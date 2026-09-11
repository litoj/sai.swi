---Tests for sai.lib.ui (the one-shot prompts): the prompt rendering and
---the confirm flow of ui.input/ui.select. The completion menu it can host
---is covered in tests/completion.lua.
---Runs over a recording api stack (see H.recording_stack).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local ui = require 'sai.lib.ui'
local raw_binds = env.raw_binds
local remapper = require 'sai.lib.remapper'

-- the raw text layer of the stub receives the status renders; the modes
-- write their blocks into the current mode's scheme (the stub's viewer,
-- which exists only once written to)
local raw_text = env.swayimg.text
local function scheme() return env.swayimg.viewer.text end

local T = {}

T.ui_input = with_env(function(h)
	local got
	local e = ui.input { prompt = 'Name', on_confirm = function(t) got = t end }
	h.eq('prompt renders with the cursor', 'Name: ▎', raw_text.status)
	e:insert 'bob'
	h.eq('typing shows in the status', 'Name: bob▎', raw_text.status)
	e:confirm()
	h.eq('confirm hands over the lines', 'bob', table.concat(got, '\n'))
	h.ok('confirm disables the editor', not e._enabled)

	-- a plain disable reports nothing: only an explicit confirm or abort
	-- reaches the hook
	got = nil
	local c = ui.input { on_confirm = function(t) got = t end }
	c:insert 'x'
	c.enabled = false
	h.eq('a plain disable fires no report', nil, got)

	local changed
	local p = ui.input { text = 'pre', on_text_changed = function(t) changed = t end, on_confirm = function() end }
	h.eq('preset text renders', 'pre▎', raw_text.status)
	p:insert '!'
	h.eq('on_text_changed sees every change', 'pre!', changed)
	p.enabled = false
end)

T.ui_select = with_env(function(h)
	local got
	local s = ui.select {
		prompt = 'Pick:',
		lines = { 'a', 'b', 'c' },
		on_confirm = function(r) got = r end,
	}
	h.ok('the mode comes enabled', s._enabled)
	h.eq('the title renders', 'Pick:', scheme().topleft[1])
	h.eq('the cursor starts on the first item', '> a', scheme().topleft[2])

	s.line = 2
	s:confirm()
	h.eq('single pick: the cursor item', 'b', got)
	h.ok('confirm disables the mode', not s._enabled)

	s.enabled = true
	s:select(3)
	s:select(1)
	s:confirm()
	h.eq('selected items come back in selection order', 'c\na', table.concat(got, '\n'))

	s.enabled = true
	s:confirm(false)
	h.eq('abort reports false', false, got)
end)

T.ui_select_extras = with_env(function(h)
	local got
	local s = ui.select {
		lines = { 'a', 'b' },
		line_fmt = function(_, item) return item .. '!' end,
		location = 'bottomright',
		on_confirm = function(r) got = r end,
	}
	h.eq('the custom hook paints the cursor row too', 'a!', scheme().bottomright[1])
	h.eq('the plain line format applies', 'b!', scheme().bottomright[2])
	h.eq('the cursor starts on the first item', 'a', s.lines[s.line])
	s:confirm()
	h.eq('the cursor item confirms', 'a', got)

	-- beyond the fixed set, options no longer reach the mode: involved
	-- setups build the selector directly
	local r = ui.select { lines = { 'x' }, rest = { _max_height = 99 }, on_confirm = function() end }
	h.eq('extra options stay out of the mode', 1, r.max_height)
	r.enabled = false
end)

T.ui_input_sync = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.test_sync' }
	local got, after
	mode.map('F13', function()
		coroutine.wrap(function()
			got = ui.input { prompt = 'Name' } -- no on_confirm: parks this action
			after = true
		end)()
	end)
	mode.enabled = true

	raw_binds['viewer:F13']()
	h.ok('the action parks on the prompt', not after)
	h.eq('prompt renders with the cursor', 'Name: ▎', raw_text.status)

	raw_binds['viewer:unassigned'] 'x'
	raw_binds['viewer:unassigned'] 'y'
	h.eq('typing reaches the parked prompt', 'Name: xy▎', raw_text.status)

	raw_binds['viewer:Return']()
	h.eq('the sync call returns the lines', 'xy', table.concat(got, '\n'))
	h.ok('the action continued after the prompt', after)
end)

T.ui_input_sync_abort = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.test_sync' }
	local got, after
	mode.map('F13', function()
		coroutine.wrap(function()
			got = ui.input {}
			after = true
		end)()
	end)
	mode.enabled = true

	raw_binds['viewer:F13']()
	raw_binds['viewer:unassigned'] 'x'
	-- the hide bind: disable without a verdict reports the abort
	raw_binds['viewer:Ctrl+Escape']()
	h.eq('a hidden prompt resumes its caller with false', false, got)
	h.ok('the action continued after the abort', after)
end)

T.ui_select_sync = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.test_sync' }
	local got, after
	mode.map('F13', function()
		coroutine.wrap(function()
			got = ui.select { prompt = 'Pick:', lines = { 'a', 'b', 'c' } }
			after = true
		end)()
	end)
	mode.enabled = true

	raw_binds['viewer:F13']()
	h.ok('the action parks on the menu', not after)
	h.eq('the menu renders with its title', 'Pick:', scheme().topleft[1])
	h.eq('the cursor starts on the first item', '> a', scheme().topleft[2])

	raw_binds['viewer:Down']()
	h.eq('navigation reaches the parked menu', '> b', scheme().topleft[3])

	raw_binds['viewer:Return']()
	h.eq('the sync call returns the pick', 'b', got)
	h.ok('the action continued after the menu', after)
end)

T.ui_sync_needs_a_coroutine = with_env(function(h)
	local ran = pcall(function() ui.input {} end)
	h.ok('ui.input without on_confirm errors outside a bind action', not ran)
	ran = pcall(function() ui.select {} end)
	h.ok('ui.select without on_confirm errors outside a bind action', not ran)
end)

H.maybe_standalone(T)

return T
