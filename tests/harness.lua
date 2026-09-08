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
int *__errno_location(void);
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

-- cdef ownership: sai.bridge.cdef owns `pid_t`/`getpid`, sai.bridge.socket
-- owns `timeval` and the socket calls, sai.bridge.debug owns `realpath`/`free`
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

-- output is only inspected on failure: print the per-assertion noise (PASS
-- lines, method headers) only when explicitly asked to (VERBOSE=1)
local verbose = os.getenv 'VERBOSE' ~= nil
H.verbose = verbose

function H.pass(name)
	passed = passed + 1
	if verbose then print('PASS ' .. name) end
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

function H.pid_alive(pid)
	if pid == nil then return false end
	if ffi.C.kill(pid, 0) == 0 then return true end
	-- EPERM: the process exists but is not ours to signal (e.g. root-owned)
	return ffi.C.__errno_location()[0] == 1
end

function H.kill(pid, sig)
	if pid then pcall(ffi.C.kill, pid, sig or 9) end
end

function H.wait_pid_dead(pid, timeout)
	return H.wait_for(function() return not H.pid_alive(pid) end, timeout or 10)
end

-- ---------------------------------------------------------------------------
-- Spawned-process fixtures: the shared lifecycle of the test modules that
-- drive real child processes
-- ---------------------------------------------------------------------------

---A child-process fixture under /tmp: the script/log/pid/sock files named
---after `name`, plus the kill/cleanup/scenario machinery around them. The
---socket is unlinked before every spawn; `fx.spawn` waits for the ready
---marker in the log and returns whether it appeared. `fx.track` extends the
---cleanup set with extra files (secondary logs and the like).
---@param name string file prefix: /tmp/sai_<name>...
---@param ready string log marker the child prints once it is up
---@return table fx .sock .script .log .pid .spawn .kill .log_has .wait_log .track .cleanup .scenario
function H.proc_fixture(name, ready)
	local fx = {
		sock = ('/tmp/sai_%s.sock'):format(name),
		script = ('/tmp/sai_%s_script.lua'):format(name),
		log = ('/tmp/sai_%s.log'):format(name),
		pid = ('/tmp/sai_%s.pid'):format(name),
	}
	local tracked = {}
	local child

	function fx.spawn(cmd)
		os.remove(fx.sock)
		child = H.spawn(cmd, fx.log, fx.pid)
		return H.wait_for(function() return fx.log_has(ready) end, 15)
	end

	function fx.kill() H.kill(child) end

	function fx.log_has(pat) return (H.read_file(fx.log) or ''):find(pat, 1, true) ~= nil end

	function fx.wait_log(pat, timeout)
		return H.wait_for(function() return fx.log_has(pat) end, timeout)
	end

	function fx.track(path) tracked[#tracked + 1] = path end

	function fx.cleanup()
		for _, f in ipairs { fx.sock, fx.script, fx.log, fx.pid } do
			os.remove(f)
		end
		for _, f in ipairs(tracked) do
			os.remove(f)
		end
	end

	---A test method: always kills the child and removes its files afterwards,
	---even when the scenario crashes midway
	function fx.scenario(fn)
		return function(h)
			local ran, err = pcall(fn, h)
			fx.kill()
			fx.cleanup()
			if not ran then error(err, 0) end
		end
	end

	return fx
end

---The sai-owned socket files currently on disk: every socket the tests (or
---the bridges they drive) create is named after sai and lives in /tmp or the
---runtime dir. Foreign sockets are not tracked.
local function sai_sockets()
	local out = {}
	local dirs = { os.getenv 'XDG_RUNTIME_DIR' or '/tmp', '/tmp' }
	for _, d in ipairs(dirs) do
		for path in H.sh(('ls %s/*sai*.sock 2>/dev/null'):format(d)):gmatch '[^\r\n]+' do
			out[path] = true
		end
	end
	return out
end

---Every socket a method brought up must go with its owner: a file left
---behind is a leak (a dead owner cannot unlink anymore, so killed
---processes count too - only the sockets of live owners are excused).
---`before` is the snapshot taken when the method started; leaked files are
---reported as failures and swept so they cannot accumulate system-wide.
function H.no_socket_leaks(tag, before)
	local leaked = {}
	for path in pairs(sai_sockets()) do
		if not before[path] then
			local pid = tonumber(path:match 'sai%-debug%-(%d+)%.sock$')
			if not (pid and H.pid_alive(pid)) then leaked[#leaked + 1] = path end
		end
	end
	if #leaked == 0 then return end
	table.sort(leaked)
	H.fail(tag .. ' socket leak', table.concat(leaked, ', '))
	for _, path in ipairs(leaked) do
		os.remove(path)
	end
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
		if verbose then print('--- ' .. name .. ' ---') end
		local sockets = sai_sockets()
		local ok, err = pcall(T[name], H)
		if not ok then H.fail(name .. ' crashed', err) end
		H.no_socket_leaks(name, sockets)
	end
end

---Runs the module standalone (luajit tests/foo.lua) unless the test runner
---already drives it: prints the summary and exits with the harness code.
function H.maybe_standalone(T)
	if _G._TEST_RUNNER then return end
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

-- ---------------------------------------------------------------------------
-- Raw api stubs: stand-ins for the C side of swayimg, over which the whole
-- sai api stack can run under plain luajit
-- ---------------------------------------------------------------------------

---A stand-in for a raw swayimg mode: any method read resolves to a no-op
---function, so no test needs to enumerate the api surface itself. `fields`
---lands on the stub directly (data fields or method overrides) and wins
---over the generic no-op.
function H.raw_mode(fields)
	return setmetatable(fields or {}, {
		__index = function()
			return function() end
		end,
	})
end

---The image every mode stub serves from get_image: a fresh table per call,
---no test can corrupt a shared one.
function H.stub_image() return { width = 500, height = 400, index = 1, path = 'stub', meta = {} } end

---A stand-in for the raw swayimg global: the three mode stubs plus the
---fields every part of the api stack reads. `modes` replaces the default
---mode stubs (tests/help.lua records the binds through its own).
function H.raw_swayimg(modes)
	modes = modes or {}
	return {
		mode = 'viewer',
		viewer = modes.viewer or H.raw_mode { get_image = H.stub_image },
		slideshow = modes.slideshow or H.raw_mode(),
		gallery = modes.gallery or H.raw_mode {
			get_image = H.stub_image,
			-- the help modes read these for their backdrop sizing
			thumb_size = 128,
			padding_size = 10,
		},
		imagelist = { size = 0 },
		text = {},
		defer = function() end,
		on_window_resize = function() end,
		get_window_size = function() return { width = 800, height = 600 } end,
	}
end

---Drops the cached sai modules except the bridge: the lib modules bind the
---eventloop (and each other) at require time, so a cached one keeps firing
---into a dead eventloop. The bridge stays - its ffi cdefs cannot re-run.
function H.drop_sai_stack()
	for name in pairs(package.loaded) do
		if name:sub(1, 4) == 'sai.' and name:sub(1, 11) ~= 'sai.bridge.' then package.loaded[name] = nil end
	end
end

---Binds a pristine api stack to the given raw swayimg stub: whichever
---module ran before this one leaves its records on the shared registry,
---keyed by that stack's objects - a fresh bind gets a clean namespace.
---Installs the stub as the swayimg global (the api modules resolve it at
---require time); the caller restores the raw globals afterwards, after
---everything that must load against the stub has loaded. Returns the stack
---and the sai proxy the module installed as the global.
function H.fresh_api_stack(swi_stub)
	H.drop_sai_stack()
	_G.swayimg = swi_stub
	local stack = require 'sai.api.init'
	return stack, _G.sai
end

---A full api stack over recording mode stubs, for the tests that exercise
---the mode machinery: the startup a real swayimg session runs (init, the
---default binds, the key help mode), under plain luajit. The binds each raw
---mode receives land in env.raw_binds ('mode:bind' -> callback);
---env.with_env(fn) returns a test method that lends the stubbed globals
---for the duration of its run. `mods` lists extra modules to load against
---the installed stub (those that bind the stack's objects at require time).
---@param mods string[]?
---@return table env .sai, .sai_proxy, .swayimg, .key_help, .raw_binds, .with_env, .mods
function H.recording_stack(mods)
	local raw_binds = {}
	local function recording_mode(name)
		return H.raw_mode {
			on_key = function(b, fn) raw_binds[name .. ':' .. b] = fn end,
			on_mouse = function(b, fn) raw_binds[name .. ':' .. b] = fn end,
			get_image = H.stub_image,
		}
	end

	local resize_cb
	local swayimg = H.raw_swayimg {
		viewer = recording_mode 'viewer',
		slideshow = recording_mode 'slideshow',
		gallery = recording_mode 'gallery',
	}
	swayimg.on_window_resize = function(fn) resize_cb = fn end
	swayimg.gallery.thumb_size = 128 -- read by the help modes for the backdrop sizing
	swayimg.gallery.padding_size = 10

	local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')
	local sai, sai_proxy = H.fresh_api_stack(swayimg)
	resize_cb() -- app initialization: also registers the default binds
	local key_help = require 'sai.mode.key_help'
	local loaded = { ['sai.mode.key_help'] = key_help }
	for _, name in ipairs(mods or {}) do
		loaded[name] = require(name)
	end

	-- the api stack and the modes read the globals at runtime, so lend them
	-- the stubbed environment just for the duration of each method
	_G.swayimg, _G.sai = old_swi, old_sai

	local function with_env(fn)
		return function(h)
			_G.swayimg, _G.sai = swayimg, sai_proxy
			local ran, err = pcall(fn, h)
			_G.swayimg, _G.sai = old_swi, old_sai
			if not ran then error(err, 0) end
		end
	end

	return {
		sai = sai,
		sai_proxy = sai_proxy,
		swayimg = swayimg,
		key_help = key_help,
		raw_binds = raw_binds,
		with_env = with_env,
		mods = loaded,
	}
end

return H
