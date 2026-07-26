---@diagnostic disable: invisible
--- Tests for sai.lib.ipc
---
--- Usage: luajit tests/ipc.lua
---
--- Run from the sai/ project root directory.

local root = debug.getinfo(1, 'S').source:match('^@(.+)/tests/') or '..'
package.path = root .. '/?.lua;' .. package.path

local ipc = require 'sai.lib.ipc'

local tmp = '/tmp/sai_ipc_test'
local sock = tmp .. '.sock'
local script_path = tmp .. '_server.lua'
local log_path = tmp .. '_server.log'
local pid_path = tmp .. '_server.pid'

----------------------------------------------------------------------
-- Test helpers
----------------------------------------------------------------------

local passed, failed = 0, 0

local function pass(name) passed = passed + 1; print('PASS ' .. name) end
local function fail(name) failed = failed + 1; print('FAIL ' .. name) end

local function eq(name, exp, got)
	if exp ~= got then
		fail(name .. ': expected ' .. tostring(exp) .. ' got ' .. tostring(got))
	else
		pass(name)
	end
end

local function ok(name, cond)
	if cond then pass(name) else fail(name) end
end

----------------------------------------------------------------------
-- Server process management
----------------------------------------------------------------------

local function remove(path) os.remove(path) end

local function cleanup()
	remove(sock)
	remove(script_path)
	remove(log_path)
	remove(pid_path)
end

local function write_script(body)
	local f = assert(io.open(script_path, 'w'))
	f:write(body)
	f:close()
end

local function start_server()
	os.remove(sock)
	os.execute(('luajit %s > %s 2>&1 & echo $! > %s'):format(script_path, log_path, pid_path))
	require('ffi').cdef('int usleep(unsigned int usec);')
	require('ffi').C.usleep(500000)
	local fl = io.open(log_path, 'r')
	local content = fl and fl:read('*a')
	if fl then fl:close() end
	return content and content:find('SERVER_READY') ~= nil
end

local function kill_server()
	local pf = io.open(pid_path, 'r')
	if pf then
		os.execute('kill -9 ' .. pf:read('*n') .. ' 2>/dev/null')
		pf:close()
	end
	cleanup()
end

----------------------------------------------------------------------
-- Client test suite (runs against a running server)
----------------------------------------------------------------------

local function client_suite()
	local c = ipc.client(sock)

	-- auto-enabled, send works immediately
	eq('integer result', '4', c:send("return 2 + 2"))
	eq('string result', 'hello', c:send("return 'hello'"))
	eq('nil result', 'nil', c:send("return nil"))
	eq('side effect', '123', c:send("x = 123; return x"))

	-- compile error
	local r, e = c:send("bad lua !!!")
	eq('compile returns nil', nil, r)
	ok('compile has message', e and e:find('=') ~= nil)

	-- runtime error
	r, e = c:send("error('boom')")
	eq('runtime returns nil', nil, r)
	ok('runtime has message', e and e:find('boom') ~= nil)

	-- table result
	r = c:send("return {1, 2, 3}")
	ok('table result', r and r:match('^table:') ~= nil)

	-- multiple requests on one connection
	for i = 1, 5 do
		r = c:send("return " .. i * 10)
		eq('multi ' .. i, tostring(i * 10), r)
	end

	-- large payload
	local big = string.rep('a', 10000)
	r = c:send("return #[[" .. big .. "]]")
	eq('large payload', tostring(#big), r)

	-- disconnect
	c.enabled = false
	local r_dis, e_dis = c:send("return 1")
	eq('send while disconnected', nil, r_dis)
	eq('disconnect error', 'not connected', e_dis)

	-- reconnect
	c.enabled = true
	r = c:send("return 'back'")
	eq('reconnect', 'back', r)
	c.enabled = false
end

----------------------------------------------------------------------
-- Configuration tests
----------------------------------------------------------------------

print('--- Configuration ---')

-- ignore SIGUSR2 so the auto-enabled server doesn't kill the test process
local ffi = require('ffi')
ffi.cdef[[
typedef void (*sighandler_t)(int);
sighandler_t signal(int, sighandler_t);
]]
local sig = ffi.cast('sighandler_t', function() end)
ffi.C.signal(12, sig)

---@diagnostic disable: missing-parameter
local s = ipc.server('/tmp/x.sock')
ok('enabled by default', s.enabled)
ok('has receive', type(s.receive) == 'function')

local c = ipc.client('/tmp/x.sock')
ok('client enabled by default', c.enabled)
ok('has send method', type(c.send) == 'function')

s.enabled = false
c.enabled = false

local s2 = ipc.server('/tmp/x2.sock')
s2._signal = 'USR1'
ok('signal set to USR1', rawget(s2, '_signal') == 'USR1')
s2._signal = false
ok('signal set to false', rawget(s2, '_signal') == false)
s2.enabled = false

ok('server missing path', not pcall(ipc.server))
ok('server empty path', not pcall(function() ipc.server('') end))
ok('client missing path', not pcall(ipc.client))
ok('client empty path', not pcall(function() ipc.client('') end))
ok('path too long', not pcall(function() ipc.server(string.rep('a', 108)) end))
---@diagnostic enable: missing-parameter

----------------------------------------------------------------------
-- Poll-driven server (no signal, manual receive calls)
----------------------------------------------------------------------

print('--- Poll-driven server ---')

local poll_script = table.concat({
	"local ffi = require('ffi')",
	("package.path = %q .. '/?.lua;' .. package.path"):format(root),
	"local ipc = require 'sai.lib.ipc'",
	"ffi.cdef('int usleep(unsigned int usec);')",
	("local serv = ipc.server(%q)"):format(sock),
	"rawset(serv, '_signal', false)",
	"serv.enabled = false",  -- disable auto-enable, we poll manually
	"serv.enabled = true",   -- re-enable with no O_ASYNC since _signal is false
	"print('SERVER_READY')",
	"io.stdout:flush()",
	"while true do",
	"  serv:receive()",
	"  ffi.C.usleep(1000)",
	"end",
}, '\n') .. '\n'

write_script(poll_script)
ok('server started', start_server())
client_suite()
kill_server()

----------------------------------------------------------------------
-- Signal-driven server
-- Uses O_ASYNC to be notified of connections via SIGUSR2.
-- A raw signal handler sets a flag; the main loop blocks on pause()
-- and calls receive() when a signal arrives.
----------------------------------------------------------------------

print('--- Signal-driven server ---')

local signal_script = table.concat({
	"local ffi = require('ffi')",
	("package.path = %q .. '/?.lua;' .. package.path"):format(root),
	"local ipc = require 'sai.lib.ipc'",
	"ffi.cdef[[",
	"typedef void (*sighandler_t)(int);",
	"sighandler_t signal(int, sighandler_t);",
	"int pause(void);",
	"]]",
	"local got_signal = false",
	"local sh = ffi.cast('sighandler_t', function(s) got_signal = true end)",
	"ffi.C.signal(12, sh)", -- SIGUSR2, must be installed before server enables
	("local serv = ipc.server(%q)"):format(sock),
	"print('SERVER_READY')",
	"io.stdout:flush()",
	"while true do",
	"  ffi.C.pause()",      -- block until signal
	"  if not got_signal then break end",
	"  got_signal = false",
	"  serv:receive()",
	"end",
	"sh:free()",
}, '\n') .. '\n'

write_script(signal_script)
ok('server started', start_server())
client_suite()
kill_server()

----------------------------------------------------------------------

print('\n' .. passed .. ' passed, ' .. failed .. ' failed')
if failed > 0 then os.exit(1) end
print('ALL_OK')
