---Tests for sai.mode.help: the base pager and its scrolls.
---Over a recording api stack.
---Development tool: not used during normal swayimg operation.
---
---The sub-mode tab/group tests live on their subjects now
---(tests/key_help.lua, tests/var_help.lua, tests/image_filter.lua).

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local sai, key_help = env.sai, env.key_help
local with_env = env.with_env
local remapper = require 'sai.lib.remapper'

local function tabs_of(m)
	m:gen_tabs()
	return m._tabs
end

local T = {}

-- enable cycles must not accumulate hooks: the shared tree (mode plus its
-- pager) applies its presets on enable and drops them on disable, every time
T.enable_cycles_drop_all_hooks = with_env(function(h)
	local e = require 'sai.api.eventloop'
	local function mode_hooks()
		local n = 0
		for _ in pairs(e.find_all { event = 'ModeChanged' }) do
			n = n + 1
		end
		for _ in pairs(e.find_all { event = 'ModeChangedPre' }) do
			n = n + 1
		end
		return n
	end
	key_help.enabled = false
	local base = mode_hooks()
	for _ = 1, 3 do
		key_help.enabled = true
		key_help.enabled = false
	end
	h.eq('no hooks left behind', base, mode_hooks())
end)

-- set_tab wraps around the tab set; an emptied set renders nothing
T.tab_switch_wraps_and_empty_renders_silent = with_env(function(h)
	sai.mode = 'viewer'
	key_help.enabled = true
	local n = #tabs_of(key_help)
	h.ok('at least one tab exists', n >= 1)

	key_help.tab = n + 5
	h.eq('wrap lands inside the set', (n + 5 - 1) % n + 1, key_help.tab)

	local title = key_help.pager.title
	local saved, saved_tab = key_help._tabs, key_help.tab
	key_help._tabs = {}
	key_help:render()
	h.eq('empty set keeps the title', title, key_help.pager.title)
	key_help._tabs = saved
	key_help.tab = 1
	key_help.enabled = false
	h.eq('tab back to one', 1, saved_tab and key_help.tab)
end)

-- the corner display scrolls with the mouse wheel over its block, taken
-- by the topmost enabled display; the keyboard keys stay with the
-- running mode - a display never eats them
T.help_pager_owns_scrolls = with_env(function(h)
	key_help.enabled = true
	local lines = table.concat(key_help.pager.lines, '\n')
	h.ok('the wheel scroll stays out of the display listing', not lines:find('Scroll up', 1, true))
	h.eq('the help window owns the wheel privately', 'private', sai.viewer._mappings['TR+ScrollUp'].kind)
	h.eq('the help window owns keyboard scrolling', 'private', sai.viewer._mappings['Up'].kind)
	key_help.enabled = false
	h.eq('window wheel mapping drops with the mode', nil, sai.viewer._mappings['TR+ScrollUp'])

	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() end, 'do the thing')
	layer.enabled = true
	h.eq('the layer display owns the corner wheel privately', 'private', sai.viewer._mappings['TR+ScrollUp'].kind)
	h.eq('the activator keyboard binds stay live', 'Pan up', sai.viewer._mappings['Up'].desc)
	layer.enabled = false
	h.eq('corner wheel mapping drops with the display', nil, sai.viewer._mappings['TR+ScrollUp'])
end)

-- enable cycles must not accumulate records: the two scroll binds sit on
-- the registry stack exactly once while the mode runs
T.help_pager_records_stable = with_env(function(h)
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.enabled = true
	local stack = require('sai.lib.registry').binds[sai.modes[1]]['TR+ScrollUp']
	h.eq('one scroll bind record while enabled', 1, #stack)
	for _ = 1, 3 do
		layer.enabled = false
		layer.enabled = true
	end
	h.eq('cycles do not grow the record stack', 1, #stack)
	layer.enabled = false
	h.eq('record gone with the mode', 0, #stack)
end)

H.maybe_standalone(T)

return T
