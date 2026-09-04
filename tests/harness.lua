---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Shared test harness for the tests in this directory.
---Development tool: not used during normal swayimg operation.
---
---A test module returns a table of named test methods, each receiving the
---harness as its only argument:
---
---	local H = require 'harness'
---	local T = {}
---	function T.something(h)
---		h.ok('sky is blue', true)
---	end
---	return T

local ffi = require 'ffi'

ffi.cdef [[
int usleep(unsigned int usec);
int kill(int pid, int sig);
int access(const char *path, int mode);
]]

local H = {}

-- test output is piped through files/logs most of the time: never buffer it
local _print = print
function print(...)
	_print(...)
	io.stdout:flush()
end

-- computed without realpath: the bridge modules owning its cdef can only
-- load after the package paths below are set up
local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
H.dir = dir
H.sai_dir = H.dir:match '^(.*)/'
H.swayimg_dir = H.sai_dir:match '^(.*)/'
package.path = H.dir .. '/?.lua;' .. H.swayimg_dir .. '/?.lua;' .. package.path

-- cdef ownership: sai.bridge.socket owns `timeval` and the socket calls,
-- sai.bridge.debug owns `realpath`/`free`
require 'sai.bridge.socket'
require 'sai.bridge.debug'

ffi.cdef [[
int gettimeofday(struct timeval *tv, void *tz);
]]

local function abs_path(p)
	local r = ffi.C.realpath(p, nil)
	if r == nil then return nil end
	local s = ffi.string(r)
	ffi.C.free(r)
	return s
end
H.abs_path = abs_path

local passed, failed, skipped = 0, 0, 0

function H.pass(name)
	passed = passed + 1
	print('PASS ' .. name)
end

function H.fail(name, extra)
	failed = failed + 1
	print('FAIL ' .. name .. (extra ~= nil and (': ' .. tostring(extra)) or ''))
end

function H.skip(name, reason)
	skipped = skipped + 1
	print('SKIP ' .. name .. (reason ~= nil and (': ' .. reason) or ''))
end

function H.ok(name, cond)
	if cond then
		H.pass(name)
	else
		H.fail(name)
	end
end

function H.eq(name, exp, got)
	if exp == got then
		H.pass(name)
	else
		H.fail(name, 'expected ' .. tostring(exp) .. ' got ' .. tostring(got))
	end
end

function H.contains(name, haystack, needle)
	if haystack and haystack:find(needle, 1, true) then
		H.pass(name)
	else
		H.fail(name, tostring(haystack) .. ' does not contain ' .. tostring(needle))
	end
end

function H.counts() return passed, failed, skipped end

function H.summary() print(('\n%d passed, %d failed, %d skipped'):format(passed, failed, skipped)) end

function H.exit_code() return failed > 0 and 1 or 0 end

function H.now()
	local tv = ffi.new 'struct timeval'
	ffi.C.gettimeofday(tv, nil)
	return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end

---Polls fn every 50ms until it returns truthy or the timeout (seconds,
---default 10) expires; returns the last fn() result.
function H.wait_for(fn, timeout)
	local deadline = H.now() + (timeout or 10)
	while H.now() < deadline do
		if fn() then return true end
		ffi.C.usleep(50000)
	end
	return fn()
end

function H.read_file(path)
	local f = io.open(path, 'r')
	if not f then return nil end
	local t = f:read '*a'
	f:close()
	return t
end

function H.write_file(path, content)
	local f = assert(io.open(path, 'w'))
	f:write(content)
	f:close()
end

function H.file_exists(path) return ffi.C.access(path, 0) == 0 end

---Runs a shell command and returns its combined stdout+stderr.
function H.sh(cmd)
	local p = io.popen(cmd .. ' 2>&1')
	local out = p:read '*a'
	p:close()
	return out
end

---Spawns a shell command in the background with stdout+stderr redirected to
---a log file, writing its pid; returns the pid.
function H.spawn(cmd, log_path, pid_path)
	os.execute(('%s > %s 2>&1 & echo $! > %s'):format(cmd, log_path, pid_path))
	return tonumber((H.read_file(pid_path) or ''):match '%d+')
end

function H.pid_alive(pid) return pid ~= nil and ffi.C.kill(pid, 0) == 0 end

function H.kill(pid, sig)
	if pid then pcall(ffi.C.kill, pid, sig or 9) end
end

function H.wait_pid_dead(pid, timeout)
	return H.wait_for(function() return not H.pid_alive(pid) end, timeout or 10)
end

---Runs all methods of a test module in name order, each pcall-guarded so a
---crash fails the method but does not abort the run. filter, when given,
---receives the method name and selects the methods to run.
function H.run(T, filter)
	local names = {}
	for k, v in pairs(T) do
		if type(v) == 'function' and (not filter or filter(k)) then names[#names + 1] = k end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		print('--- ' .. name .. ' ---')
		local ok, err = pcall(T[name], H)
		if not ok then H.fail(name .. ' crashed', err) end
	end
end

return H
