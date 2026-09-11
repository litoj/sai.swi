---Tests for sai.mode.help: the base pager and its scrolls.
---Over a recording api stack.
---Development tool: not used during normal swayimg operation.
---
---The sub-mode tab/group tests live on their subjects now
---(tests/key_help.lua, tests/var_help.lua, tests/image_filter.lua).

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/' or ''
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
dir = dir:gsub('/%./', '/'):gsub('/%.?$', '')
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local sai, key_help = env.sai, env.key_help
local raw_binds, with_env = env.raw_binds, env.with_env
local remapper = require 'sai.lib.remapper'
local at = H.mouse_stub(env.swayimg)

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

-- enable holds with no current image: the fit-scale needs one
T.enable_without_image_skips_fit_scale = with_env(function(h)
	sai.mode = 'viewer'
	local raw = env.swayimg.viewer
	local old = raw.get_image
	raw.get_image = function() end
	local ok = pcall(function() key_help.enabled = true end)
	raw.get_image = old
	h.ok('enable holds with no current image', ok)
	if ok then key_help.enabled = false end
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
	-- the viewer's plain wheel pans the image: count it instead, the
	-- stub app carries no image position
	local pans = 0
	local pan_scroll = sai.viewer.remap('Scroll', { cb = function() pans = pans + 1 end })

	key_help.enabled = true
	local lines = table.concat(key_help.pager.lines, '\n')
	h.ok('the wheel scroll stays out of the display listing', not lines:find('Scroll up', 1, true))

	local pager = key_help.pager
	at(750, 30) -- the top-right corner: inside the display's block
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('the wheel over the block scrolls the display', 2, pager.scroll)
	h.eq('the display keeps the wheel off the viewer pan', 0, pans)

	local recs = H.capture_notify(sai, function() raw_binds['viewer:unassigned'] 'Up' end)
	h.eq('keyboard scrolling claims the key', 0, #recs)
	h.eq('the display scrolled up a line', 1, pager.scroll)

	key_help.enabled = false
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('window wheel mapping drops with the mode', 1, pager.scroll)
	h.eq('the wheel fell through to the viewer pan', 1, pans)

	local fired = 0
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() fired = fired + 1 end, 'do the thing')
	layer.enabled = true
	layer.help_pager.lines = H.items(20)
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('the layer display owns the corner wheel', 2, layer.help_pager.scroll)

	H.press(raw_binds, 'F13')
	h.eq('the layer keeps its keys: the display claims none', 1, fired)

	layer.enabled = false
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('corner wheel mapping drops with the display', 2, layer.help_pager.scroll)
	h.eq('the wheel fell through to the viewer pan', 2, pans)

	sai.viewer.remap('Scroll', pan_scroll)
end)

-- enable cycles keep the display's wheel exactly-once: one line per
-- tick through them, silence with the display
T.help_pager_records_stable = with_env(function(h)
	-- the viewer's plain wheel pans the image: count it instead, the
	-- stub app carries no image position
	local pans = 0
	local pan_scroll = sai.viewer.remap('Scroll', { cb = function() pans = pans + 1 end })

	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.enabled = true
	for _ = 1, 3 do
		layer.enabled = false
		layer.enabled = true
	end
	layer.help_pager.lines = H.items(20)
	at(750, 30)
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('one wheel tick scrolls one line through the cycles', 2, layer.help_pager.scroll)
	h.eq('the display keeps the wheel off the viewer pan', 0, pans)
	layer.enabled = false
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('the display takes no wheel once disabled', 2, layer.help_pager.scroll)
	h.eq('the wheel fell through to the viewer pan', 1, pans)

	sai.viewer.remap('Scroll', pan_scroll)
end)

H.maybe_standalone(T)

return T
