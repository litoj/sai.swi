---Tests for sai.bridge.ipc: the IPC communication between separate processes,
---end-to-end over the unix socket.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local ok, eq = H.ok, H.eq

local ipc = require 'sai.bridge.ipc'

local tmp = '/tmp/sai_ipc_test'
local sock = tmp .. '.sock'
local script_path = tmp .. '_server.lua'
local log_path = tmp .. '_server.log'
local pid_path = tmp .. '_server.pid'

local function cleanup()
	os.remove(sock)
	os.remove(script_path)
	os.remove(log_path)
	os.remove(pid_path)
end

local function start_server()
	os.remove(sock)
	H.spawn('luajit ' .. script_path, log_path, pid_path)
	return H.wait_for(function() return (H.read_file(log_path) or ''):find('SERVER_READY', 1, true) ~= nil end, 10)
end

local function kill_server() H.kill(tonumber((H.read_file(pid_path) or ''):match '%d+')) end

-- A test method: always kills the server and removes its files afterwards,
-- ipc runs without the rest of sai: the parts it touches
local function mock_sai()
	rawset(_G, 'sai', {
		log = function(m) print(m) end,
		eventloop = { subscribe = function() return {} end, unsubscribe = function() end },
	})
end

-- even when the scenario crashes midway
local function scenario(fn)
	return function()
		local saved_sai = rawget(_G, 'sai')
		mock_sai()
		local ran, err = pcall(fn)
		rawset(_G, 'sai', saved_sai)
		kill_server()
		cleanup()
		if not ran then H.fail('scenario crashed', err) end
	end
end

local function client_suite()
	local c = ipc.client(sock)

	-- auto-enabled, send works immediately
	eq('integer result', '4', c:send 'return 2 + 2')
	eq('string result', 'hello', c:send "return 'hello'")
	eq('nil result', 'nil', c:send 'return nil')
	eq('side effect', '123', c:send 'x = 123; return x')

	local r, e = c:send 'bad lua !!!'
	eq('compile returns nil', nil, r)
	ok('compile has message', e and e:find '=' ~= nil)

	r, e = c:send "error('boom')"
	eq('runtime returns nil', nil, r)
	ok('runtime has message', e and e:find 'boom' ~= nil)

	r = c:send 'return {1, 2, 3}'
	-- sai.lib.utils overrides tostring globally: tables arrive serialized,
	-- same as inside swayimg
	ok('table result', r and r:find('[1]=1', 1, true) ~= nil)

	for i = 1, 5 do
		r = c:send('return ' .. i * 10)
		eq('multi ' .. i, tostring(i * 10), r)
	end

	local big = string.rep('a', 10000)
	r = c:send('return #[[' .. big .. ']]')
	eq('large payload', tostring(#big), r)

	eq('function result', '7', c:send(function() return 3 + 4 end))
	r, e = c:send(function() error 'fn boom' end)
	ok('function runtime error', r == nil and e and e:find 'fn boom' ~= nil)
	ok('c function rejected', select(2, c:send(print)) ~= nil)

	local upv = 41
	eq('function upvalues dropped', 'nil', c:send(function() return upv end))

	c.enabled = false
	local r_dis, e_dis = c:send 'return 1'
	eq('send while disconnected', nil, r_dis)
	eq('disconnect error', 'not connected', e_dis)

	c.enabled = true
	r = c:send "return 'back'"
	eq('reconnect', 'back', r)
	c.enabled = false
end

-- setup runs before the SERVER_READY marker (server creation, signal
-- setup), loop after it
local function server_script(setup, loop)
	return table.concat({
		"local ffi = require('ffi')",
		("package.path = %q .. '/?.lua;' .. package.path"):format(H.swayimg_dir),
		"local ipc = require 'sai.bridge.ipc'",
		"ffi.cdef('int usleep(unsigned int usec);')",
		setup,
		"print('SERVER_READY')",
		'io.stdout:flush()',
		loop,
	}, '\n') .. '\n'
end

local T = {}

T.config = scenario(function()
	-- the auto-enabled servers below arm O_ASYNC with SIGUSR2: ignore it so
	-- their traffic cannot kill this test process
	local ffi = require 'ffi'
	ffi.cdef [[
	typedef void (*sighandler_t)(int);
	sighandler_t signal(int, sighandler_t);
	]]
	ffi.C.signal(12, ffi.cast('sighandler_t', function() end))

	local s = ipc.server '/tmp/sai_ipc_test_x.sock'
	ok('enabled by default', s.enabled)
	ok('has poll', type(s.poll) == 'function')

	local c = ipc.client '/tmp/sai_ipc_test_x.sock'
	ok('client enabled by default', c.enabled)
	ok('has send method', type(c.send) == 'function')

	s.enabled = false
	c.enabled = false

	local s2 = ipc.server '/tmp/sai_ipc_test_x2.sock'
	s2._signal = 'USR1'
	ok('signal set to USR1', rawget(s2, '_signal') == 'USR1')
	s2._signal = false
	ok('signal set to false', rawget(s2, '_signal') == false)
	s2.enabled = false

	ok('server missing path', not pcall(ipc.server))
	ok('server empty path', not pcall(function() ipc.server '' end))
	ok('client missing path', not pcall(ipc.client))
	ok('client empty path', not pcall(function() ipc.client '' end))
	ok('path too long', not pcall(function() ipc.server(string.rep('a', 108)) end))
end)

T.poll_driven = scenario(function()
	-- no O_ASYNC: the main loop polls the socket itself
	H.write_file(
		script_path,
		server_script(
			table.concat({
				('local serv = ipc.server(%q)'):format(sock),
				"rawset(serv, '_signal', false)",
				'serv.enabled = false',
				'serv.enabled = true',
			}, '\n'),
			table.concat({
				'while true do',
				'  serv:poll(0)',
				'  ffi.C.usleep(1000)',
				'end',
			}, '\n')
		)
	)
	ok('server started', start_server())
	client_suite()
end)

T.signal_driven = scenario(function()
	-- O_ASYNC notifies of connections via SIGUSR2; the handler sets a flag
	-- and the main loop polls the socket after waking up from pause()
	H.write_file(
		script_path,
		server_script(
			[==[
ffi.cdef[[
typedef void (*sighandler_t)(int);
sighandler_t signal(int, sighandler_t);
int pause(void);
]]
local got_signal = false
ffi.C.signal(12, ffi.cast('sighandler_t', function() got_signal = true end))
]==]
				.. '\n'
				.. ('local serv = ipc.server(%q)'):format(sock),
			table.concat({
				'while true do',
				'  ffi.C.pause()',
				'  if not got_signal then break end',
				'  got_signal = false',
				'  serv:poll(0)',
				'end',
			}, '\n')
		)
	)
	ok('server started', start_server())
	client_suite()
end)

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
