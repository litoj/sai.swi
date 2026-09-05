---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for sai.bridge.debug: the DAP communication between a raw client
---and the harness, end-to-end - each scenario spawns its own debuggee
---process and drives it over the socket.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local ok, eq, contains, fail = H.ok, H.eq, H.contains, H.fail

local cjson = require 'cjson'
local ffi = require 'ffi'

-- the raw client below needs the socket cdefs
require 'sai.bridge.socket'

local tmp = '/tmp/sai_debug_test'
local sock = tmp .. '.sock'
local script_path = tmp .. '_script.lua'
local log_path = tmp .. '_script.log'
local dbg_log_path = tmp .. '_dbg.log'
local pid_path = tmp .. '_script.pid'

local AF_UNIX, SOCK_STREAM = 1, 1
local POLLIN, MSG_NOSIGNAL = 0x1, 0x4000

local function client_new(path)
	local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
	assert(fd >= 0, 'socket failed')
	local addr = ffi.new 'struct sockaddr_un'
	addr.sun_family = AF_UNIX
	ffi.copy(ffi.cast('char *', addr.sun_path), path)
	assert(ffi.C.connect(fd, addr, ffi.sizeof(addr)) == 0, 'connect failed')
	return { fd = fd, buf = '', msgs = {}, seq = 0, dead = false }
end

local function client_close(c)
	if c.fd >= 0 then ffi.C.close(c.fd) end
	c.fd = -1
end

local function client_send(c, m)
	local enc = cjson.encode(m)
	local data = 'Content-Length: ' .. #enc .. '\r\n\r\n' .. enc
	local sent = 0
	while sent < #data do
		local n = ffi.C.send(c.fd, ffi.cast('const char *', data) + sent, #data - sent, MSG_NOSIGNAL)
		if n <= 0 then
			c.dead = true
			return false
		end
		sent = sent + n
	end
	return true
end

local function client_pump(c, timeout)
	local pfd = ffi.new('struct pollfd', { fd = c.fd, events = POLLIN })
	if ffi.C.poll(pfd, 1, timeout) <= 0 then return end
	local buf = ffi.new 'char[65536]'
	local n = ffi.C.recv(c.fd, buf, 65536, 0)
	if n <= 0 then
		c.dead = true
		return
	end
	c.buf = c.buf .. ffi.string(buf, n)
	while true do
		local hend = c.buf:find('\r\n\r\n', 1, true)
		if not hend then break end
		local len = tonumber(c.buf:match '^Content%-Length:%s*(%d+)')
		if not len or #c.buf < hend + 3 + len then break end
		local bstart = hend + 4
		c.msgs[#c.msgs + 1] = cjson.decode(c.buf:sub(bstart, bstart + len - 1))
		c.buf = c.buf:sub(bstart + len)
	end
end

local function expect(c, pred, timeout)
	local deadline = os.time() + (timeout or 10)
	while os.time() < deadline do
		for i, m in ipairs(c.msgs) do
			if pred(m) then return table.remove(c.msgs, i) end
		end
		client_pump(c, 100)
		if c.dead then
			for i, m in ipairs(c.msgs) do
				if pred(m) then return table.remove(c.msgs, i) end
			end
			return nil
		end
	end
	return nil
end

local function request(c, command, args)
	c.seq = c.seq + 1
	local m = { seq = c.seq, type = 'request', command = command }
	if args ~= nil then m.arguments = args end
	if not client_send(c, m) then return nil end
	return expect(c, function(r) return r.type == 'response' and r.request_seq == c.seq end)
end

local function request_ok(c, command, args)
	local r = request(c, command, args)
	if not r or r.success ~= true then
		fail('request ' .. command .. ': ' .. tostring(r and r.message or 'no response'))
	end
	return r
end

local function wait_event(c, name, timeout)
	return expect(c, function(m) return m.type == 'event' and m.event == name end, timeout)
end

local function wait_stopped(c, reason)
	local m = wait_event(c, 'stopped')
	if not m then return nil end
	if reason and m.body and m.body.reason ~= reason then
		fail('stopped reason: expected ' .. reason .. ' got ' .. tostring(m.body and m.body.reason))
		return nil
	end
	return m
end

local function drain(c)
	for _ = 1, 10 do
		if c.dead then break end
		client_pump(c, 100)
	end
end

local function cleanup()
	os.remove(script_path)
	os.remove(log_path)
	os.remove(dbg_log_path)
	os.remove(pid_path)
	os.remove(sock)
end

local function read_log() return H.read_file(log_path) end

local function find_line(pattern)
	local f = assert(io.open(script_path, 'r'))
	local n = 0
	for line in f:lines() do
		n = n + 1
		if line:find(pattern, 1, true) then
			f:close()
			return n
		end
	end
	f:close()
	error('pattern not found in debuggee script: ' .. pattern)
end

local function start_debuggee()
	os.remove(sock)
	H.spawn('luajit ' .. script_path, log_path, pid_path)
	local ready = H.wait_for(function() return (read_log() or ''):find('DBG_READY', 1, true) ~= nil end, 15)
	if not ready then error('debuggee did not start:\n' .. (read_log() or '')) end
end

local function kill_debuggee() H.kill(tonumber((H.read_file(pid_path) or ''):match '%d+')) end

local function wait_log(pattern, timeout)
	return H.wait_for(function() return (read_log() or ''):find(pattern, 1, true) ~= nil end, timeout)
end

local function write_debuggee(user_code)
	local script = table.concat({
		("package.path = %q .. '/?.lua;' .. package.path"):format(H.swayimg_dir),
		-- plain luajit: mock the sai env the harness runs in',
		'local noop = function() end',
		'_G.sai = {',
		'\tdefer_fn = function(cb) cb() end,',
		'\texit = function(code) os.exit(code) end,',
		'\tlog = function(m) print(m) end,',
		'\tnotify = function() end,',
		'\teventloop = { subscribe = function() return {} end, unsubscribe = noop },',
		'}',
		"local dbg = require 'sai.bridge.debug'",
		('local sock = dbg.start { path = %q, log = %q }'):format(sock, dbg_log_path),
		"print('DBG_READY ' .. sock)",
		'io.stdout:flush()',
		'dbg.wait_attached()',
		user_code,
	}, '\n') .. '\n'
	H.write_file(script_path, script)
end

local function handshake(c)
	request_ok(c, 'initialize', { adapterID = 'test' })
	ok('initialized event', wait_event(c, 'initialized') ~= nil)
	request_ok(c, 'attach', {})
end

-- A test method: always kills the debuggee and removes its files afterwards,
-- even when the scenario crashes midway
local function scenario(fn)
	return function()
		local ran, err = pcall(fn)
		kill_debuggee()
		cleanup()
		if not ran then H.fail('scenario crashed', err) end
	end
end

local T = {}

T.breakpoints = scenario(function()
	write_debuggee [[
e_table = { alpha = 1, beta = 2, gamma = 3, delta = 4, epsilon = 5, zeta = 6, eta = 7, theta = 8, iota = 9, kappa = 10 }
e_proxy = setmetatable({ 10, 20, 30 }, { __tostring = function(t) return 'PROXY ' .. #t end })

local function work(n)
	local acc = 0
	for i = 1, n do
		acc = acc + i
	end
	return acc
end

local total = work(5)
print('RESULT ' .. total)
io.stdout:flush()
]]

	local bp_line = find_line 'acc = acc + i'

	start_debuggee()
	local c = client_new(sock)
	handshake(c)
	request_ok(c, 'setBreakpoints', {
		source = { path = script_path },
		breakpoints = { { line = bp_line } },
	})
	request_ok(c, 'configurationDone')

	local stopped = wait_stopped(c, 'breakpoint')
	ok('breakpoint stopped', stopped ~= nil)
	eq('stopped threadId', 1, stopped and stopped.body and stopped.body.threadId)

	local r = request_ok(c, 'threads')
	eq('thread count', 1, r and r.body and #r.body.threads)

	r = request_ok(c, 'stackTrace', { threadId = 1 })
	local frames = r and r.body and r.body.stackFrames
	eq('top frame name', 'work', frames and frames[1].name)
	eq('top frame line', bp_line, frames and frames[1].line)
	eq('top frame path', script_path, frames and frames[1].source and frames[1].source.path)
	eq('caller frame name', 'main chunk', frames and frames[2] and frames[2].name)

	r = request_ok(c, 'scopes', { frameId = frames[1].id })
	local scopes = r and r.body and r.body.scopes
	ok('scopes present', scopes and #scopes == 1)
	local scope_ref = scopes and scopes[1].variablesReference

	r = request_ok(c, 'variables', { variablesReference = scope_ref })
	local names = {}
	for _, v in ipairs((r and r.body and r.body.variables) or {}) do
		names[v.name] = v.value
	end
	eq('acc value at first hit', '0', names.acc)

	r = request_ok(c, 'evaluate', { expression = 'i * 10 + acc', frameId = frames[1].id })
	eq('evaluate scalar', '10', r and r.body and r.body.result)

	r = request_ok(c, 'evaluate', { expression = '/nat i * 10 + acc', frameId = frames[1].id })
	eq('evaluate /nat prefix stripped', '10', r and r.body and r.body.result)

	r = request_ok(c, 'evaluate', { expression = '{ [19] = "a", [2] = "b", [1] = "c" }', frameId = frames[1].id })
	local table_ref = r and r.body and r.body.variablesReference
	ok('evaluate table ref', table_ref and table_ref ~= 0)

	r = request_ok(c, 'evaluate', { expression = 'e_table', frameId = frames[1].id })
	local res = r and r.body and r.body.result or ''
	ok('evaluate wide table one-line', type(res) == 'string' and not res:find('\n', 1, true))
	r = request_ok(c, 'variables', { variablesReference = r and r.body and r.body.variablesReference })
	local prev = ''
	local sorted = true
	for _, v in ipairs((r and r.body and r.body.variables) or {}) do
		if v.name < prev then sorted = false end
		prev = v.name
	end
	ok('table members sorted by name', sorted)

	r = request_ok(c, 'variables', { variablesReference = table_ref })
	local names = {}
	for _, v in ipairs((r and r.body and r.body.variables) or {}) do
		names[#names + 1] = v.name
	end
	eq('table member count', 3, #names)
	eq('numeric names sort numerically', '1,2,19', table.concat(names, ','))

	-- metamethod tables render their __tostring now instead of a bare 'table'
	r = request_ok(c, 'evaluate', { expression = 'e_proxy', frameId = frames[1].id })
	eq('proxy value via metamethod', 'PROXY 3', r and r.body and r.body.result)

	r = request_ok(c, 'evaluate', { expression = 'nosuchvar + 1', frameId = frames[1].id })
	ok('evaluate error has message', r and r.body and r.body.result ~= nil and #r.body.result > 0)

	request_ok(c, 'setVariable', {
		variablesReference = scope_ref,
		name = 'n',
		value = '9',
	})

	r = request_ok(c, 'variables', { variablesReference = scope_ref })
	names = {}
	for _, v in ipairs((r and r.body and r.body.variables) or {}) do
		names[v.name] = v.value
	end
	eq('setVariable applied', '9', names.n)

	request_ok(c, 'next')
	wait_stopped(c, 'step')
	request_ok(c, 'stepOut')
	wait_stopped(c, 'breakpoint')
	request_ok(c, 'continue')
	wait_stopped(c, 'breakpoint')
	request_ok(c, 'continue')
	wait_stopped(c, 'breakpoint')
	request_ok(c, 'continue')
	wait_stopped(c, 'breakpoint')
	request_ok(c, 'disconnect')
	ok('terminated event', wait_event(c, 'terminated') ~= nil)

	ok('debuggee finished after disconnect', wait_log 'RESULT 15' ~= nil)

	client_close(c)
end)

-- a client holding frame/variable references from a previous stop must get
-- visible errors after the freeze reset them - never empty lists or
-- evaluations against the wrong frame (which silently wipe UI state)
T.stale_refs = scenario(function()
	write_debuggee [[
local function work(n)
	local acc = 0
	for i = 1, n do
		acc = acc + i
	end
	return acc
end

local total = work(4)
print('RESULT ' .. total)
io.stdout:flush()
]]

	local bp_line = find_line 'acc = acc + i'

	start_debuggee()
	local c = client_new(sock)
	handshake(c)
	request_ok(c, 'setBreakpoints', {
		source = { path = script_path },
		breakpoints = { { line = bp_line } },
	})
	request_ok(c, 'configurationDone')
	wait_stopped(c, 'breakpoint')

	local r = request_ok(c, 'stackTrace', { threadId = 1 })
	local old_frame_id = r.body.stackFrames[1].id
	r = request_ok(c, 'scopes', { frameId = old_frame_id })
	local old_scope_ref = r.body.scopes[1].variablesReference
	r = request_ok(c, 'evaluate', { expression = 'acc', frameId = old_frame_id })
	eq('evaluate at stop', '0', r.body.result)

	-- advance to the next stop: the freeze resets the reference maps
	request_ok(c, 'continue')
	wait_stopped(c, 'breakpoint')

	local function request_fail(command, args)
		local resp = request(c, command, args)
		if not resp then
			fail('request ' .. command .. ': no response')
		elseif resp.success ~= false then
			fail('request ' .. command .. ': expected an error, got success')
		end
		return resp
	end

	request_fail('scopes', { frameId = old_frame_id })
	request_fail('variables', { variablesReference = old_scope_ref })
	request_fail('evaluate', { expression = 'acc', frameId = old_frame_id })
	request_fail('setVariable', { variablesReference = old_scope_ref, name = 'acc', value = '0' })

	-- fresh references still work and the ids never get reused across stops
	r = request_ok(c, 'stackTrace', { threadId = 1 })
	local new_frame_id = r.body.stackFrames[1].id
	ok('frame ids not reused', new_frame_id > old_frame_id)
	r = request_ok(c, 'scopes', { frameId = new_frame_id })
	local scope_ref = r.body.scopes[1].variablesReference
	ok('variable refs not reused', scope_ref > old_scope_ref)

	-- expressions that LuaJIT would also compile as statements must still
	-- return their value, not silently drop it
	r = request_ok(c, 'evaluate', { expression = 'type(acc)', frameId = new_frame_id })
	eq('evaluate call returns value', 'number', r.body.result)
	r = request_ok(c, 'evaluate', { expression = 'acc ~= nil', frameId = new_frame_id })
	eq('evaluate comparison returns value', 'true', r.body.result)
	-- statements still run through the fallback: globals persist across
	-- evaluations (locals cannot be assigned this way - env copies only)
	r = request_ok(c, 'evaluate', { expression = '_G.stamp = 5', frameId = new_frame_id })
	r = request_ok(c, 'evaluate', { expression = 'stamp', frameId = new_frame_id })
	eq('evaluate statement works', '5', r.body.result)

	request_ok(c, 'disconnect')
	ok('terminated event', wait_event(c, 'terminated') ~= nil)

	client_close(c)
end)

T.hit_log = scenario(function()
	write_debuggee [[
local function work(n)
	local acc = 0
	for i = 1, n do
		acc = acc + i
		local dummy = acc
	end
	return acc
end

local total = work(5)
print('RESULT ' .. total)
io.stdout:flush()
]]

	local log_line = find_line 'acc = acc + i'
	local hit_line = find_line 'local dummy = acc'

	start_debuggee()
	local c = client_new(sock)
	handshake(c)
	request_ok(c, 'setBreakpoints', {
		source = { path = script_path },
		breakpoints = {
			{ line = log_line, logMessage = 'iteration i={i} acc={acc}' },
			{ line = hit_line, hitCondition = '3' },
		},
	})
	request_ok(c, 'configurationDone')

	wait_stopped(c, 'breakpoint')
	local r = request_ok(c, 'stackTrace', { threadId = 1 })
	local hit_frames = r and r.body and r.body.stackFrames
	r = request_ok(c, 'evaluate', { expression = 'i', frameId = hit_frames and hit_frames[1].id })
	eq('hit condition stops on 3rd', '3', r and r.body and r.body.result)
	request_ok(c, 'disconnect')

	ok('debuggee finished after hit bp', wait_log 'RESULT 15' ~= nil)

	drain(c)
	local outputs, first_output = 0, nil
	for _, m in ipairs(c.msgs) do
		if m.type == 'event' and m.event == 'output' then
			outputs = outputs + 1
			first_output = first_output or (m.body and m.body.output)
		end
	end
	ok('log point fired', outputs >= 1)
	if first_output then contains('log point interpolated', first_output, 'iteration i=') end

	client_close(c)
end)

T.conditional = scenario(function()
	write_debuggee [[
local function work(n)
	local acc = 0
	for i = 1, n do
		acc = acc + i
	end
	return acc
end

local total = work(5)
print('RESULT ' .. total)
io.stdout:flush()
]]

	local cond_line = find_line 'acc = acc + i'

	start_debuggee()
	local c = client_new(sock)
	handshake(c)
	request_ok(c, 'setBreakpoints', {
		source = { path = script_path },
		breakpoints = { { line = cond_line, condition = 'i >= 4' } },
	})
	request_ok(c, 'configurationDone')

	wait_stopped(c, 'breakpoint')
	local r = request_ok(c, 'stackTrace', { threadId = 1 })
	local cond_frames = r and r.body and r.body.stackFrames
	r = request_ok(c, 'evaluate', { expression = 'i', frameId = cond_frames and cond_frames[1].id })
	eq('condition stops at i=4', '4', r and r.body and r.body.result)
	request_ok(c, 'continue')
	wait_stopped(c, 'breakpoint')
	r = request_ok(c, 'stackTrace', { threadId = 1 })
	cond_frames = r and r.body and r.body.stackFrames
	r = request_ok(c, 'evaluate', { expression = 'i', frameId = cond_frames and cond_frames[1].id })
	eq('condition stops at i=5', '5', r and r.body and r.body.result)
	request_ok(c, 'disconnect')

	ok('debuggee finished after condition', wait_log 'RESULT 15' ~= nil)

	client_close(c)
end)

T.exception = scenario(function()
	write_debuggee [[
local function boom()
	error 'kaboom'
end

local ok = xpcall(boom, debug.traceback)
print('RESULT ' .. tostring(ok))
io.stdout:flush()
]]

	local err_line = find_line "error 'kaboom'"

	start_debuggee()
	local c = client_new(sock)
	handshake(c)
	request_ok(c, 'setExceptionBreakpoints', { filters = { 'lua_error' } })
	request_ok(c, 'configurationDone')

	local exc = wait_stopped(c, 'exception')
	ok('exception stopped', exc ~= nil)
	contains('exception text', exc and exc.body and exc.body.text, 'kaboom')

	local r = request_ok(c, 'exceptionInfo', { threadId = 1 })
	contains('exceptionInfo description', r and r.body and r.body.description, 'kaboom')
	contains(
		'exceptionInfo stack',
		r and r.body and r.body.details and r.body.details.stackTrace,
		script_path .. ':' .. err_line
	)

	r = request_ok(c, 'stackTrace', { threadId = 1 })
	local frames = r and r.body and r.body.stackFrames
	eq('exception frame line', err_line, frames and frames[1] and frames[1].line)

	request_ok(c, 'continue')
	ok('debuggee recovered from exception', wait_log 'RESULT false' ~= nil)

	client_close(c)
end)

T.coroutine = scenario(function()
	write_debuggee [[
local function cwork()
	local y = 7
	print('IN_COROUTINE ' .. y)
end

local co = coroutine.wrap(cwork)
co()

local function plain()
	local z = 3
	print('IN_PLAIN ' .. z)
end
plain()
print('RESULT done')
io.stdout:flush()
]]

	local co_line = find_line "print('IN_COROUTINE ' .. y)"

	start_debuggee()
	local c = client_new(sock)
	handshake(c)
	request_ok(c, 'setBreakpoints', {
		source = { path = script_path },
		breakpoints = { { line = co_line } },
	})
	request_ok(c, 'configurationDone')

	wait_stopped(c, 'breakpoint')
	local r = request_ok(c, 'stackTrace', { threadId = 1 })
	local frames = r and r.body and r.body.stackFrames
	eq('coroutine frame line', co_line, frames and frames[1] and frames[1].line)
	eq('coroutine frame path', script_path, frames and frames[1].source and frames[1].source.path)

	r = request_ok(c, 'evaluate', { expression = 'y', frameId = frames[1].id })
	eq('coroutine local eval', '7', r and r.body and r.body.result)

	request_ok(c, 'continue')
	ok('coroutine body executed', wait_log 'IN_COROUTINE 7' ~= nil)
	ok('debuggee finished after coroutine', wait_log 'RESULT done' ~= nil)

	client_close(c)
end)

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
