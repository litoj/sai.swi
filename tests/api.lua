---Tests for the main api (sai.api.init): the notify and cmdline getters.
---Development tool: not used during normal swayimg operation.
---
---Due-order scheduling lives in tests/deferred_heap.lua, viewer scale
---handling in tests/viewer.lua.
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

-- Notify arms the expiry with the display time, never 0: only its firing repaints.
-- The defer stub queues fires like the app timers, exercising the stuck-message chain.

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

-- The instance serves its state over ipc over a stubbed swayimg with no modes loaded.
-- The stub stays local: the api alone must declare its ffi needs before PRE_IPC.
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
-- Usability tests: the status flows a user and a mode trigger
-- ---------------------------------------------------------------------------

T.notify_never_arms_the_app_expiry = with_env(function(h)
	sai.text.status_timeout = 2
	sai.text.status = 'my status'

	sai.notify 'test message'
	h.eq('notify message shown in the status', 'test message', raw_text.status)
	h.eq('raw status timeout pinned to 0 for display', 0, raw_text.status_timeout)
	h.eq('public status timeout untouched', 2, sai.text.status_timeout)

	run_deferred() -- the defer owns the clear, no expiry to wait for
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('raw status timeout back to the public value', 2, raw_text.status_timeout)
end)

-- A display time of our own (the given one, or the length formula over a
-- permanent 0) must go back to the configured timeout once the message
-- expired - unless someone wrote their own value in the meantime
T.notify_restores_the_configured_timeout = with_env(function(h)
	sai.text.status_timeout = 5
	sai.notify('test message', 2)
	h.eq('raw status timeout pinned to 0 for display', 0, raw_text.status_timeout)
	h.eq('public status timeout untouched', 5, sai.text.status_timeout)

	run_deferred()
	h.eq('the configured timeout restored', 5, raw_text.status_timeout)
end)

T.late_timeout_write_survives_the_restore = with_env(function(h)
	sai.text.status_timeout = 5
	sai.notify('test message', 2)

	sai.text.status_timeout = 7 -- a late direct write does not cancel it
	run_deferred()
	h.eq('the late timeout write survives', 7, raw_text.status_timeout)
end)

T.superseded_notify_keeps_newest = with_env(function(h)
	sai.text.status_timeout = 5
	sai.notify('first message', 2)
	sai.notify('second message', 3)
	h.eq('newest notify message shown in the status', 'second message', raw_text.status)
	h.eq('raw status timeout stays pinned across notifies', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the configured timeout restored once', 5, raw_text.status_timeout)
end)

-- A permanent statusline (timeout 0) has no expiry of its own: the display
-- time comes from the message length, and both the stored text and the 0 go
-- back once the message is gone
T.notify_computes_over_permanent = with_env(function(h)
	sai.text.status_timeout = 0
	sai.notify 'test message' -- 13 chars: one second at the -10 rate
	h.eq('notify message shown in the status', 'test message', raw_text.status)
	h.eq('raw status timeout stays 0 over the permanent', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('stored status text restored', '', raw_text.status)
	h.eq('the permanent timeout restored', 0, raw_text.status_timeout)
end)

-- a multiline message is aligned to its longest line so the centered status
-- renders it as a block: the padding must keep the lines, not replace them
-- with the width number (a format mix-up once rendered the width twice)
T.notify_pads_multiline_into_a_block = with_env(function(h)
	sai.notify 'ab\ncdef'
	h.eq('multiline notify lines padded to the longest', 'ab  \ncdef', raw_text.status)
	sai.notify 'single'
	h.eq('single-line notify left unpadded', 'single', raw_text.status)
end)

-- A corner block takes a message too, leaving the status free (e.g. for the
-- input field); every location owns its expiry: one block's hider must not
-- cancel another's pending clear
T.notify_per_location = with_env(function(h)
	sai.text.status_timeout = 5
	sai.notify('status message', 5)
	sai.notify('corner message', 5, 'bottomright')

	h.eq('the corner block shows its message', 'corner message', (swayimg.viewer.text.bottomright or {})[1])
	h.eq('the status keeps its message', 'status message', raw_text.status)
	h.eq('the status timeout still pinned', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the corner back to its empty default', nil, (swayimg.viewer.text.bottomright or {})[1])
	h.eq('the status cleared on its own', ' ', raw_text.status)
	h.eq('the configured timeout restored', 5, raw_text.status_timeout)
end)

-- a newer message on the same corner replaces the older one and its expiry
T.notify_supersedes_per_location = with_env(function(h)
	sai.notify('first corner', 5, 'topleft')
	sai.notify('second corner', 5, 'topleft')
	h.eq('only the newest corner message shows', 'second corner', (swayimg.viewer.text.topleft or {})[1])

	run_deferred()
	-- the release restores the corner's prior content: the viewer's
	-- default block, not a blank
	h.eq('the corner restored to its prior content', 'File:\t{name}', (swayimg.viewer.text.topleft or {})[1])
end)

-- the corner machinery reads tables of lines: the message must arrive
-- aligned and split, a raw string would break it
T.notify_splits_the_corner_message = with_env(function(h)
	sai.notify('ab\ncdef', 5, 'topleft')
	local lines = swayimg.viewer.text.topleft or {}
	h.eq('corner notify line one padded', 'ab  ', lines[1])
	h.eq('corner notify line two split off', 'cdef', lines[2])

	run_deferred()
	h.eq('the corner restored to its prior content', 'File:\t{name}', (swayimg.viewer.text.topleft or {})[1])
end)

T.notify_unknown_location_errors = with_env(function(h)
	local ok, err = pcall(function() sai.notify('msg', nil, 'nowhere') end)
	h.ok('unknown block errors on its own', not ok)
	h.contains('the error names the block', tostring(err), 'sai.text.nowhere')
	-- the throw skips notify's own restore of the muted flag
	e.ignore_opts = false
end)

-- ---------------------------------------------------------------------------
-- The base app scenario: the option printer snippet, the key_help display
-- and the editor input mode over the shared text stack - what a real session runs
-- ---------------------------------------------------------------------------

-- the other test files bind the mode modules to their own stacks: reload
-- them against this one
local function fresh(name)
	package.loaded[name] = nil
	return require(name)
end

-- the app after startup: init resolved, the option printer subscribed, the
-- help display and the editor input mode loaded - the base every user path below
-- runs against
local function base_scenario()
	sai.initialized = true
	local snip = fresh 'sai.snippets'
	snip.print_option_changes(false) -- a printer from an earlier scenario must not stack
	snip.print_option_changes()
	local key_help = fresh 'sai.mode.key_help'
	local prompt = fresh('sai.mode.editor').new { _prompt = 'Code' }
	return key_help, prompt
end

-- The Escape path: F1 opens help, the prompt opens over the status, F1
-- closes help, Escape aborts the prompt input (confirm(false) clears the
-- text, then disables the mode from inside the confirm) - the message must
-- come out the same
T.app_sequence_escape_abort_clears = with_env(function(h)
	local key_help, prompt = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	key_help.enabled = true
	prompt.enabled = true
	key_help.enabled = false
	prompt:confirm(false)

	h.eq('option printer message shows in the status', 'Editor Enabled: false', tostring(sai.text.status))
	h.eq('raw status timeout pinned to 0 for display', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the configured timeout stands', 3, raw_text.status_timeout)
end)

-- A message over a mode's live prompt: the message pins itself permanent
-- for its display, but the prompt input still waits for its text - the prompt
-- must come back once the message is gone
T.app_sequence_help_over_prompt_returns_the_prompt = with_env(function(h)
	local key_help, prompt = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	prompt.enabled = true -- the prompt takes the status over, permanent
	h.eq('the editor prompt shows in the status', 'Code: ▎', raw_text.status)
	h.eq('the prompt pins its status permanent', 0, raw_text.status_timeout)

	key_help.enabled = true
	key_help.enabled = false -- the printer notifies over the prompt
	h.eq('option printer message shows in the status', 'Key Help Enabled: false', tostring(sai.text.status))

	run_deferred() -- the message is gone, the defer restored the prompt
	h.eq('the prompt is back after the message', 'Code: ▎', raw_text.status)
	h.eq('the prompt is permanent again', 0, raw_text.status_timeout)

	prompt.enabled = false -- the scenario leaves no mode layer behind
end)

-- The notify fires the prompt disable itself (the printer reacts
-- to sai.mode.editor.enabled = false): the armed expiry must survive the
-- whole disable cascade running underneath it
T.notify_fired_from_inside_prompt_disable = with_env(function(h)
	local _, prompt = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	prompt.enabled = true
	prompt.text = 'echo hi'
	prompt.enabled = false -- the OptionSet fires after the setter: notify mid-cascade

	h.eq('option printer message shows in the status', 'Editor Enabled: false', tostring(sai.text.status))
	h.eq('raw status timeout pinned to 0 for display', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the configured timeout stands', 3, raw_text.status_timeout)
end)

-- The user sequence used to leave armed fires behind after the heap
-- emptied: a surplus fire must skip the empty heap instead of erroring
-- inside the app callback - the stuck-message wedge
T.spurious_fire_does_not_kill_the_chain = with_env(function(h)
	local key_help, prompt = base_scenario()

	sai.text.status = 'my status'
	sai.text.status_timeout = 3

	key_help.enabled = true
	prompt.enabled = true
	prompt.text = 'echo hi'
	key_help.enabled = false
	prompt.enabled = false

	run_deferred()
	h.eq('the timed text cleared', ' ', raw_text.status)
	h.eq('the configured timeout stands', 3, raw_text.status_timeout)

	-- only stale fires are replayed: the latest arm always finds its heap
	-- entry (arms happen on push), so the app can only deliver it work to do
	for i = 1, #all_defers - 1 do
		all_defers[i]() -- every older fire, fired again as a surplus
	end
	h.eq('no state change after the surplus fires', ' ', raw_text.status)
	h.eq('the timeout untouched by the surplus fires', 3, raw_text.status_timeout)
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
	h.eq('the timeout restore behind the error ran', 5, raw_text.status_timeout)
	h.ok('the callback error was reported', printed[1] ~= nil and printed[1]:find('boom', 1, true) ~= nil)
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
	h.eq('a direct timeout write prints', 1, #printed)

	sai.notify 'test message' -- the timeout write: no print
	h.eq('the notify printed nothing', 1, #printed)

	sai.notify('own time', 5) -- a display time of our own: no print either
	h.eq('notify own display time printed nothing', 1, #printed)

	run_deferred() -- the timeout restore: no print
	h.eq('the timeout restore printed nothing', 1, #printed)

	e.unsubscribe { event = 'OptionSet', group = 'test_pin_printer' }
end)

H.maybe_standalone(T)

return T
