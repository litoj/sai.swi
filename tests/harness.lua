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
---
---Counting is per usecase (method), not per assertion. A method fails when
---any of its checks fails or it crashes, skips when it skipped and nothing
---failed, and fails when it ran no check at all; a failure beats a skip.
---A method's output is buffered and shown only for a failed or skipped
---usecase (VERBOSE=1 shows every method live). A failed check leads with
---its `path:line`. It prints the compared objects where they differ.
---A harness-detected failure carries no site: its reason names the place.

local ffi = require 'ffi'

ffi.cdef [[
int usleep(unsigned int usec);
int kill(int pid, int sig);
int access(const char *path, int mode);
int *__errno_location(void);
]]

local H = {}

-- the real output: every write the per-test buffer lets through flushes here
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

-- the summary counts usecases (methods), not assertions
local passed, failed, skipped = 0, 0, 0

-- the method H.run currently runs: its checks decide the method's status
-- (a failure beats a skip, no check at all fails it). Outside H.run no
-- method runs, so H.fail counts the usecase itself (module load errors)
local cur

-- every check result lands in the running method's buffer, so a failed
-- usecase can dump its full log; VERBOSE=1 keeps the output live instead
local verbose = os.getenv 'VERBOSE' ~= nil
H.verbose = verbose

function H.pass(name)
	if cur then cur.passes = cur.passes + 1 end
	print('PASS ' .. name)
end

-- self source for the walk below: its own frames are never the check site
local harness_src = debug.getinfo(1, 'S').source

-- check site: the first frame outside this file, so a wrapper reports the test.
-- C frames skipped: they carry no line, a pcall(h.ok, ...) site would read `=[C]:-1`.
-- sai_dir stripped: the runner loads by absolute path, the repo names `tests/foo.lua`.
local function fail_site()
	for level = 2, math.huge do
		local info = debug.getinfo(level, 'Sl')
		if not info then return end
		if info.what ~= 'C' and info.source ~= harness_src then
			local src = info.source:match '^@(.+)' or info.source
			if src:sub(1, #H.sai_dir + 1) == H.sai_dir .. '/' then src = src:sub(#H.sai_dir + 2) end
			return src .. ':' .. info.currentline
		end
	end
end

-- FAIL line with an optional site prefix.
-- internal callers pass none: no check ran, the reason already names the place.
-- load errors keep it: the err names the module, the site names the reporter.
local function emit_fail(name, extra, site)
	if cur then
		cur.fails = cur.fails + 1
	else
		failed = failed + 1
	end
	print('FAIL ' .. (site and site .. ': ' or '') .. name .. (extra ~= nil and (': ' .. tostring(extra)) or ''))
end

function H.fail(name, extra) emit_fail(name, extra, fail_site()) end

function H.skip(name, reason)
	if cur then cur.skips = cur.skips + 1 end
	print('SKIP ' .. name .. (reason ~= nil and (': ' .. reason) or ''))
end

function H.ok(name, cond)
	if cond then
		H.pass(name)
	else
		H.fail(name, 'got ' .. tostring(cond))
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

function H.not_contains(name, haystack, needle)
	if not haystack or not haystack:find(needle, 1, true) then
		H.pass(name)
	else
		H.fail(name, tostring(haystack) .. ' contains ' .. tostring(needle))
	end
end

function H.summary() print(('\n%d passed, %d failed, %d skipped'):format(passed, failed, skipped)) end

function H.exit_code() return failed > 0 and 1 or 0 end

function H.now()
	local tv = ffi.new 'struct timeval'
	ffi.C.gettimeofday(tv, nil)
	return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end

---Polls fn every 10ms until it returns truthy or the timeout (seconds,
---default 1) expires; returns the last fn() result. All tests are instant,
---so a wait past 1s is a failure, not patience.
function H.wait_for(fn, timeout)
	local deadline = H.now() + (timeout or 1)
	while H.now() < deadline do
		if fn() then return true end
		ffi.C.usleep(10000)
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
function H.shell(cmd)
	local p = assert(io.popen(cmd .. ' 2>&1'), 'shell failed')
	local out = p:read '*a'
	p:close()
	return out
end

---Captures every notify fired inside fn (a log without a file routes through
---notify too), so a check names the reporting file instead of matching text.
---@param sai_proxy table
---@param fn fun()
---@return table[] records: { msg = string, trace = string, location = string? }
function H.capture_notify(sai_proxy, fn)
	local recs = {}
	local old = sai_proxy.notify
	-- pass the rest through: a hooked capture must not mute the location
	-- routing; the trace leads with the hook frame, the caller (the code
	-- under test) right below it
	sai_proxy.notify = function(msg, timeout, location)
		recs[#recs + 1] = { msg = tostring(msg), trace = debug.traceback(), location = location }
		return old(msg, timeout, location)
	end
	local ran, err = pcall(fn)
	sai_proxy.notify = old
	if not ran then error(err, 0) end
	return recs
end

---Spawns a shell command in the background with stdout+stderr redirected to
---a log file, writing its pid; returns the pid.
function H.spawn(cmd, log_path, pid_path)
	os.execute(('%s > %s 2>&1 & echo $! > %s'):format(cmd, log_path, pid_path))
	return tonumber((H.read_file(pid_path) or ''):match '%d+')
end

function H.pid_alive(pid)
	if pid == nil then return false end
	-- spawn(&) orphans children: kill(0) counts zombies as alive while
	-- the PID-1 reaper lingers - a zombie already exited, in either case
	local stat = H.read_file(('/proc/%d/stat'):format(pid))
	if stat and (stat:gsub('^.*%)%s*', '')):match '^%a' == 'Z' then return false end
	if ffi.C.kill(pid, 0) == 0 then return true end
	-- EPERM: the process exists but is not ours to signal (e.g. root-owned)
	return ffi.C.__errno_location()[0] == 1
end

function H.kill(pid, sig)
	if pid then pcall(ffi.C.kill, pid, sig or 9) end
end

function H.wait_pid_dead(pid, timeout)
	return H.wait_for(function() return not H.pid_alive(pid) end, timeout or 1)
end

-- ---------------------------------------------------------------------------
-- Spawned-process fixtures: the shared lifecycle of the test modules that
-- drive real child processes
-- ---------------------------------------------------------------------------

---Child fixture under /tmp (script/log/pid/sock); spawn waits for the ready marker.
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
		return H.wait_for(function() return fx.log_has(ready) end, 1)
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
---runtime dir. Foreign sockets are not tracked. H.shell's stderr capture would
---turn ls's no-match error into a bogus path, so only existing files count.
local function sai_sockets()
	local out = {}
	local dirs = { os.getenv 'XDG_RUNTIME_DIR' or '/tmp', '/tmp' }
	for _, d in ipairs(dirs) do
		for path in H.shell(('ls %s/*sai*.sock 2>/dev/null'):format(d)):gmatch '[^\r\n]+' do
			if H.file_exists(path) then out[path] = true end
		end
	end
	return out
end

---Debug-harness sockets carry their owner pid: alive owners are not leaks.
local debug_sock_pid_pat = 'sai%-debug%-(%d+)%.sock$'

---Per-method socket leak check against the `before` snapshot; leaks fail and sweep.
function H.no_socket_leaks(tag, before)
	local leaked = {}
	for path in pairs(sai_sockets()) do
		if not before[path] then
			local pid = tonumber(path:match(debug_sock_pid_pat))
			if not (pid and H.pid_alive(pid)) then leaked[#leaked + 1] = path end
		end
	end
	if #leaked == 0 then return end
	table.sort(leaked)
	emit_fail(tag .. ' socket leak', table.concat(leaked, ', '))
	for _, path in ipairs(leaked) do
		os.remove(path)
	end
end

---One buffered output line: same stringification as the C print().
local function to_line(...)
	local t = {}
	for i = 1, select('#', ...) do
		t[#t + 1] = tostring((select(i, ...)))
	end
	return table.concat(t, '\t')
end

---Runs all methods of a test module in name order, each pcall-guarded so a
---crash fails the method but does not abort the run. filter, when given,
---receives the method name and selects the methods to run.
---Each method is one counted usecase: it fails when any check fails or it
---crashes, skips when it only skipped, and fails when it ran no check at
---all. A method's whole output (check results, stray prints) is buffered
---and dumped only when the usecase fails or skips; VERBOSE=1 keeps the
---output of every method live.
function H.run(T, filter)
	local names = {}
	for k, v in pairs(T) do
		if type(v) == 'function' and (not filter or filter(k)) then names[#names + 1] = k end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		if verbose then print('--- ' .. name .. ' ---') end
		local sockets = sai_sockets()

		local log, real
		if not verbose then
			log = {}
			real = print
			rawset(_G, 'print', function(...) log[#log + 1] = to_line(...) end)
		end

		cur = { fails = 0, skips = 0, passes = 0 }
		local ok, err = pcall(T[name], H)
		if not ok then emit_fail(name .. ' crashed', err) end
		H.no_socket_leaks(name, sockets)
		-- a method without a single check cannot have tested its usecase
		if cur.fails == 0 and cur.skips == 0 and cur.passes == 0 then
			emit_fail(name .. ' no checks', 'a test without checks is not a test')
		end
		local m = cur
		cur = nil

		-- a failure beats a skip
		if m.fails > 0 then
			failed = failed + 1
		elseif m.skips > 0 then
			skipped = skipped + 1
		else
			passed = passed + 1
		end

		if log then
			rawset(_G, 'print', real)
			if m.fails > 0 or m.skips > 0 then
				print('--- ' .. name .. ' ---')
				for _, l in ipairs(log) do
					print(l)
				end
			end
		end
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
-- Raw api doubles: they model what the app really provides. Anything beyond
-- Lua's reach (decoded pixels, C++ timers) stays an explicit seam,
-- documented where it is used.
-- ---------------------------------------------------------------------------

function H.raw_mode(fields)
	return setmetatable(fields or {}, {
		__index = function()
			return function() end
		end,
	})
end

---Pixels and exif decoding live in C++ (the seam); fresh table per call.
---The path stays `'stub'`: path-dependent flows need the recording stack's
---current-image model instead.
function H.stub_image() return { width = 500, height = 400, index = 1, path = 'stub', meta = {} } end

---For stacks that never touch the imagelist (api, reconfigurer, fresh-env
---tests); list- or image-dependent tests need the recording stack below.
---`modes` replaces the default mode doubles (tests/help.lua records the
---binds through its own).
function H.raw_swayimg(modes)
	modes = modes or {}
	return {
		mode = 'viewer',
		overlay = true, -- like the app's default: a lone resize is the full init, not the dedup marker
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

---Exit-asserting os.execute: stock luajit returns the raw exit code, while
---lua52-compatible luajit builds (debian/ubuntu) return ok,"exit",code
---@param cmd string
---@param msg string? assert failure message
function H.exec(cmd, msg)
	local ok = os.execute(cmd)
	assert(ok == 0 or ok == true, msg or ('command failed: ' .. cmd))
end

---Set a fixture file's mtime to a fixed epoch: the raw list stats the real
---file (like the app), so ordering tests need deterministic filesystem times.
---@param path string
---@param epoch integer unix timestamp
function H.touch(path, epoch) H.exec(("touch -d @%d '%s'"):format(epoch, path:gsub("'", "'\\''"))) end

---Copy committed fixtures to /tmp and pin fixed-epoch mtimes: ordering
---tests need deterministic filesystem times but must not dirty the repo.
---@param specs table[] { name=basename, epoch=unix timestamp? }; fixture names are unique across modules (sort_* vs filter_*)
---@return string[] /tmp paths in spec order, the basename kept so basename assertions hold
function H.fixture_copy(specs)
	local out = {}
	for i, s in ipairs(specs) do
		local dst = '/tmp/' .. s.name
		H.exec(
			("cp '%s' '%s'"):format((H.dir .. '/fixtures/' .. s.name):gsub("'", "'\\''"), dst:gsub("'", "'\\''")),
			'fixture copy failed: ' .. s.name
		)
		if s.epoch then H.touch(dst, s.epoch) end
		out[i] = dst
	end
	return out
end

---Writable pointer stub for the modes reading swayimg.get_mouse_pos. One shared
---closure: the api proxy caches the getter on first read, so a plain field swap would not take.
---@return fun(x?: integer|table, y?: integer) at move: coords, a pos table, or nothing (clears); starts nil, like a pointer never moved
function H.mouse_stub(swayimg)
	local pos
	swayimg.get_mouse_pos = function() return pos end
	return function(x, y)
		if type(x) == 'table' then
			pos = x
		elseif x == nil then
			pos = nil
		else
			pos = { x = x, y = y }
		end
	end
end

---Fire a recorded viewer bind, the way the app delivers a keypress.
function H.press(raw_binds, bind) raw_binds['viewer:' .. bind]() end

---Deliver one wheel tick to the mode's on_scroll handler, as the app
---does for a scroll event. `dir` names the event
---('ScrollUp'/'ScrollDown'); magnitudes are not simulated.
function H.wheel(raw_binds, kmods, dir) raw_binds['viewer:scroll'](kmods, 0, dir == 'ScrollDown' and 1 or -1) end

---Numbered item lines for pager/selector window tests.
function H.items(n)
	local out = {}
	for i = 1, n do
		out[i] = 'item' .. i
	end
	return out
end

---Drops the cached sai modules except the bridge: the lib modules bind the
---eventloop (and each other) at require time, so a cached one keeps firing
---into a dead eventloop. The bridge stays - its ffi cdefs cannot re-run.
function H.drop_sai_stack()
	for name in pairs(package.loaded) do
		if name:sub(1, 4) == 'sai.' and name:sub(1, 11) ~= 'sai.bridge.' then package.loaded[name] = nil end
	end
end

---Binds a pristine api stack to the given raw double.
function H.fresh_api_stack(swi_stub)
	H.drop_sai_stack()
	_G.swayimg = swi_stub
	local stack = require 'sai.api.init'
	-- the mouse geometry stays on its uncalibrated defaults: the test
	-- coordinates assume them, a real font lookup would be machine-dependent
	require('sai.bridge.mouse_box')._stub_metrics = function() end
	return stack, _G.sai
end

---Real startup over doubles, recording the binds.
---@param mods string[]?
---@return table env .sai, .sai_proxy, .swayimg, .key_help, .raw_binds, .with_env, .mods
function H.recording_stack(mods)
	local raw_binds = {}
	-- sai reaches the app-side list only through its public imagelist api,
	-- the app side only through the mode actions below (open/mark).
	-- Size and mtime come from the real filesystem on every read, like the app.
	local entries = {}
	local current = false
	local raw_il
	local function find(path)
		for i, e in ipairs(entries) do
			if e.path == path then return i, e end
		end
	end
	local function stat(path)
		local p = io.popen("stat -c '%Y %s' '" .. path:gsub("'", "'\\''") .. "'")
		if not p then return nil end
		local out = p:read '*a'
		p:close()
		local mt, sz = out:match '(%d+) (%d+)'
		return mt and tonumber(mt), sz and tonumber(sz)
	end
	raw_il = {
		size = 0,
		-- fresh bare tables per call, like the app: no meta, real stat fields
		get = function()
			local out = {}
			for i, e in ipairs(entries) do
				local mt, sz = stat(e.path)
				out[i] = { path = e.path, index = i, size = sz, mtime = mt, mark = e.mark }
			end
			return out
		end,
		clear = function()
			entries = {}
			raw_il.size = 0
			current = false
		end,
		add = function(x)
			for _, p in ipairs(type(x) == 'table' and x or { x }) do
				if not find(p) then entries[#entries + 1] = { path = p, mark = false } end
			end
			raw_il.size = #entries
		end,
		remove = function(x)
			local rm = {}
			for _, p in ipairs(type(x) == 'table' and x or { x }) do
				rm[p] = true
			end
			local kept = {}
			for _, e in ipairs(entries) do
				if not rm[e.path] then kept[#kept + 1] = e end
			end
			entries = kept
			raw_il.size = #entries
			if current and rm[current] then current = false end
		end,
	}
	local function current_image()
		local i = current and find(current) or nil
		-- no explicit selection: the app displays the first image
		if not i and #entries > 0 then i = 1 end
		if not i then
			-- empty list: the app still reports a dummy current image
			return { path = '', index = 0, width = 500, height = 400, meta = {} }
		end
		-- the displayed image: the viewer proxy caches it in the exiv2
		-- bridge by path (like the decoded image in the app), so it must
		-- carry the real decoded data, not a bare dummy. It carries the
		-- file's size but no mtime:
		-- - a matching one would make the bridge serve it the list entry's
		--   snapshot, which stubbed writes mutate apart from the file
		-- - no mtime keeps the display re-reading
		local _, sz = stat(entries[i].path)
		local img = {
			path = entries[i].path,
			index = i,
			size = sz,
			width = 500,
			height = 400,
			meta = {},
			mark = entries[i].mark,
		}
		require('sai.bridge.exiv2').load_all { img }
		return img
	end
	local function recording_mode(name)
		local mode = H.raw_mode {
			on_key = function(b, fn) raw_binds[name .. ':' .. b] = fn end,
			on_mouse = function(b, fn) raw_binds[name .. ':' .. b] = fn end,
			-- one scroll handler per mode: expose it so tests drive the wheel
			on_scroll = function(fn) raw_binds[name .. ':scroll'] = fn end,
			-- the app calls the installed fn for unmapped keys: expose it
			on_unassigned_key = function(fn) raw_binds[name .. ':unassigned'] = fn end,
			open_path = function(p)
				if not find(p) then return false end
				current = p
				return true
			end,
			select_path = function(p)
				if not find(p) then return false end
				current = p
				return true
			end,
			mark_image = function(state)
				local _, e = find(current)
				if e then e.mark = not not state end
			end,
			get_image = current_image,
		}
		-- placements are independent blocks in the app: a field write sets
		-- its own placements, the others stand. The key stays absent, so
		-- every write lands here like on the app's text setter.
		local text_store = {}
		local mt = getmetatable(mode)
		local orig_index = mt.__index
		mt.__index = function(t, k)
			if k == 'text' then return text_store end
			return orig_index(t, k)
		end
		mt.__newindex = function(t, k, v)
			if k == 'text' and type(v) == 'table' then
				for loc, content in pairs(v) do
					text_store[loc] = content
				end
			else
				rawset(t, k, v)
			end
		end
		return mode
	end

	local resize_cb
	-- the app's defer is inert here: sai.defer_fn schedules through
	-- swayimg.defer, so the tests pump the recorded callbacks by hand
	local defers = {}
	local swayimg = {
		mode = 'viewer',
		overlay = true, -- like the app's default: a lone resize is the full init
		viewer = recording_mode 'viewer',
		slideshow = recording_mode 'slideshow',
		gallery = recording_mode 'gallery',
		imagelist = raw_il,
		text = {},
		defer = function(_, fn) defers[#defers + 1] = fn end,
		on_window_resize = function() end,
		get_window_size = function() return { width = 800, height = 600 } end,
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

	---Run every defer the app scheduled so far, including the ones the
	---drain itself schedules; the multiclick waits only fire through it.
	local function flush_defers()
		local guard = 0
		while #defers > 0 do
			guard = guard + 1
			assert(guard < 1000, 'defer pump runaway')
			local batch = defers
			defers = {}
			for _, fn in ipairs(batch) do
				fn()
			end
		end
	end

	return {
		sai = sai,
		sai_proxy = sai_proxy,
		swayimg = swayimg,
		key_help = key_help,
		raw_binds = raw_binds,
		with_env = with_env,
		flush_defers = flush_defers,
		mods = loaded,
	}
end

return H
