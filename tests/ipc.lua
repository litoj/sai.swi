---Tests for sai.bridge.ipc: the IPC communication between separate processes,
---end-to-end over the unix socket.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local ok, eq = H.ok, H.eq

local ipc = require 'sai.bridge.ipc'

local fx = H.proc_fixture('ipc', 'SERVER_READY')

local function start_server() return fx.spawn('luajit ' .. fx.script) end

local function client_suite()
	local c = ipc.client(fx.sock)

	-- auto-enabled, send works immediately
	eq('a call returns an integer', '4', c:send 'return 2 + 2')
	eq('a call returns a string', 'hello', c:send "return 'hello'")
	eq('a call returns nil', 'nil', c:send 'return nil')
	eq('a statement chunk round-trips', '123', c:send 'x = 123; return x')

	local r, e = c:send 'bad lua !!!'
	eq('a bad compile returns nil', nil, r)
	ok('a bad compile reports a message', e and e:find '=' ~= nil)

	r, e = c:send "error('boom')"
	eq('a runtime error returns nil', nil, r)
	ok('a runtime error reports a message', e and e:find 'boom' ~= nil)

	r = c:send 'return {1, 2, 3}'
	-- sai.lib.utils overrides tostring globally: tables arrive serialized,
	-- same as inside swayimg
	ok('a table arrives serialized', r and r:find('[1]=1', 1, true) ~= nil)

	for i = 1, 5 do
		r = c:send('return ' .. i * 10)
		eq('sequential call ' .. i .. ' answers', tostring(i * 10), r)
	end

	local big = string.rep('a', 10000)
	r = c:send('return #[[' .. big .. ']]')
	eq('a 10 KB payload round-trips', tostring(#big), r)

	r, e = c:send('return [[' .. string.rep('a', 1024 * 1024 + 1) .. ']]')
	ok('oversize payload dropped', r == nil)
	-- the server hung up on it; the client still reads enabled (the fd died,
	-- not the flag): cycle it fully for a fresh connection
	c.enabled = false
	c.enabled = true

	eq('a function chunk returns its value', '7', c:send(function() return 3 + 4 end))
	r, e = c:send(function() error 'fn boom' end)
	ok('a function runtime error is reported', r == nil and e and e:find 'fn boom' ~= nil)
	ok('c function rejected', select(2, c:send(print)) ~= nil)

	local upv = 41
	eq('function upvalues dropped', 'nil', c:send(function() return upv end))

	c.enabled = false
	local r_dis, e_dis = c:send 'return 1'
	eq('send while disconnected returns nil', nil, r_dis)
	eq('send while disconnected reports not connected', 'not connected', e_dis)

	c.enabled = true
	r = c:send "return 'back'"
	eq('a reconnect restores sending', 'back', r)
	c.enabled = false
	eq('client disable no-op returns false', false, c:set_enabled(false))
end

-- setup runs before the SERVER_READY marker (server creation, signal
-- setup), loop after it
local function server_script(setup, loop)
	return table.concat({
		"local ffi = require('ffi')",
		("package.path = %q .. '/?.lua;' .. %q .. '/?.lua;' .. package.path"):format(H.dir, H.swayimg_dir),
		"local ipc = require 'sai.bridge.ipc'",
		"local H = require 'harness' -- the poll loop's usleep",
		setup,
		"print('SERVER_READY')",
		'io.stdout:flush()',
		loop,
	}, '\n') .. '\n'
end

local T = {}

-- ---------------------------------------------------------------------------
-- Generic unit tests
-- ---------------------------------------------------------------------------

T.config = fx.scenario(function()
	-- serving is exercised end-to-end by the poll_driven/signal_driven
	-- scenarios below; here only the config semantics
	local s2 = ipc.server '/tmp/sai_ipc_x2.sock'
	s2._signal = 'USR1'
	ok('signal set to USR1', s2._signal == 'USR1')
	s2._signal = false
	ok('signal set to false', s2._signal == false)
	s2.enabled = false

	ok('server errors on a missing path', not pcall(ipc.server))
	ok('server errors on an empty path', not pcall(function() ipc.server '' end))
	ok('client errors on a missing path', not pcall(ipc.client))
	ok('client errors on an empty path', not pcall(function() ipc.client '' end))
	ok('an overlong socket path errors', not pcall(function() ipc.server(string.rep('a', 108)) end))

	-- re-setting the same value is a no-op, loudly marked by the false
	eq('server enable no-op returns false', false, s2:set_enabled(false))

	-- unknown field writes must error, not silently land
	ok('unknown field errors', not pcall(function() s2.not_a_field = 1 end))
end)

-- ---------------------------------------------------------------------------
-- Usability tests: a client and a server process over the unix socket
-- ---------------------------------------------------------------------------

T.poll_driven = fx.scenario(function()
	-- no O_ASYNC: the main loop polls the socket itself
	H.write_file(
		fx.script,
		server_script(
			table.concat({
				('local serv = ipc.server(%q)'):format(fx.sock),
				'serv._signal = false',
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

T.signal_driven = fx.scenario(function()
	-- O_ASYNC notifies of connections via SIGUSR2; the signal is blocked
	-- and consumed with sigwait: a pause()-plus-flag loop loses the wakeup
	-- when the signal lands between the flag check and the pause itself
	H.write_file(
		fx.script,
		server_script(
			[==[
ffi.cdef[[
typedef void (*sighandler_t)(int);
typedef struct { unsigned long __val[16]; } sigset_t;
sighandler_t signal(int, sighandler_t);
int sigemptyset(sigset_t *set);
int sigaddset(sigset_t *set, int signum);
int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
int sigwait(const sigset_t *set, int *sig);
]]
-- the handler only satisfies arm_fd's SigCgt check: USR2 must look caught
ffi.C.signal(12, ffi.cast('sighandler_t', function() end))
local mask = ffi.new 'sigset_t'
ffi.C.sigemptyset(mask)
ffi.C.sigaddset(mask, 12) -- SIGUSR2
ffi.C.sigprocmask(0, mask, nil) -- 0 = SIG_BLOCK
]==]
				.. '\n'
				.. ('local serv = ipc.server(%q)'):format(fx.sock),
			table.concat({
				"local sig = ffi.new('int[1]')",
				'while true do',
				'  if ffi.C.sigwait(mask, sig) ~= 0 then break end',
				'  serv:poll(0)',
				'end',
			}, '\n')
		)
	)
	ok('server started', start_server())
	client_suite()
end)

H.maybe_standalone(T)

return T
