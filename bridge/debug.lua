---@module 'sai.bridge.debug'
---@class sai.bridge.debug
---Development tool: a DAP server-side debug harness for swayimg's LuaJIT
---runtime, a port of one-small-step-for-vimkind's debuggee logic (the
---debug.sethook flow control and the DAP request handlers), with no
---client-side concerns. Not loaded during normal swayimg operation.
---See the README (Development) for how to start it; nvim-dap users get the
---companion adapter module sai/nvim_dap.lua.

local cjson = require 'cjson'
local ffi = require 'ffi'
local sock = require 'sai.bridge.socket'
local U = require 'sai.lib.utils'

-- the rest of the cdefs this module needs lives in sai.bridge.socket
pcall(ffi.cdef, 'char *realpath(const char *path, char *resolve);')
pcall(ffi.cdef, 'void free(void *ptr);')

pcall(function() cjson.encode_empty_table_as_object(true) end)

local INTERNAL_SRC = debug.getinfo(1, 'S').source

local S = {
	path = nil,
	signal = 'USR2',
	log_path = nil,

	srv = nil,
	conn = nil,
	queue = {},
	seq = 0,

	state = 'off',
	hooked = false,
	attached = false,
	init_done = false,
	attach_done = false,

	running = true,
	in_freeze = false,
	in_eval = false,

	step_in = nil,
	step_over = nil,
	step_out = nil,
	pause_req = false,
	stop_depth = 0,

	bps = {},
	frames = {},
	frame_id = 1,
	vars_ref = {},
	vars_id = 1,

	exc_msg = nil,
	exc_trace = nil,
	exc_default = false,

	path_cache = {},
	exit_sub = nil,
}

local session_reset
local install_hook
local sync_exc_override

local function log(msg)
	if not S.log_path then return end
	local f = io.open(S.log_path, 'a')
	if f then
		f:write(os.date '%H:%M:%S' .. ' ' .. tostring(msg) .. '\n')
		f:close()
	end
end

local function tbl(x)
	if type(x) ~= 'table' then return {} end
	return x
end

local function norm_path(p)
	if type(p) ~= 'string' or p == '' then return nil end
	local c = S.path_cache[p]
	if c ~= nil then return c end
	local res
	local rp = ffi.C.realpath(p, nil)
	if rp ~= nil then
		res = ffi.string(rp)
		ffi.C.free(rp)
	else
		res = p
	end
	S.path_cache[p] = res
	return res
end

local function source_path(src)
	if type(src) ~= 'string' or src:sub(1, 1) ~= '@' then return nil end
	return norm_path(src:sub(2))
end

---Walks the stack and locates the user code being debugged.
---Returns two levels relative to the caller: the innermost user frame
---(first frame past the outermost harness frame, skipping C frames such as
---the pcall bridge or an error handler) and the outermost valid level.
---Valid from any call depth: the outermost harness frame on the stack
---(the line hook, an error handler or a manual pump entry) marks the boundary.
local function user_stack()
	local surface, top = 0, 0
	local off = 1
	while true do
		local info = debug.getinfo(off, 'S')
		if not info then
			top = off - 1
			break
		end
		if info.source == INTERNAL_SRC then surface = off end
		off = off + 1
	end
	local base = surface + 1
	while base < top do
		local info = debug.getinfo(base, 'S')
		if info and info.what == 'C' then
			base = base + 1
		else
			break
		end
	end
	return base - 1, top - 1
end

local function user_depth()
	local base, top = user_stack()
	return top - base
end

---Collects locals and upvalues of the frame at `level` (relative to
---`frame_env` itself) into a lookup environment with `_G` fallback.
local function frame_env(level)
	local locals, ups = {}, {}
	if level then
		local i = 1
		while true do
			local ln, lv = debug.getlocal(level, i)
			if not ln then break end
			if not ln:find '^%(' then locals[ln] = lv end
			i = i + 1
		end
		local info = debug.getinfo(level, 'f')
		if info and info.func then
			local i = 1
			while true do
				local ln, lv = debug.getupvalue(info.func, i)
				if not ln then break end
				if not ln:find '^%(' then ups[ln] = lv end
				i = i + 1
			end
		end
	end
	setmetatable(ups, { __index = _G })
	setmetatable(locals, { __index = ups })
	return locals
end

---Evaluates `code` in the context of the frame `level` (relative to `eval_in`
---itself: `debug.getinfo(level)` from here must return the target frame).
local function eval_in(level, code)
	local fn, err = loadstring(code, '=(dap eval)')
	if not fn then
		fn, err = loadstring('return ' .. code, '=(dap eval)')
	end
	if not fn then return nil, err end
	setfenv(fn, frame_env(level and level + 1))
	S.in_eval = true
	local ok, res = pcall(fn)
	S.in_eval = false
	if not ok then return nil, res end
	return true, res
end

---`level` is the target frame relative to the caller (the line hook).
local function interpolate(level, fmt)
	return (
		fmt:gsub('{(.-)}', function(expr)
			local ok, res = eval_in(level + 2, expr)
			if ok then return tostring(res) end
			return '{' .. expr .. '}'
		end)
	)
end

local function new_var_ref(val)
	S.vars_id = S.vars_id + 1
	S.vars_ref[S.vars_id] = val
	return S.vars_id
end

local function handle_disconnect()
	if not S.conn then return end
	log 'client disconnected'
	session_reset(false)
end

local function send_all(data)
	local conn = S.conn
	if not conn then return false end
	if not conn:send(data) then
		handle_disconnect()
		return false
	end
	return true
end

local function parse_frames(conn)
	local buf = conn.buffer
	while true do
		local hend = buf:find('\r\n\r\n', 1, true)
		if not hend then break end
		local len = tonumber(buf:match '^Content%-Length:%s*(%d+)')
		local bstart = hend + 4
		if not len then
			buf = buf:sub(bstart)
		elseif #buf < bstart - 1 + len then
			break
		else
			local body = buf:sub(bstart, bstart - 1 + len)
			buf = buf:sub(bstart + len)
			local ok, msg = pcall(cjson.decode, body)
			if ok then
				S.queue[#S.queue + 1] = msg
			else
				log('bad message: ' .. tostring(msg))
			end
		end
	end
	conn.buffer = buf
	if #buf > 1024 * 1024 then
		log 'input overflow'
		handle_disconnect()
	end
end

local function send_msg(m)
	S.seq = S.seq + 1
	m.seq = S.seq
	local ok, enc = pcall(cjson.encode, m)
	if not ok then
		log('encode error: ' .. tostring(enc))
		return
	end
	send_all('Content-Length: ' .. #enc .. '\r\n\r\n' .. enc)
end

local function respond(req, body)
	local m = {
		type = 'response',
		request_seq = req.seq,
		success = true,
		command = req.command,
	}
	if body then m.body = body end
	send_msg(m)
end

local function respond_err(req, message)
	send_msg {
		type = 'response',
		request_seq = req.seq,
		success = false,
		command = req.command,
		message = tostring(message),
	}
end

local function event(name, body)
	local m = { type = 'event', event = name }
	if body then m.body = body end
	send_msg(m)
end

local handlers = {}

function handlers.initialize(req)
	S.init_done = true
	respond(req, {
		supportsConfigurationDoneRequest = true,
		supportTerminateDebuggee = true,
		supportsExceptionInfoRequest = true,
		supportsHitConditionalBreakpoints = true,
		supportsConditionalBreakpoints = true,
		supportsSetVariable = true,
		supportsLogPoints = true,
		exceptionBreakpointFilters = {
			{ filter = 'lua_error', label = 'Lua errors', default = false },
		},
	})
	event 'initialized'
end

function handlers.attach(req)
	S.attach_done = true
	respond(req, {})
end

handlers.launch = handlers.attach

function handlers.setBreakpoints(req)
	local args = tbl(req.arguments)
	local path = norm_path(args.source and args.source.path)
	local out = {}
	if path then
		for _, linebps in pairs(S.bps) do
			if linebps[path] then linebps[path] = nil end
		end
		for _, bp in ipairs(tbl(args.breakpoints)) do
			local spec = { hits = 0 }
			if type(bp.condition) == 'string' then spec.cond = bp.condition end
			if type(bp.hitCondition) == 'string' or type(bp.hitCondition) == 'number' then
				spec.hitn = tonumber(bp.hitCondition)
			end
			if type(bp.logMessage) == 'string' then spec.log = bp.logMessage end
			S.bps[bp.line] = S.bps[bp.line] or {}
			S.bps[bp.line][path] = spec
			out[#out + 1] = { verified = true, line = bp.line }
		end
	end
	respond(req, { breakpoints = out })
end

function handlers.setExceptionBreakpoints(req)
	local args = tbl(req.arguments)
	S.break_on_exception = false
	for _, f in ipairs(tbl(args.filters)) do
		if f == 'lua_error' then S.break_on_exception = true end
	end
	if S.hooked then sync_exc_override() end
	respond(req, { breakpoints = {} })
end

function handlers.configurationDone(req)
	respond(req, {})
	install_hook()
end

function handlers.continue(req)
	S.running = true
	S.step_in, S.step_over, S.step_out, S.pause_req = nil, nil, nil, nil
	respond(req, { allThreadsContinued = true })
end

function handlers.pause(req)
	S.pause_req = true
	respond(req, {})
end

function handlers.next(req)
	if S.in_freeze then
		S.step_in, S.step_over, S.step_out = nil, S.stop_depth, nil
		S.running = true
	end
	respond(req, {})
end

function handlers.stepIn(req)
	if S.in_freeze then
		S.step_in, S.step_over, S.step_out = true, nil, nil
		S.running = true
	end
	respond(req, {})
end

function handlers.stepOut(req)
	if S.in_freeze then
		S.step_in, S.step_over, S.step_out = nil, nil, S.stop_depth
		S.running = true
	end
	respond(req, {})
end

function handlers.threads(req) respond(req, { threads = { { id = 1, name = 'main' } } }) end

function handlers.stackTrace(req)
	local args = tbl(req.arguments)
	local start = args.startFrame or 0
	local max = args.levels or -1
	local base, top = user_stack()
	local out = {}
	local off = base + start
	while off <= top and (max == -1 or #out < max) do
		local info = debug.getinfo(off, 'Sln')
		if info and info.source and info.source:sub(1, 1) == '@' then
			local path = source_path(info.source)
			if path then
				S.frames[S.frame_id] = off
				out[#out + 1] = {
					id = S.frame_id,
					name = info.name or ((info.what or '') .. ' chunk'),
					line = info.currentline or 0,
					column = 0,
					source = { name = info.source, path = path },
				}
				S.frame_id = S.frame_id + 1
			end
		end
		off = off + 1
	end
	respond(req, { stackFrames = out, totalFrames = #out })
end

function handlers.scopes(req)
	local args = tbl(req.arguments)
	local level = S.frames[args.frameId]
	if not level then
		respond(req, { scopes = {} })
		return
	end
	respond(req, {
		scopes = {
			{
				name = 'Locals',
				presentationHint = 'locals',
				expensive = false,
				variablesReference = new_var_ref(level),
			},
		},
	})
end

local function var_item(name, val)
	local v = { name = tostring(name), type = type(val), variablesReference = 0 }
	if type(val) == 'table' then
		local mt = getmetatable(val)
		v.value = mt and mt.__tostring and 'table' or tostring(val)
		v.variablesReference = new_var_ref(val)
	else
		v.value = tostring(val)
	end
	return v
end

function handlers.variables(req)
	local args = tbl(req.arguments)
	local ref = S.vars_ref[args.variablesReference]
	local vars = {}
	if type(ref) == 'number' then
		local i = 1
		while true do
			local ln, lv = debug.getlocal(ref, i)
			if not ln then break end
			if not ln:find '^%(' then vars[#vars + 1] = var_item(ln, lv) end
			i = i + 1
		end
		local info = debug.getinfo(ref, 'f')
		if info and info.func then
			local i = 1
			while true do
				local ln, lv = debug.getupvalue(info.func, i)
				if not ln then break end
				if not ln:find '^%(' then vars[#vars + 1] = var_item(ln, lv) end
				i = i + 1
			end
		end
	elseif type(ref) == 'table' then
		for k, val in pairs(ref) do
			vars[#vars + 1] = var_item(k, val)
		end
	end
	respond(req, { variables = vars })
end

function handlers.evaluate(req)
	local args = tbl(req.arguments)
	local level = args.frameId and S.frames[args.frameId]
	local ok, res = eval_in(level and level + 1, tostring(args.expression or ''))
	if not ok then res = res or 'evaluation failed' end
	local v
	if type(res) == 'table' then
		local mt = getmetatable(res)
		v = {
			result = mt and mt.__tostring and 'table' or tostring(res),
			variablesReference = new_var_ref(res),
		}
	else
		v = { result = tostring(res), variablesReference = 0 }
	end
	respond(req, v)
end

function handlers.setVariable(req)
	local args = tbl(req.arguments)
	local ref = S.vars_ref[args.variablesReference]
	local val
	local fn = loadstring('return ' .. tostring(args.value or ''), '=(dap set)')
	if fn then
		setfenv(fn, frame_env(nil))
		local ok, res = pcall(fn)
		val = ok and res or args.value
	else
		val = args.value
	end
	if type(ref) == 'number' then
		local i = 1
		while true do
			local ln = debug.getlocal(ref, i)
			if not ln then break end
			if ln == args.name then debug.setlocal(ref, i, val) end
			i = i + 1
		end
	elseif type(ref) == 'table' then
		ref[args.name] = val
	end
	local body = { value = tostring(val), type = type(val), variablesReference = 0 }
	if type(val) == 'table' then body.variablesReference = new_var_ref(val) end
	respond(req, body)
end

function handlers.exceptionInfo(req)
	respond(req, {
		exceptionId = 'error',
		breakMode = 'always',
		description = S.exc_msg or '',
		details = { message = S.exc_msg or '', stackTrace = S.exc_trace or '' },
	})
end

function handlers.disconnect(req)
	respond(req, {})
	local term = tbl(req.arguments).terminateDebuggee == true
	event 'terminated'
	if term then event('exited', { exitCode = 0 }) end
	session_reset(term)
	if term then sai.defer_fn(function() sai.exit(0) end, 1) end
end

local function dispatch(msg)
	if type(msg) ~= 'table' or not msg.command then return end
	log('recv ' .. msg.command)
	local h = handlers[msg.command]
	if h then
		local ok, err = pcall(h, msg)
		if not ok then
			log('handler error: ' .. tostring(err))
			respond_err(msg, err)
		end
	else
		respond(msg, {})
	end
end

local function drain_queue()
	while S.queue[1] do
		if S.in_freeze and S.running then break end
		dispatch(table.remove(S.queue, 1))
	end
end

-- the harness server: a socket server extension
local dbg_srv = {
	super = sock.Server,
	arm_conns = true,
}
setmetatable(dbg_srv, { __index = dbg_srv.super })

function dbg_srv.new(self)
	U.new_object(self, dbg_srv)
	return sock.Server.new(self)
end

function dbg_srv:on_data(conn)
	if conn:drain() then
		handle_disconnect()
	else
		parse_frames(conn)
	end
end

-- the socket layer drained the connection before this runs: the pre-accept
-- bytes are already parsed into the queue
function dbg_srv:on_conn(conn)
	if S.conn then
		conn:close()
		return
	end
	S.conn = conn
	log 'client connected'
	parse_frames(conn)
end

function dbg_srv:on_io()
	self:poll(0)
	drain_queue()
end

local function freeze(reason, text)
	S.frames, S.vars_ref = {}, {}
	S.frame_id, S.vars_id = 1, 1
	S.in_freeze = true
	S.running = false
	event('stopped', { reason = reason, threadId = 1, text = text })
	log('stopped: ' .. reason .. ' depth=' .. tostring(S.stop_depth))
	while not S.running do
		drain_queue()
		if not S.running and S.conn then S.srv:poll(200) end
		if not S.conn then S.running = true end
	end
	S.in_freeze = false
	log 'resumed'
end

local function hook(_, line)
	if not S.hooked or S.in_freeze or S.in_eval then return end
	local info = debug.getinfo(2, 'S')
	if not info or info.source == INTERNAL_SRC then return end

	local linebps = S.bps[line]
	if linebps then
		local path = source_path(info.source)
		local spec = path and linebps[path]
		if spec then
			spec.hits = spec.hits + 1
			local hit = true
			if spec.hitn and spec.hits ~= spec.hitn then hit = false end
			if hit and spec.cond then
				local ok, res = eval_in(3, spec.cond)
				hit = ok and res == true
			end
			if hit then
				if spec.log then
					event('output', { category = 'console', output = interpolate(2, spec.log) .. '\n' })
				else
					S.stop_depth = user_depth()
					freeze 'breakpoint'
					return
				end
			end
		end
	end

	if S.step_in then
		S.step_in = nil
		S.stop_depth = user_depth()
		freeze 'step'
	elseif S.step_over then
		local d = user_depth()
		if d <= S.step_over then
			S.step_over = nil
			S.stop_depth = d
			freeze 'step'
		end
	elseif S.step_out then
		local d = user_depth()
		if d < S.step_out then
			S.step_out = nil
			S.stop_depth = d
			freeze 'step'
		end
	elseif S.pause_req then
		S.pause_req = false
		S.stop_depth = user_depth()
		freeze 'pause'
	end
end

local orig_traceback

local function traceback_hook(...)
	if not S.attached or S.in_freeze or S.in_eval then return orig_traceback(...) end

	local explicit
	local off = 1
	while true do
		local info = debug.getinfo(off, 'Sfn')
		if not info then break end
		if info.func == debug.traceback and info.name == 'traceback' then
			local above = debug.getinfo(off + 1, 'S')
			if above and above.source ~= '=[C]' then explicit = true end
		end
		off = off + 1
	end
	if explicit then return orig_traceback(...) end

	local args = { ... }
	S.exc_msg = tostring(args[1] or '')
	local trace = {}
	local base, top = user_stack()
	local lvl = base
	while lvl <= top do
		local info = debug.getinfo(lvl, 'Sln')
		if info then
			local desc = (info.short_src or '?') .. ':' .. (info.currentline or 0)
			if info.name then
				desc = desc .. ' in function ' .. info.name
			elseif info.what then
				desc = desc .. ' in ' .. info.what .. ' chunk'
			end
			trace[#trace + 1] = desc
		end
		lvl = lvl + 1
	end
	S.exc_trace = table.concat(trace, '\n')
	log('exception: ' .. S.exc_msg)
	S.stop_depth = user_depth()
	freeze('exception', S.exc_msg)
	return orig_traceback(...)
end

function sync_exc_override()
	if S.break_on_exception and S.attached and not orig_traceback then
		orig_traceback = debug.traceback
		debug.traceback = traceback_hook
	elseif not S.break_on_exception and orig_traceback and not S.in_freeze then
		debug.traceback = orig_traceback
		orig_traceback = nil
	end
end

function install_hook()
	if S.hooked then return end
	S.hooked = true
	S.attached = true
	debug.sethook(hook, 'l')
	sync_exc_override()
	log 'hook installed'
end

local function remove_hook()
	if not S.hooked then return end
	S.hooked = false
	S.attached = false
	debug.sethook()
	if orig_traceback then
		debug.traceback = orig_traceback
		orig_traceback = nil
	end
	log 'hook removed'
end

function session_reset(full)
	if S.conn then
		S.conn:close()
		S.conn = nil
		-- the full reset either exits swayimg or tears the whole server
		-- down: no status message would outlive it
		if not full then sai.notify('debug: client disconnected', 3) end
	end
	if full then
		if S.srv then
			S.srv:stop()
			S.srv = nil
		end
		if S.exit_sub then
			local ok, ev = pcall(require, 'sai.api.eventloop')
			if ok then pcall(ev.unsubscribe, { id = S.exit_sub }) end
			S.exit_sub = nil
		end
	end
	S.queue = {}
	S.frames, S.vars_ref = {}, {}
	S.frame_id, S.vars_id = 1, 1
	S.running = true
	S.in_freeze = false
	S.in_eval = false
	S.step_in, S.step_over, S.step_out, S.pause_req, S.stop_depth = nil, nil, nil, false, nil
	S.exc_msg, S.exc_trace = nil, nil
	S.init_done, S.attach_done, S.attached = false, false, false
	S.break_on_exception = S.exc_default
	remove_hook()
	if full then
		S.state = 'off'
	elseif S.srv then
		S.state = 'listening'
	else
		S.state = 'off'
	end
end

local M = {}

function M.start(opts)
	opts = opts or {}
	if S.state ~= 'off' then return S.path end
	S.path = opts.path
		or ('%s/sai-debug-%d.sock'):format(os.getenv 'XDG_RUNTIME_DIR' or '/tmp', tonumber(ffi.C.getpid()))
	S.signal = opts.signal ~= nil and opts.signal or 'USR2'
	if opts.log then
		S.log_path = type(opts.log) == 'string' and opts.log
			or ('/tmp/sai-debug-%d.log'):format(tonumber(ffi.C.getpid()))
	end
	S.exc_default = opts.break_on_exception == true
	S.break_on_exception = S.exc_default

	S.srv = dbg_srv.new {
		path = S.path,
		signal = S.signal,
	}
	S.state = 'listening'

	S.exit_sub = sai.eventloop.subscribe {
		event = 'SwiLeavePre',
		once = true,
		callback = function()
			M.stop()
			return true
		end,
	}

	log('listening on ' .. S.path)
	if opts.blocking then M.wait_attached() end
	return S.path
end

function M.wait_attached()
	while not S.attached and S.state ~= 'off' do
		S.srv:poll(50)
		drain_queue()
	end
end

function M.stop() session_reset(true) end

function M.is_attached() return S.attached end

function M.pump(timeout)
	if not S.srv then return end
	S.srv:poll(timeout or 0)
	drain_queue()
end

return M
