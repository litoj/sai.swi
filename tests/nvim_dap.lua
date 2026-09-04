---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for sai.nvim_dap: a complete DAP session end-to-end, over the whole
---stack - a real swayimg window with the debug harness (sai.bridge.debug)
---driven by a headless nvim running nvim-dap. Exercises breakpoint hits in
---code that init could not have set up on its own (IPC-injected,
---SIGUSR1-triggered, sai.defer_fn-scheduled) and ipc traffic concurrent
---with a debug freeze and with DAP traffic.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local ok, eq = H.ok, H.eq

local home = os.getenv 'HOME'
local e2e = '/tmp/sai_e2e'
local config_path = e2e .. '/swayimg/config.lua'
local driver_path = e2e .. '/driver.lua'
local ipc_send_path = e2e .. '/ipc_send.lua'
local ipc_sock = e2e .. '/ipc.sock'
local log_path = e2e .. '/swayimg.log'
local dbg_log = e2e .. '/dbg.log'
local pid_path = e2e .. '/swayimg.pid'
local dap_root = home .. '/.local/share/nvim/lazy/nvim-dap'
local nio_root = home .. '/.local/share/nvim/lazy/nvim-nio'

-- Debuggee config: default socket path, so that sai.nvim_dap discovery finds it
local config_src = ([[
local swi_config = os.getenv 'XDG_CONFIG_HOME' or (os.getenv 'HOME' .. '/.config')
package.path = swi_config .. '/swayimg/?.lua;' .. package.path
require 'sai.api.globals'

local dbg = require 'sai.bridge.debug'
dbg.start { log = %q }
print 'DBG_READY'
io.stdout:flush()
dbg.wait_attached()

function work(n, tag)
	local acc = 0
	for i = 1, n do
		acc = acc + i
	end
	print(('RESULT %%s %%d'):format(tag, acc))
	io.stdout:flush()
	return acc
end

work(2, 'init')

e.subscribe {
	event = 'Signal',
	pattern = 'USR1',
	callback = function() work(4, 'signal') end,
}

require('sai.bridge.ipc').server(%q)

print 'E2E_READY'
io.stdout:flush()
]]):format(dbg_log, ipc_sock)

-- Standalone IPC client: run from nvim via jobstart so that blocking on a
-- frozen debuggee does not block the nvim event loop.
local ipc_send_src = [[
local swi_config = os.getenv 'XDG_CONFIG_HOME' or (os.getenv 'HOME' .. '/.config')
package.path = swi_config .. '/swayimg/?.lua;' .. package.path
local sock, code_path = ...
local f = assert(io.open(code_path, 'rb'))
local code = f:read '*a'
f:close()
local ipc = require 'sai.bridge.ipc'
local c = ipc.client(sock)
-- compile client-side, send as bytecode: `work` and `sai` resolve server-side
local res, err = c:send(assert(load(code)))
print(res or ('ERR ' .. tostring(err)))
c.enabled = false
]]

local function driver_src(pid, bp_line)
	local dbg_sock = ('%s/sai-debug-%d.sock'):format(os.getenv 'XDG_RUNTIME_DIR' or '/tmp', pid)
	local header = table.concat({
		('local e2e = %q'):format(e2e),
		('local config_path = %q'):format(config_path),
		('local dbg_sock = %q'):format(dbg_sock),
		('local ipc_sock = %q'):format(ipc_sock),
		('local pid = %d'):format(pid),
		('local bp_line = %d'):format(bp_line),
		('local dap_root = %q'):format(dap_root),
		('local nio_root = %q'):format(nio_root),
		'',
	}, '\n')
	local body = [==[
local swi_config = os.getenv 'XDG_CONFIG_HOME' or (os.getenv 'HOME' .. '/.config')

vim.opt.runtimepath:prepend(dap_root)
vim.opt.runtimepath:prepend(nio_root)

local dap = require 'dap'
local bps = require 'dap.breakpoints'
local sdap = assert(loadfile(swi_config .. '/swayimg/sai/nvim_dap.lua'))()

local passed, failed = 0, 0

local function pass(name)
	passed = passed + 1
	print('PASS ' .. name)
end

local function fail(name, extra)
	failed = failed + 1
	print('FAIL ' .. name .. (extra ~= nil and (': ' .. tostring(extra)) or ''))
end

local function ok(name, cond)
	if cond then pass(name) else fail(name) end
end

local function eq(name, exp, got)
	if exp == got then
		pass(name)
	else
		fail(name, 'expected ' .. tostring(exp) .. ' got ' .. tostring(got))
	end
end

local log_path = e2e .. '/swayimg.log'

local function read_log()
	local f = io.open(log_path, 'r')
	if not f then return '' end
	local t = f:read '*a'
	f:close()
	return t
end

local function log_has(pat)
	return read_log():find(pat, 1, true) ~= nil
end

local function wait_log(pat, ms)
	return vim.wait(ms or 8000, function() return log_has(pat) end, 10)
end

local function wait_file(path, ms)
	return vim.wait(ms or 8000, function()
		local f = io.open(path, 'r')
		if f then
			f:close()
			return true
		end
	end, 10)
end

local function session()
	return dap.session()
end

local function sync(command, args)
	local s = session()
	if not s then return nil, 'no session' end
	local result, err, done
	s:request(command, args, function(e, r)
		err, result, done = e, r, true
	end)
	vim.wait(4000, function() return done end, 20)
	return result, err
end

local function wait_stopped(ms)
	return vim.wait(ms or 8000, function()
		local s = session()
		return s ~= nil and s.stopped_thread_id ~= nil
	end, 10)
end

local function top_frame()
	local result = sync('stackTrace', { threadId = 1 })
	local frame = result and result.stackFrames and result.stackFrames[1]
	if not frame then return nil, 'no frame' end
	return frame
end

local function evaluate(frame, expr)
	local result = sync('evaluate', { expression = expr, frameId = frame.id })
	return result and result.result
end

local function locals(frame)
	local result = sync('scopes', { frameId = frame.id })
	local scope = result and result.scopes and result.scopes[1]
	if not scope then return {}, nil end
	local names = {}
	result = sync('variables', { variablesReference = scope.variablesReference })
	for _, v in ipairs((result and result.variables) or {}) do
		names[v.name] = v.value
	end
	return names, scope.variablesReference
end

local function run_to_completion(pat)
	for _ = 1, 12 do
		-- never continue a running session: nvim-dap would drop into an
		-- interactive picker that blocks headless nvim forever
		local s = session()
		if not (s and s.stopped_thread_id) then return false end
		dap.continue()
		-- the bp fires per loop iteration: wait for either the completion
		-- marker or the next stop, not for the marker alone
		local done, stopped
		local hit = vim.wait(3000, function()
			done = log_has(pat)
			stopped = session() ~= nil and session().stopped_thread_id ~= nil
			return done or stopped
		end, 10)
		if done then return true end
		if not (hit and stopped) then return false end
	end
	return log_has(pat)
end

local function ipc_exec(code)
	local f = assert(io.open(e2e .. '/ipc_code.lua', 'w'))
	f:write(code)
	f:close()
	vim.fn.jobstart({ 'luajit', e2e .. '/ipc_send.lua', ipc_sock, e2e .. '/ipc_code.lua' }, { detach = true })
end

-- ipc code that reports it ran by writing a marker file
local function ipc_marker(name)
	return ([=[local f = io.open('%s/%s', 'w') f:write 'served' f:close()]=]):format(e2e, name)
end

local function assert_stop(tag)
	if not wait_stopped() then
		fail(tag .. ' stopped')
		return nil
	end
	pass(tag .. ' stopped')
	local frame = top_frame()
	if not frame then
		fail(tag .. ' frame present')
		return nil
	end
	eq(tag .. ' frame name', 'work', frame.name)
	eq(tag .. ' frame line', bp_line, frame.line)
	eq(tag .. ' frame path', config_path, frame.source and frame.source.path)
	return frame
end

local function main()
	sdap.setup()

	-- the sai configurations a `dap.continue` pick would offer for the buffer
	local function sai_configs(bufnr)
		local out = {}
		for _, provider in pairs(dap.providers.configs) do
			for _, c in ipairs(provider(bufnr)) do
				if c.type == 'sai' then out[#out + 1] = c end
			end
		end
		return out
	end

	vim.cmd('edit ' .. e2e .. '/other.lua')
	ok('not offered outside swayimg', #sai_configs(vim.api.nvim_get_current_buf()) == 0)

	vim.cmd('edit ' .. config_path)
	local buf = vim.api.nvim_get_current_buf()
	bps.set({}, buf, bp_line)

	local discovered = false
	for _, s in ipairs(sdap.sockets()) do
		if s.path == dbg_sock then discovered = true end
	end
	ok('socket discovered', discovered)

	-- run the offered configuration, as the user's dap bindings do
	local cfg = sai_configs(buf)[1]
	ok('configuration offered', cfg ~= nil)
	if not cfg then return end
	cfg = vim.deepcopy(cfg)
	cfg.pipe = dbg_sock
	dap.run(cfg)

	ok('session created', vim.wait(5000, function() return session() ~= nil end, 50))

	local frame = assert_stop 'init'
	if frame then
		local names, ref = locals(frame)
		ok('init locals present', names.acc ~= nil and names.i ~= nil and names.n ~= nil)
		eq('init local acc', '0', names.acc)
		eq('init evaluate', '3', (evaluate(frame, 'n + i')))
		local _, err = sync('setVariable', { variablesReference = ref, name = 'acc', value = '100' })
		ok('init setVariable', err == nil)
		eq('init setVariable applied', '100', (evaluate(frame, 'acc')))
		local s = session()
		if s and s.stopped_thread_id then
			dap.step_over()
			ok('step stopped', wait_stopped())
			local sframe = top_frame()
			if sframe then eq('step frame name', 'work', sframe.name) end
		else
			fail('step precondition stopped')
		end
	end
	-- setVariable changed acc from 0 to 100: 100 + 1 + 2
	ok('init completed', run_to_completion 'RESULT init 103')
	ok('swayimg ready', wait_log('E2E_READY', 8000))

	-- not `return work(...)`: a tailcall would strip the function name
	ipc_exec("work(3, 'ipc')")
	frame = assert_stop 'ipc'
	if frame then eq('ipc evaluate', '1', (evaluate(frame, 'i'))) end
	ok('ipc completed', run_to_completion 'RESULT ipc 6')

	os.execute('kill -USR1 ' .. pid)
	frame = assert_stop 'signal'
	if frame then eq('signal evaluate', 'signal', (evaluate(frame, 'tag'))) end
	ok('signal completed', run_to_completion 'RESULT signal 10')

	ipc_exec("sai.defer_fn(function() work(5, 'defer') end, 50)")
	frame = assert_stop 'defer'
	if frame then eq('defer evaluate', 'defer', (evaluate(frame, 'tag'))) end
	ok('defer completed', run_to_completion 'RESULT defer 15')

	-- ipc request that arrives while the debuggee is frozen at a bp: the
	-- freeze pump only watches the debug socket, so it must be served after
	-- the resume instead of being lost
	ipc_exec("sai.defer_fn(function() work(6, 'concurrent') end, 50)")
	frame = assert_stop 'concurrent'
	if frame then
		ipc_exec(ipc_marker 'ipc_frozen')
		eq('evaluate while frozen', '2', (evaluate(frame, '1 + 1')))
	end
	ok('concurrent completed', run_to_completion 'RESULT concurrent 21')
	ok('ipc during freeze served', wait_file(e2e .. '/ipc_frozen', 8000))

	-- both sockets receive data in the same instant while running: the two
	-- SIGUSR2s coalesce into one wake that must still serve both
	ipc_exec(ipc_marker 'ipc_burst')
	local th = sync('threads')
	ok('dap during burst', th ~= nil and th.threads ~= nil)
	ok('ipc burst served', wait_file(e2e .. '/ipc_burst', 8000))

	-- breakpoints must still fire after the concurrent traffic
	ipc_exec("sai.defer_fn(function() work(2, 'final') end, 50)")
	frame = assert_stop 'final'
	ok('final completed', run_to_completion 'RESULT final 3')

	ok('all results in log', log_has 'RESULT init 103' and log_has 'RESULT ipc 6'
		and log_has 'RESULT signal 10' and log_has 'RESULT defer 15'
		and log_has 'RESULT concurrent 21' and log_has 'RESULT final 3')

	local disc_done = false
	dap.disconnect({ terminateDebuggee = true }, function() disc_done = true end)
	ok('disconnect responded', vim.wait(5000, function() return disc_done end, 50))
	ok('session closed', vim.wait(5000, function() return session() == nil end, 50))
end

local ran, err = pcall(main)
if not ran then fail('driver crashed', err) end
print(('%d passed, %d failed'):format(passed, failed))
vim.cmd 'qa!'
]==]
	return header .. body
end

local function log_has(pat) return (H.read_file(log_path) or ''):find(pat, 1, true) ~= nil end

local function cleanup()
	local pid = tonumber((H.read_file(pid_path) or ''):match '%d+')
	if H.pid_alive(pid) then
		H.kill(pid)
		H.wait_pid_dead(pid, 3)
	end
end

local function prerequisites()
	local missing = {}
	if not os.getenv 'WAYLAND_DISPLAY' then missing[#missing + 1] = 'a Wayland session' end
	if H.sh 'command -v swayimg' == '' then missing[#missing + 1] = 'swayimg' end
	if H.sh 'command -v nvim' == '' then missing[#missing + 1] = 'nvim' end
	if not H.file_exists(dap_root .. '/lua/dap.lua') then missing[#missing + 1] = 'nvim-dap' end
	if not H.file_exists(nio_root .. '/lua/nio/init.lua') then missing[#missing + 1] = 'nvim-nio' end
	local images = {}
	for line in H.sh('ls ~/Pictures/*/*.jpg 2>/dev/null | head -3'):gmatch '[^\r\n]+' do
		images[#images + 1] = line
	end
	if #images == 0 then missing[#missing + 1] = 'images at ~/Pictures/*/*.jpg' end
	return missing, images
end

local T = {}

local function run_session(images)
	local _, failed_before = H.counts()
	os.execute('rm -rf ' .. e2e)
	os.execute('mkdir -p ' .. e2e .. '/swayimg')

	H.write_file(config_path, config_src)
	H.write_file(e2e .. '/other.lua', '-- not a swayimg file\n')
	H.write_file(ipc_send_path, ipc_send_src)

	local pid = H.spawn(('swayimg --config=%s %s'):format(config_path, table.concat(images, ' ')), log_path, pid_path)
	ok('swayimg started', pid ~= nil and H.wait_for(function() return log_has 'DBG_READY' end, 20))

	local dbg_sock = ('%s/sai-debug-%d.sock'):format(os.getenv 'XDG_RUNTIME_DIR' or '/tmp', pid or -1)
	if not (pid and H.pid_alive(pid)) then
		print('swayimg did not start, see ' .. log_path)
		return
	end

	local offset = assert(config_src:find('acc = acc + i', 1, true))
	local _, nl = config_src:sub(1, offset):gsub('\n', '\n')
	local bp_line = nl + 1

	H.write_file(driver_path, driver_src(pid, bp_line))
	local out = H.sh(('timeout 60 nvim --headless -u %s < /dev/null'):format(driver_path))
	H.write_file(e2e .. '/nvim.log', out)

	for line in out:gmatch '[^\r\n]+' do
		if line:match '^PASS ' or line:match '^FAIL ' or line:match '%d+ passed, %d+ failed' then print(line) end
	end

	local driver_failed = 0
	for line in out:gmatch '[^\r\n]+' do
		if line:match '^FAIL ' then driver_failed = driver_failed + 1 end
	end
	ok('driver completed', out:match '%d+ passed, %d+ failed' ~= nil)
	ok('driver failures', driver_failed == 0)

	if driver_failed > 0 or not out:match '%d+ passed, %d+ failed' then
		print(('--- nvim output (full log at %s/nvim.log) ---'):format(e2e))
		print(out)
	end
	ok('swayimg terminated', H.wait_pid_dead(pid, 10))
	ok('debug socket removed', not H.file_exists(dbg_sock))
	ok('ipc socket removed', not H.file_exists(ipc_sock))
	ok('RESULT init', log_has 'RESULT init 103')
	ok('RESULT ipc', log_has 'RESULT ipc 6')
	ok('RESULT signal', log_has 'RESULT signal 10')
	ok('RESULT defer', log_has 'RESULT defer 15')
	ok('RESULT concurrent', log_has 'RESULT concurrent 21')
	ok('RESULT final', log_has 'RESULT final 3')

	local _, failed = H.counts()
	if failed > 0 then
		print(('--- swayimg output (full log at %s) ---'):format(log_path))
		print(H.read_file(log_path) or '')
		print(('--- debug harness log (%s) ---'):format(dbg_log))
		print(H.read_file(dbg_log) or '')
	end
end

T.dap_session = function(h)
	local missing, images = prerequisites()
	if #missing > 0 then
		h.skip('dap_session', 'requires ' .. table.concat(missing, ', '))
		return
	end
	local ran, err = pcall(run_session, images)
	if not ran then h.fail('dap_session crashed', err) end
	cleanup()
end

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
