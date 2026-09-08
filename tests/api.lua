---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for the main api (sai.api.init): the notify and cmdline getters.
---Development tool: not used during normal swayimg operation.
---
---Loads a private copy of the api stack: the raw text table the proxies
---write through to is captured at module load time, so this file cannot
---reuse the stack the help tests bound to their own stub.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local ipc = require 'sai.bridge.ipc'

local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')

-- The notify tests: the message display is the app's own expiry - the
-- status write arms it with the current status_timeout, and its firing is
-- the only thing that repaints the layer (an empty write from Lua does not
-- repaint, the message frame would stay painted until the next redraw). So
-- notify must arm the expiry with the display time and never pin it to 0.
-- The swayimg.defer stub queues every armed fire the way the app's own
-- timers run them: pumping the queue exercises the chain scheduling under
-- the heap, the exact machinery the stuck-message bug lived in.

-- faithful to the live app: the C++ text property getters return nil
-- (reads fall through to the api copies), writes land on the C++ side;
-- raw_text records what the app would have received
local raw_text = {}
-- every armed deferred fire queues up; all_defers remembers each one ever
-- armed so a test can replay them as surplus fires
local defer_queue, all_defers = {}, {}
local swayimg = H.raw_swayimg()
swayimg.text = setmetatable({}, {
	__index = function() return nil end,
	__newindex = function(_, k, v) raw_text[k] = v end,
})
swayimg.defer = function(_, cb) -- deferred callbacks are pumped manually
	defer_queue[#defer_queue + 1] = cb
	all_defers[#all_defers + 1] = cb
end

local sai, sai_proxy = H.fresh_api_stack(swayimg)
local heap = require 'sai.bridge.deferred_heap'
local e = require 'sai.api.eventloop'
local registry_vars = require('sai.lib.registry').vars

_G.swayimg, _G.sai = old_swi, old_sai

---Fire the armed deferred fires until the queue and the heap settle: each
---fire pops the earliest entry, exactly like the app's timers would.
local function run_deferred()
	for _ = 1, 100 do
		local fire = table.remove(defer_queue, 1)
		if not fire then break end
		fire()
	end
end

local function with_env(fn)
	return function(h)
		_G.swayimg, _G.sai = swayimg, sai_proxy
		-- flush a half-fired chain from the previous test: a leftover fire
		-- or heap entry would silence or double this test's timers
		run_deferred()
		-- the previous scenario's modes leave their records applied: this
		-- test must not resurrect their prompts off the shared stacks
		for _, stacks in pairs(registry_vars) do
			for _, stack in pairs(stacks) do
				for i = #stack, 1, -1 do
					stack[i] = nil
				end
			end
		end
		for i = #all_defers, 1, -1 do
			all_defers[i] = nil
		end
		-- the api copies must not read the previous test's display time as
		-- this test's config: no display time can ever be 0
		local muted = e.ignore_opts
		e.ignore_opts = true
		sai.text.status_timeout = 0
		sai.text.status = ''
		e.ignore_opts = muted
		raw_text.status_timeout = nil
		raw_text.status = nil
		local ran, err = pcall(fn, h)
		-- a scenario's printer must not echo the next test's direct
		-- writes into its own notifies
		e.unsubscribe { event = 'OptionSet', group = 'print_var_change' }
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

local T = {}

-- ---------------------------------------------------------------------------
-- The cmdline getter, end-to-end: a launched instance with known args
-- serves its own pid and cmdline back over the ipc, checked against the
-- real launch
-- ---------------------------------------------------------------------------

local fx = H.proc_fixture('api_instance', 'INSTANCE_READY')

-- the launched instance: the api stack over a stubbed swayimg (the resize
-- callback never fires, so no mode ever loads), serving its own state over
-- the ipc - the closest to a real swayimg instance a test can launch.
-- The stub cannot come from the harness: requiring it would preload the
-- socket and debug bridges before the getters ran, and the whole point of
-- the PRE_IPC check below is that the api alone declares its ffi needs
local function instance_script()
	return table.concat({
		"local ffi = require('ffi')",
		("package.path = %q .. '/?.lua;' .. %q .. '/?.lua;' .. package.path"):format(H.dir, H.swayimg_dir),
		'local function raw_mode(t)',
		'	t = t or {}',
		'	t.get_image = t.get_image or function()',
		"		return { width = 500, height = 400, index = 1, path = 'stub', meta = {} }",
		'	end',
		'	return setmetatable(t, { __index = function() return function() end end })',
		'end',
		'_G.swayimg = {',
		"	mode = 'viewer',",
		'	viewer = raw_mode(),',
		'	slideshow = raw_mode {},',
		'	gallery = raw_mode { thumb_size = 128, padding_size = 10 },',
		'	imagelist = { size = 0 },',
		'	text = setmetatable({}, {',
		'		__index = function() return nil end,',
		'		__newindex = function() end,',
		'	}),',
		'	defer = function() end,',
		'	on_window_resize = function() end,',
		'	get_window_size = function() return { width = 800, height = 600 } end,',
		'}',
		"require 'sai.api.init' -- also sets the sai global",
		-- production order: with no bridge module beyond the api's own cdef
		-- requirement loaded, the getters must already work
		"print('PRE_IPC_OK ' .. #_G.sai:get_cmdline())",
		"local H = require 'harness' -- the poll loop's usleep",
		("local serv = require('sai.bridge.ipc').server(%q)"):format(fx.sock),
		'serv._signal = false -- no O_ASYNC: the loop below polls',
		'serv.enabled = false',
		'serv.enabled = true',
		"print('INSTANCE_READY')",
		'io.stdout:flush()',
		'while true do',
		'	serv:poll(0)',
		'	ffi.C.usleep(1000)',
		'end',
	}, '\n') .. '\n'
end

-- the instance is launched with known args; the pid and cmdline it serves
-- must be the real ones of the launched process, through both the getter
-- and the plain field read
T.cmdline_of_launched_instance = fx.scenario(function(h)
	h.write_file(fx.script, instance_script())
	h.ok('instance started', fx.spawn(("luajit %s --viewer 'my pic.png'"):format(fx.script)))
	-- the getters ran before the ipc (and the socket bridge) even loaded:
	-- the api alone must declare everything its ffi use needs
	h.contains('getters work before any bridge ipc loads', h.read_file(fx.log) or '', 'PRE_IPC_OK 4')

	-- the args the instance was really launched with, \1-joined for transport.
	-- _G.sai, not the local one: the closure's bytecode travels to the
	-- instance, and upvalues (like this file's sai stack) do not. A wrong pid
	-- would fail here too: it would read some other process's args
	local c = ipc.client(fx.sock)
	h.eq(
		'cmdline of the launched process',
		table.concat({ 'luajit', fx.script, '--viewer', 'my pic.png' }, '\1'),
		c:send(function() return table.concat(_G.sai:get_cmdline(), '\1') end)
	)
	c.enabled = false
end)

-- ---------------------------------------------------------------------------
-- Generic unit tests: the deferred heap notify schedules its restore on
-- ---------------------------------------------------------------------------

T.monotonic_ms_precision = function(h)
	-- whole-second clock truncation would record this due time up to 1s early
	heap:push(500, function() end)
	local remaining = heap:time_to_next()
	h.ok('sub-second precision', remaining > 250 and remaining <= 500)
	heap:pop()
end

-- ---------------------------------------------------------------------------
-- Usability tests: the status flows a user and a mode trigger
-- ---------------------------------------------------------------------------

T.notify_never_arms_the_app_expiry = with_env(function(h)
	sai.text.status_timeout = 2
	sai.text.status = 'my status'

	sai.notify 'test message'
	h.eq('message shown', 'test message', raw_text.status)
	h.eq('the raw timeout pinned for the display', 0, raw_text.status_timeout)
	h.eq('the publicly known timeout untouched', 2, sai.text.status_timeout)

	run_deferred() -- the defer owns the clear, no expiry to wait for
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the raw back to the public value', 2, raw_text.status_timeout)
end)

-- A display time of our own (the given one, or the length formula over a
-- permanent 0) must go back to the configured timeout once the message
-- expired - unless someone wrote their own value in the meantime
T.notify_restores_the_configured_timeout = with_env(function(h)
	sai.text.status_timeout = 5
	sai.notify('test message', 2)
	h.eq('the raw pinned for the display', 0, raw_text.status_timeout)
	h.eq('the public timeout untouched', 5, sai.text.status_timeout)

	run_deferred()
	h.eq('the configured timeout restored', 5, raw_text.status_timeout)
end)

T.late_timeout_write_survives_the_restore = with_env(function(h)
	sai.text.status_timeout = 5
	sai.notify('test message', 2)

	sai.text.status_timeout = 7 -- a late direct write does not cancel it
	run_deferred()
	h.eq('the late write survives', 7, raw_text.status_timeout)
end)

T.superseded_notify_keeps_newest = with_env(function(h)
	sai.text.status_timeout = 5
	sai.notify('first message', 2)
	sai.notify('second message', 3)
	h.eq('newest message shown', 'second message', raw_text.status)
	h.eq('the raw stays pinned across them', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the configured timeout restored once', 5, raw_text.status_timeout)
end)

-- A permanent statusline (timeout 0) has no expiry of its own: the display
-- time comes from the message length, and both the stored text and the 0 go
-- back once the message is gone
T.notify_computes_over_permanent = with_env(function(h)
	sai.text.status_timeout = 0
	sai.notify 'test message' -- 13 chars: one second at the -10 rate
	h.eq('message shown', 'test message', raw_text.status)
	h.eq('the raw stays 0 over the permanent', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the stored text restored', '', raw_text.status)
	h.eq('the permanent timeout restored', 0, raw_text.status_timeout)
end)

-- ---------------------------------------------------------------------------
-- The base app scenario: the option printer snippet, the key_help display
-- and the cmd mode over the shared text stack - what a real session runs
-- ---------------------------------------------------------------------------

-- the other test files bind the mode modules to their own stacks: reload
-- them against this one
local function fresh(name)
	package.loaded[name] = nil
	return require(name)
end

-- the app after startup: init resolved, the option printer subscribed, the
-- help display and the cmd mode loaded - the base every user path below
-- runs against
local function base_scenario()
	sai.initialized = true
	local snip = fresh 'sai.snippets'
	snip.print_option_changes(false) -- a printer from an earlier scenario must not stack
	snip.print_option_changes()
	local key_help = fresh 'sai.mode.key_help'
	local cmd = fresh('sai.mode.cmd').new {}
	return key_help, cmd
end

-- The Escape path: F1 opens help, ':' opens cmd, F1 closes help, Escape
-- aborts the cmd input (confirm(false) clears the text, then disables the
-- mode from inside the confirm) - the message must come out the same
T.app_sequence_escape_abort_clears = with_env(function(h)
	local key_help, cmd = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	key_help.enabled = true
	cmd.enabled = true
	key_help.enabled = false
	cmd:confirm(false)

	h.eq('the printer message shows', 'Cmd Enabled: false', tostring(sai.text.status))
	h.eq('the raw pinned for the display', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the configured timeout stands', 3, raw_text.status_timeout)
end)

-- A message over a mode's live prompt: the message pins itself permanent
-- for its display, but the cmd input still waits for its text - the prompt
-- must come back once the message is gone
T.app_sequence_help_over_cmd_returns_the_prompt = with_env(function(h)
	local key_help, cmd = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	cmd.enabled = true -- the prompt takes the status over, permanent
	h.eq('the prompt shows', 'Code: ▎', raw_text.status)
	h.eq('the prompt pins its status permanent', 0, raw_text.status_timeout)

	key_help.enabled = true
	key_help.enabled = false -- the printer notifies over the prompt
	h.eq('the printer message shows', 'Key Help Enabled: false', tostring(sai.text.status))

	run_deferred() -- the message is gone, the defer restored the prompt
	h.eq('the prompt is back after the message', 'Code: ▎', raw_text.status)
	h.eq('the prompt is permanent again', 0, raw_text.status_timeout)

	cmd.enabled = false -- the scenario leaves no mode layer behind
end)

-- The notify fires from inside the cmd disable itself (the printer reacts
-- to sai.mode.cmd.enabled = false): the armed expiry must survive the
-- whole disable cascade running underneath it
T.notify_fired_from_inside_cmd_disable = with_env(function(h)
	local _, cmd = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	cmd.enabled = true
	cmd.text = 'echo hi'
	cmd.enabled = false -- the OptionSet fires after the setter: notify mid-cascade

	h.eq('the printer message shows', 'Cmd Enabled: false', tostring(sai.text.status))
	h.eq('the raw pinned for the display', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the configured timeout stands', 3, raw_text.status_timeout)
end)

-- Every push beyond the first must re-aim the single chain instead of
-- arming another fire: the surplus fires pop past the heap's end and the
-- error inside the app's callback kills every timer the app runs on
T.pushes_keep_single_chain = with_env(function(h)
	sai.defer_fn(function() end, 1)
	h.eq('the first push arms the chain', 1, #defer_queue)

	sai.defer_fn(function() end, 1)
	sai.defer_fn(function() end, 1)
	h.eq('the later pushes re-arm it, not multiply', 1, #defer_queue)

	run_deferred()
	h.eq('the queue drained', 0, #defer_queue)
end)

-- The user sequence used to leave armed fires behind after the heap
-- emptied: a surplus fire must skip the empty heap instead of erroring
-- inside the app callback - the stuck-message wedge
T.spurious_fire_does_not_kill_the_chain = with_env(function(h)
	local key_help, cmd = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	key_help.enabled = true
	cmd.enabled = true
	cmd.text = 'echo hi'
	key_help.enabled = false
	cmd.enabled = false

	run_deferred()
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the configured timeout stands', 3, raw_text.status_timeout)

	for i = 1, #all_defers do
		all_defers[i]() -- every fire ever armed, fired again as a surplus
	end
	h.eq('no state change after the surplus fires', ' ', raw_text.status)
	h.eq('the timeout untouched by them', 3, raw_text.status_timeout)
end)

-- A callback erroring inside the app's fire would take the whole timer
-- chain down with it: the chain must isolate it and carry the rest on
T.callback_error_does_not_kill_the_chain = with_env(function(h)
	local printed = {}
	local old_print = _G.print
	_G.print = function(msg) printed[#printed + 1] = tostring(msg) end
	local ran, err = pcall(function()
		sai.defer_fn(function() error 'boom' end)
		sai.text.status_timeout = 5
		sai.notify('test message', 2) -- the restore is behind the bad cb
		run_deferred()
	end)
	_G.print = old_print
	if not ran then error(err, 0) end

	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the restore behind the error ran', 5, raw_text.status_timeout)
	h.ok('the error was reported', printed[1] ~= nil and printed[1]:find('boom', 1, true) ~= nil)
end)

-- A defer_fn called from inside a running fire re-arms the chain for its
-- own entry: the queue must not grow a second fire
T.reentrant_push_rearms_single_chain = with_env(function(h)
	local ran_inner = false
	sai.defer_fn(function()
		sai.defer_fn(function() ran_inner = true end, 1)
		h.eq('the reentrant push re-armed, not multiplied', 1, #defer_queue)
	end, 1)

	run_deferred()
	h.ok('the reentrant push ran', ran_inner)
	h.eq('the queue drained', 0, #defer_queue)
end)

-- The notify writes run under e.ignore_opts: option printers must stay
-- quiet, or every message and its timeout restore would echo through them
T.notify_writes_do_not_print = with_env(function(h)
	local printed = {}
	e.subscribe {
		event = 'OptionSet',
		pattern = 'sai.text.status_timeout',
		group = 'test_pin_printer',
		callback = function(ev)
			if not e.ignore_opts then printed[#printed + 1] = ev.data end
		end,
	}

	sai.text.status_timeout = 2
	sai.text.status = 'my status'
	h.eq('a direct write prints', 1, #printed)

	sai.notify 'test message' -- the timeout write: no print
	h.eq('the notify printed nothing', 1, #printed)

	sai.notify('own time', 5) -- a display time of our own: no print either
	h.eq('the own time printed nothing', 1, #printed)

	run_deferred() -- the timeout restore: no print
	h.eq('the restore printed nothing', 1, #printed)

	e.unsubscribe { event = 'OptionSet', group = 'test_pin_printer' }
end)

H.maybe_standalone(T)

return T
