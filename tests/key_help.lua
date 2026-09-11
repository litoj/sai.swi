---Tests for sai.mode.key_help: tabs, layers, corner displays.
---Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.var_help' }
local sai, key_help = env.sai, env.key_help
local var_help = env.mods['sai.mode.var_help']
local raw_binds, with_env = env.raw_binds, env.with_env
local remapper = require 'sai.lib.remapper'

local function render_pager(pager)
	local out = {}
	for _, line in ipairs(pager.lines) do
		---@cast line string|mode_base.text.dyntext
		out[#out + 1] = type(line) == 'string' and line or line.callback()
	end
	return table.concat(out, '\n')
end

local function find_line_with(pager, text)
	for _, line in ipairs(pager.lines) do
		---@cast line string
		if line:find(text, 1, true) then return line end
	end
end

local function tabs_of(m)
	m:gen_tabs()
	return m._tabs
end

local function rendered_header(block) return (sai.viewer.text[block] or {})[1] or '' end

---Everything after the current app mode.
local function custom_count()
	-- components (pagers) ride along their host: not bind layers of their own
	local n = 0
	for i = 2, #sai.modes do
		if not rawget(sai.modes[i], 'component') then n = n + 1 end
	end
	return n
end

local T = {}

T.key_help_lifecycle = with_env(function(h)
	sai.viewer.map('F13', function() end) -- no desc: must fall back to the simplified trace
	key_help.enabled = true
	h.ok('key help enabled', key_help.enabled)
	h.eq('registered as bind layer of the current mode', 1, custom_count())
	h.ok('binds applied to the raw api', raw_binds['viewer:Escape'] ~= nil)
	h.eq('own display sits on the right', 'topright', key_help.pager.location)
	h.ok('window scrolls registered on the display', key_help.pager._mappings['ScrollUp'] ~= nil)

	h.eq('first tab is the base mode', key_help.pager.title, 'Viewer')
	h.ok('mode binds listed', #key_help.pager.lines > 0)
	local title = (sai.viewer.text.topright or {})[1] or ''
	h.contains('page counter when the tab spans pages', title, '[Page')
	h.contains('the corner title names the mode', title, 'Viewer')

	-- a bind without a description must fall back to the simplified trace,
	-- not the raw traceback
	h.ok('no raw stack traces in the bind list', find_line_with(key_help.pager, 'stack traceback') == nil)
	local f13_line = find_line_with(key_help.pager, 'F13')
	h.ok('undescribed bind listed', f13_line ~= nil)
	h.ok(
		'undescribed bind shows the simplified call site',
		f13_line ~= nil and not f13_line:find('keybind_processor', 1, true)
	)
	h.ok('undescribed bind shows only the first trace line', f13_line ~= nil and not f13_line:find('\n', 1, true))

	key_help.tab = 1
	key_help.enabled = false
	key_help.enabled = true
	h.contains('reenable shows the same tab', key_help.pager.title, 'Viewer')
	h.eq('reenable keeps the tab number', 1, key_help.tab)

	sai.viewer.unmap 'F13'
	key_help.enabled = false
	h.ok('key help disabled', not key_help.enabled)
	h.eq('bind layer removed', 0, custom_count())
	h.eq('original bind restored', 'Exit application', sai.viewer._mappings['Escape'].desc)
end)

-- The tab set mirrors the active layers through the bind registry.
-- Default view: each bind shows exactly once, on the tab of the layer that owns it.
-- var_help opted out of the displays (`help_pager = false`): no tab of its own.
-- `list = 'all'`: every layer lists its full bind set,
-- the base tab restores the overridden originals.
T.key_help_tabs_follow_active_layers = with_env(function(h)
	sai.mode = 'viewer'
	key_help.tab = 1

	local function tab_titles(m)
		local out = {}
		for _, t in ipairs(tabs_of(m)) do
			out[#out + 1] = t.title
		end
		return table.concat(out, '\n')
	end

	key_help.enabled = true
	h.eq('no own tab: only the base mode', 'Viewer', tab_titles(key_help))

	var_help.enabled = true
	h.eq('an opted-out layer grows no tab', 'Viewer', tab_titles(key_help))
	h.eq('key help joins the var help tabs', 'Main API Settings\nVar Help\nKey Help', tab_titles(var_help))
	key_help.enabled = false
	var_help.enabled = false

	var_help.enabled = true
	key_help.enabled = true
	h.eq('key help owns the shared keys after the flip', 'Viewer', tab_titles(key_help))
	h.eq('var help lists both after the flip', 'Main API Settings\nKey Help\nVar Help', tab_titles(var_help))

	key_help.list = 'all'
	h.eq('the all listing shows every active layer', 'Viewer', tab_titles(key_help))
	h.contains(
		'the base tab restores the overridden originals',
		table.concat(tabs_of(key_help)[1].lines, '\n'),
		'Exit application'
	)
	key_help.list = 'effective'

	key_help.enabled = false
	var_help.enabled = false
end)

T.key_help_mode_change = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	key_help.tab = 1
	key_help.enabled = true
	h.contains('the base tab shown before the flip', key_help.pager.title, 'Viewer')

	sai.mode = 'gallery' -- fires ModeChangedPre + ModeChanged
	h.eq('re-registered on the new mode', 1, custom_count())
	h.eq('the app-mode head follows the flip', sai.gallery, sai.modes[1])
	h.ok('binds re-applied on the new mode', sai.gallery._mappings['Escape'] ~= nil)
	h.contains('the base tab follows the flip', key_help.pager.title, 'Gallery')
	h.eq('tab number kept across the flip', 1, key_help.tab)

	sai.mode = 'viewer'
	h.contains('the base-mode tab follows the mode back', key_help.pager.title, 'Viewer')

	key_help.enabled = false
	h.eq('bind layer removed after mode change', 0, custom_count())
	h.ok('the key help display is down', not key_help.pager._enabled)
end)

T.key_help_dynamic_layers = with_env(function(h)
	key_help.enabled = true
	h.contains('one tab before the push', key_help.pager.title, 'Viewer')

	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('d', function() end, 'dyn')

	layer.enabled = true
	h.contains('push regenerated the tabs, first one shown', key_help.pager.title, 'Test Layer')

	key_help.tab = 2
	h.contains('main mode tab is last', key_help.pager.title, 'Viewer')

	layer.enabled = false
	h.contains('pop regenerated the tabs, first one shown', key_help.pager.title, 'Viewer')

	layer.enabled = true
	key_help.tab = 1
	h.contains('layer tab viewable', key_help.pager.title, 'Test Layer')
	layer.enabled = false
	h.contains('viewed layer removed, back on the first tab', key_help.pager.title, 'Viewer')

	-- a layer without binds still gets a tab
	local quiet = remapper.new { _path = 'sai.mode.quiet' }
	quiet.enabled = true
	h.ok('bindless layer gets an empty tab', key_help.pager.title:find('Quiet', 1, true) ~= nil)
	quiet.enabled = false

	key_help.enabled = false
end)

-- Every mode carries its own corner display: it comes up with the mode,
-- lists its binds, and goes down with it. The corner records stack: the
-- topmost mode's display owns the wheel, the one below re-emerges on pop.
T.key_help_auto_display = with_env(function(h)
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() end, 'do the thing')

	h.ok('no display before the mode', not layer.help_pager._enabled)
	layer.enabled = true
	h.ok('the mode brings its display up', layer.help_pager._enabled)
	h.eq('the display rides the mode layer, no extra bind layer', 1, custom_count())
	h.contains('the mode opens on its own tab', layer.help_pager.title, 'Test Layer')
	h.ok('no tab block without the control binds', not rendered_header('topright'):find('Tab', 1, true))
	h.contains('mode binds listed', render_pager(layer.help_pager), 'do the thing')

	-- F1 full mode over the display, then back to the mode's own one
	key_help.enabled = true
	h.ok('the full key help takes over', key_help._enabled)
	h.contains('tab block with the control binds', rendered_header 'topright', 'Tab')
	key_help.enabled = false
	h.ok('the mode display still up', layer.help_pager._enabled)
	h.eq('the layer display re-owns the corner', 'private', sai.viewer._mappings['TR+ScrollUp'].kind)
	h.ok('the mode binds back on the corner', render_pager(layer.help_pager), 'do the thing')

	local layer2 = remapper.new { _path = 'sai.mode.test_layer2' }
	layer2.map('F14', function() end, 'other thing')
	layer2.enabled = true
	h.ok('the newer display takes the corner', layer2.help_pager._enabled)
	h.eq('the top wheel belongs to the newer display', 'private', sai.viewer._mappings['TR+ScrollUp'].kind)
	layer2.enabled = false
	h.ok('the lower display back on the corner', layer.help_pager._enabled)
	h.contains('corner content restored with the pop', render_pager(layer.help_pager), 'do the thing')

	-- a mode that opted out: no display, no key help tab
	local quiet = remapper.new { _path = 'sai.mode.quiet', help_pager = false }
	quiet.map('F15', function() end, 'quiet thing')
	quiet.enabled = true
	h.ok('opted out: no display', not quiet.help_pager)
	h.ok('the lower display keeps the corner', layer.help_pager._enabled)
	key_help.enabled = true
	local titles = {}
	for _, t in ipairs(tabs_of(key_help)) do
		titles[#titles + 1] = t.title
	end
	h.ok('opted out: no key help tab', not table.concat(titles, '\n'):find('Quiet', 1, true))
	key_help.enabled = false
	quiet.enabled = false

	layer.enabled = false
	h.ok('display off after the last mode', not layer.help_pager._enabled)
end)

-- A persisting mode's display follows a base-mode flip: the pager's own
-- bracket moves the block into the new mode's text layer, the layer's
-- bracket re-applies the binds and regenerates the content
T.key_help_auto_display_follows_mode_flip = with_env(function(h)
	sai.mode = 'viewer'
	local layer = remapper.new { _path = 'sai.mode.test_layer', persist_mode_change = true }
	layer.map('F13', function() end, 'do the thing')
	layer.enabled = true
	h.ok('the mode brings its display up', layer.help_pager._enabled)
	-- the whole block: the section header may shift the bind lines around
	local function block(api) return table.concat(api.text.topright or {}, '\n') end

	h.contains('the binds shown in viewer', block(sai.viewer), 'do the thing')

	sai.mode = 'gallery'
	h.contains('the binds moved to gallery', block(sai.gallery), 'do the thing')
	h.ok('pager still up after the flip', layer.help_pager._enabled)

	sai.mode = 'viewer'
	h.contains('the binds follow the mode back', block(sai.viewer), 'do the thing')
	layer.enabled = false
end)

-- F1 cycles the key help: off -> effective listing -> full listing -> off.
-- The listing flip must re-render the open tab, not only the option.
T.key_help_cycle = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	local f1 = raw_binds['viewer:F1']
	key_help.tab = 1

	f1()
	h.ok('off -> effective: the mode comes up', key_help.enabled)
	h.eq('the listing starts at effective', 'effective', key_help.list)

	h.ok( -- the only tab is the base tab: the mode's own binds are taken
		'effective: the layer-claimed bind left the base tab',
		not table.concat(key_help.pager.lines, '\n'):find('Exit application', 1, true)
	)

	f1()
	h.ok('effective -> all: the mode stays up', key_help.enabled)
	h.eq('the listing flips to all', 'all', key_help.list)
	h.ok(
		'all: the base tab restores the overridden original in place',
		table.concat(key_help.pager.lines, '\n'):find('Exit application', 1, true)
	)

	f1()
	h.ok('all -> off: the mode goes down', not key_help.enabled)

	f1()
	h.ok('the cycle wraps back to the effective listing', key_help.enabled and key_help.list == 'effective')

	key_help.enabled = false
	key_help.tab = 1 -- later tests start from the first tab
end)

T.key_help_short_binds = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	sai.viewer.map('Ctrl+q', function() end, 'short test')
	key_help.enabled = true

	-- gather every tab line so the bind is found regardless of which layer it lands in
	local function all_lines()
		local s = {}
		for _, tab in ipairs(tabs_of(key_help)) do
			s[#s + 1] = table.concat(tab.lines, '\n')
		end
		return table.concat(s, '\n')
	end

	key_help.short_binds = false
	local full = all_lines()
	h.contains('full form keeps Ctrl+', full, 'Ctrl+q')
	h.ok('full form is not shortened', not full:find('<C-q>', 1, true))

	-- public option, changeable at any time: next render picks it up
	key_help.short_binds = true
	local short = all_lines()
	h.contains('short form uses C-', short, '<C-q>')
	h.ok('short form drops the full Ctrl+', not short:find('Ctrl+q', 1, true))

	key_help.short_binds = false
	key_help.enabled = false
	sai.viewer.unmap 'Ctrl+q'
end)

-- Tab switches are served from the built-tab cache: the generator runs only
-- when the content changes (layer toggles, option writes), never on a
-- plain tab switch.
T.key_help_tab_cache = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	key_help.list = 'effective'
	key_help.enabled = true

	local builds = 0
	local orig = key_help.gen_tabs
	key_help.gen_tabs = function(self) -- count the (re)builds
		builds = builds + 1
		orig(self)
	end

	key_help.tab = key_help.tab + 1 -- plain switch: served from the cache
	h.eq('a tab switch does not rebuild', 0, builds)

	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.enabled = true
	h.eq('a layer push rebuilds once', 1, builds)

	key_help.tab = 1
	h.eq('switches after the push stay cached', 1, builds)

	key_help.list = 'all' -- the option setter re-renders from a rebuild
	h.eq('an option write rebuilds once', 2, builds)

	key_help.gen_tabs = orig
	key_help.enabled = false
	layer.enabled = false
	key_help.list = 'effective'
end)

-- a mode with sub-modes (the filter with its completion menu): one tab
-- for the root, the sub-modes' binds under their own sub-headers inside
T.tabs_group_sub_modes = with_env(function(h)
	local m = require('sai.mode.image_filter').new { _path = 'sai.mode.image_filter' }
	m.enabled = true
	-- the menu rides the filter's layer: its keys list with it

	local tabs = tabs_of(key_help)
	h.eq('one tab for the root mode', 'Image Filter', tabs[1].title)
	h.eq('the base mode tab follows', 'Viewer', tabs[2].title)

	local lines = tabs[1].lines
	local header_at, rootbind_at = 0, 0
	for i, line in ipairs(lines) do
		---@cast line string
		if line == '[Completion]' then header_at = i end
		if line:find('Esc', 1, true) then rootbind_at = i end
	end
	h.ok('the submodule binds follow under their sub-header', header_at > 0)
	h.ok('the root binds come before the sub-header', rootbind_at > 0 and rootbind_at < header_at)

	-- the ownership follows what the action does: the input actions are
	-- the filter's, the menu keys the menu's
	local root, sub = {}, {}
	for i, line in ipairs(lines) do
		---@cast line string
		if i < header_at then
			root[#root + 1] = line
		elseif i > header_at then
			sub[#sub + 1] = line
		end
	end
	local root_str, sub_str = table.concat(root, '\n'), table.concat(sub, '\n')
	h.contains('confirm input belongs to the filter', root_str, 'Confirm')
	h.contains('abort input belongs to the filter', root_str, 'Abort')
	h.contains('hide mode belongs to the filter', root_str, 'Hide mode')
	h.contains('the menu keeps its accept key', sub_str, 'Accept completion')
	h.contains('the menu keeps its navigation', sub_str, 'Next completion')
	h.ok('no input actions under the menu', not sub_str:find('Confirm', 1, true))
	h.ok('no hide under the menu', not sub_str:find('Hide mode', 1, true))

	m.enabled = false
end)

H.maybe_standalone(T)

return T
