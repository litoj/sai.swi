---Tests for the snippet input modes (sai.snippets.lua_mode/shell_mode):
---the confirm-to-history flow. Only successful runs record (on_confirm
---returns true); failures stay open with the input kept.
---Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local eq = H.eq

local env = H.recording_stack { 'sai.mode.editor' }
local with_env = env.with_env
local raw_binds = env.raw_binds
local snippets = require 'sai.snippets'

local function new_lua(history)
	local lua = snippets.lua_mode()
	lua.enabled = true
	if history then lua.history = require('sai.lib.history').new(history) end
	return lua
end

local function new_shell(history)
	local sh = snippets.shell_mode()
	sh.enabled = true
	if history then sh.history = require('sai.lib.history').new(history) end
	return sh
end

local T = {}

-- pure: no app state needed, an unknown current stays put
T.cycle_values_cycles_and_wraps = function(h)
	local values = { 'a', 'b', 'c' }
	h.eq('next item', 'b', snippets.cycle_values(values, 'a'))
	h.eq('last wraps to first', 'a', snippets.cycle_values(values, 'c'))
	h.eq('unknown stays still', nil, snippets.cycle_values(values, 'zzz'))
end

-- ---------------------------------------------------------------------------
-- Default binds drive the menu through the app mode mappings
-- ---------------------------------------------------------------------------

T.default_binds_drive_the_menu = with_env(function(h)
	local lua = snippets.lua_mode()
	lua.enabled = true

	-- dispatch through the installed app mode mappings, the way the app
	-- delivers keys (not the recorded closures)
	local api = lua._mode_api
	h.ok('the layer binds onto an app mode', api ~= nil)
	local function dispatch(bind)
		local cfg = api._mappings[bind]
		if cfg == nil or cfg.cb == nil then
			h.fail('bind installed on the app mode: ' .. bind)
			return
		end
		h.pass('bind installed on the app mode: ' .. bind)
		cfg.cb()
	end

	lua.text = 'local a = 1'
	dispatch 'Return'
	h.eq('Return confirms and records', 1, #lua.history)
	h.ok('Return closes the mode', not lua.enabled)

	-- second cycle: re-enable re-applies the binds, Escape aborts clean
	lua.enabled = true
	lua.text = 'local'
	dispatch 'Up'
	h.eq('Up recalls the confirmed command', 'local a = 1', lua.text)
	dispatch 'Escape'
	h.eq('Escape clears the input', '', lua.text)
	h.ok('Escape closes the mode', not lua.enabled)
end)

-- ---------------------------------------------------------------------------
-- Lua: the confirm flow (what enters the history)
-- ---------------------------------------------------------------------------

T.lua_confirm_builds_history = with_env(function(h)
	local lua = new_lua {}

	lua.text = 'local a = 1'
	lua:confirm()
	eq('confirmed command recorded', 1, #lua.history)
	eq('recorded entry is the command', 'local a = 1', lua.history[1])
	eq('confirm clears the input', '', lua.text)
	h.ok('confirm disables the mode', not lua.enabled)

	lua.enabled = true
	lua.text = 'local b = 2'
	lua:confirm()
	eq('newest entry first', 'local b = 2', lua.history[1])
	eq('older entry behind it', 'local a = 1', lua.history[2])

	lua.enabled = true
	H.press(raw_binds, 'Up')
	eq('Up recalls the newest confirmed command', 'local b = 2', lua.text)
	lua.enabled = false
end)

T.lua_reconfirm_moves_to_top = with_env(function(_)
	local lua = new_lua { 'local b = 2', 'local a = 1' }

	lua.text = 'local a = 1'
	lua:confirm()
	eq('re-confirmed command not duplicated', 2, #lua.history)

	lua.enabled = true
	H.press(raw_binds, 'Up')
	eq('Up recalls the re-confirmed command, now newest', 'local a = 1', lua.text)
	lua.enabled = false
end)

T.lua_abort_is_not_recorded = with_env(function(_)
	local lua = new_lua {}

	lua.text = 'local a = 1'
	lua:confirm(false)
	eq('aborted input not recorded', 0, #lua.history)
	eq('abort clears the input', '', lua.text)
end)

T.lua_empty_confirm_is_not_recorded = with_env(function(_)
	local lua = new_lua {}

	lua:confirm()
	eq('empty input not recorded', 0, #lua.history)
end)

T.lua_history_opt_out = with_env(function(h)
	local lua = new_lua {}
	lua.update_history = false

	lua.text = 'local a = 1'
	lua:confirm()
	h.ok('success still closes the mode', not lua.enabled)
	eq('nothing recorded when disabled', 0, #lua.history)
	eq('the input still clears', '', lua.text)
end)

T.lua_syntax_error_returns_to_editing = with_env(function(h)
	local lua = new_lua {}
	lua.text = 'local x ='

	local recs = H.capture_notify(env.sai, function() lua:confirm() end)
	h.ok('the mode stays enabled for editing', lua.enabled)
	h.eq('the failed code stays in the input', 'local x =', lua.text)
	eq('nothing recorded', 0, #lua.history)
	h.contains('the syntax error verdict notifies through the editor', recs[1].trace, 'mode/editor.lua')

	lua.text = 'local x = 1'
	lua:confirm()
	h.ok('the fixed code runs and closes the mode', not lua.enabled)
	eq('the fixed code recorded', 1, #lua.history)
end)

T.lua_runtime_error_is_not_recorded = with_env(function(h)
	local lua = new_lua {}
	lua.text = 'error("boom")'

	local recs = H.capture_notify(env.sai, function() lua:confirm() end)
	h.ok('the mode is back for editing', lua.enabled)
	h.eq('the failed code is back in the input', 'error("boom")', lua.text)
	eq('the failed code not recorded', 0, #lua.history)
	h.contains('the runtime error verdict notifies through the editor', recs[1].trace, 'mode/editor.lua')
	lua.enabled = false
end)

-- ---------------------------------------------------------------------------
-- Shell: verify-then-run through sai.exec
-- ---------------------------------------------------------------------------

T.shell_run_records_and_closes = with_env(function(h)
	local sh = new_shell {}

	sh.text = 'echo hi'
	local recs = H.capture_notify(env.sai, function() sh:confirm() end)
	eq('successful command recorded', 1, #sh.history)
	eq('recorded entry is the command', 'echo hi', sh.history[1])
	eq('confirm clears the input', '', sh.text)
	h.ok('confirm disables the mode', not sh.enabled)
	h.contains('the output notifies through the editor', recs[1].trace, 'mode/editor.lua')
end)

T.shell_unknown_command_stays_open = with_env(function(h)
	local sh = new_shell {}

	sh.text = 'sai_no_such_command_xyz'
	local recs = H.capture_notify(env.sai, function() sh:confirm() end)
	h.ok('unrunnable stays open for editing', sh.enabled)
	h.eq('unrunnable keeps the text', 'sai_no_such_command_xyz', sh.text)
	eq('nothing recorded', 0, #sh.history)
	h.contains('the exit code notifies through the editor', recs[1].trace, 'mode/editor.lua')
	sh.enabled = false
end)

T.shell_failing_command_stays_open = with_env(function(h)
	local sh = new_shell {}

	sh.text = 'false'
	local recs = H.capture_notify(env.sai, function() sh:confirm() end)
	h.ok('failed run stays open for editing', sh.enabled)
	h.eq('failed run keeps the text', 'false', sh.text)
	eq('nothing recorded', 0, #sh.history)
	h.contains('the exit code notifies through the editor', recs[1].trace, 'mode/editor.lua')
	sh.enabled = false
end)

T.shell_abort_is_not_recorded = with_env(function(_)
	local sh = new_shell {}

	sh.text = 'echo hi'
	sh:confirm(false)
	eq('aborted input not recorded', 0, #sh.history)
	eq('abort clears the input', '', sh.text)
end)

T.shell_empty_confirm_is_not_recorded = with_env(function(_)
	local sh = new_shell {}

	sh:confirm()
	eq('empty input not recorded', 0, #sh.history)
end)

-- the editor emits the message only after the mode state settles: a
-- closing run notifies while the mode is down, a failed run re-enables
-- first, so the message lands after the re-enable render and stays visible
T.message_outlives_the_mode = with_env(function(h)
	local current
	local enabled_at_notify
	local old = env.sai.notify
	env.sai.notify = function(msg)
		enabled_at_notify = current.enabled
		return old(msg)
	end
	local ran, err = pcall(function()
		current = new_shell {}
		current.text = 'echo hi'
		current:confirm()
		h.eq('closing run notifies while down', false, enabled_at_notify)
		h.ok('success stays down', not current.enabled)

		current = new_lua {}
		current.text = 'error("boom")'
		current:confirm()
		h.eq('stay-open run notifies after the re-enable', true, enabled_at_notify)
		h.ok('failure comes back up', current.enabled)
		current.enabled = false
	end)
	env.sai.notify = old
	if not ran then error(err, 0) end
end)

T.histories_stay_separate = with_env(function(_)
	local lua = new_lua {}
	local sh = new_shell {}

	lua.text = 'local a = 1'
	lua:confirm()
	sh.text = 'echo hi'
	sh:confirm()

	eq('lua history holds only lua', 'local a = 1', table.concat(lua.history, '\n'))
	eq('shell history holds only shell', 'echo hi', table.concat(sh.history, '\n'))
	lua.enabled = false
end)

H.maybe_standalone(T)

return T
