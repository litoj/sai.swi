---Tests for sai.mode.key_help: tabs, layers, corner displays.
---Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/' or ''
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
dir = dir:gsub('/%./', '/'):gsub('/%.?$', '')
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.var_help' }
local sai, key_help = env.sai, env.key_help
local var_help = env.mods['sai.mode.var_help']
local raw_binds, with_env = env.raw_binds, env.with_env
local remapper = require 'sai.lib.remapper'
local e = require 'sai.api.eventloop'
local at = H.mouse_stub(env.swayimg)

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
	h.eq('own display sits on the right', 'topright', key_help.pager.location)
	at(750, 30) -- the top-right corner: inside the display's block
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('the wheel over the block scrolls the display', 2, key_help.pager.scroll)

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

	-- the overlay's own binds went live with it: 'q' closes it
	H.press(raw_binds, 'q')
	h.ok('the overlay owns its keys: q closed it', not key_help.enabled)

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
-- var_help carries its corner display: its tab grows with the mode.
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
	h.eq('a displayed layer grows its tab', 'Var Help\nViewer', tab_titles(key_help))
	h.eq('key help joins the var help tabs', 'Main API Settings\nVar Help\nKey Help', tab_titles(var_help))
	key_help.enabled = false
	var_help.enabled = false

	var_help.enabled = true
	key_help.enabled = true
	h.eq('key help owns the shared keys after the flip', 'Var Help\nViewer', tab_titles(key_help))
	h.eq('var help lists both after the flip', 'Main API Settings\nKey Help\nVar Help', tab_titles(var_help))

	key_help.list = 'all'
	h.eq('the all listing shows every active layer', 'Var Help\nViewer', tab_titles(key_help))
	local tabs = tabs_of(key_help)
	h.contains(
		'the base tab restores the overridden originals',
		table.concat(tabs[#tabs].lines, '\n'),
		'Exit application'
	)
	key_help.list = 'effective'

	key_help.enabled = false
	var_help.enabled = false
end)

-- desc-less default binds name their declaration line, not the
-- traceback header: the gen_mapadd fallback trims through its own frame
T.nodesc_default_binds_name_the_declaration_line = with_env(function(h)
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	local map = require('sai.binds').gen_mapadd(layer, { kind = 'default' })
	map('F13', function() end)
	map({ 'F14', 'F15' }, function() end)
	layer.enabled = true
	key_help.enabled = true
	key_help.list = 'all'
	local found = {}
	for _, tab in ipairs(tabs_of(key_help)) do
		for _, line in ipairs(tab.lines) do
			---@cast line string
			if line:find('F13', 1, true) or line:find('F14', 1, true) then found[#found + 1] = line end
		end
	end
	layer.enabled = false
	key_help.enabled = false
	key_help.list = 'effective'
	h.eq('both groups listed', 2, #found)
	for _, line in ipairs(found) do
		h.contains('the declaration file named', line, 'key_help.lua')
		h.ok('no traceback header in the line', not line:find('stack traceback', 1, true))
	end
end)

-- a base bind overridden by an enabled layer keeps its declaration
-- line in the `all` listing: the base tab restores the registry's
-- bottom record, which never passed get_mappings' lazy trim
T.overridden_base_bind_names_the_declaration_line = with_env(function(h)
	sai.mode = 'viewer'
	key_help.tab = 1
	sai.viewer.map('q', function() end)
	sai.viewer.map('k', function() end)
	key_help.enabled = true
	key_help.list = 'all'
	local base_lines = {}
	for _, tab in ipairs(tabs_of(key_help)) do
		if tab.title == 'Viewer' then base_lines = tab.lines end
	end
	local found = {}
	for _, line in ipairs(base_lines) do
		---@cast line string
		if line:sub(1, 2) == 'q\t' or line:sub(1, 2) == 'k\t' then found[#found + 1] = line end
	end
	key_help.enabled = false
	key_help.list = 'effective'
	sai.viewer.unmap 'q'
	sai.viewer.unmap 'k'
	h.eq('both overridden originals restored', 2, #found)
	for _, line in ipairs(found) do
		h.contains('the declaration file named', line, 'key_help.lua')
		h.ok('no traceback header in the line', not line:find('stack traceback', 1, true))
	end
end)

-- The status filter narrows the listing in place: key combos (before
-- the tab) fuzzy first, descriptions (after it) offset by -100.
T.key_help_filter_names_before_descriptions = with_env(function(h)
	sai.mode = 'viewer'
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('alpha', function() end, 'first')
	layer.map('F15', function() end, 'alpha second')
	layer.enabled = true
	key_help.enabled = true
	key_help:open_filter()
	h.ok('the status input opened', key_help.filter._enabled)

	key_help.filter.text = 'alpha'
	local lines = {}
	for _, line in ipairs(key_help.pager.lines) do
		---@cast line string
		lines[#lines + 1] = line
	end
	h.eq('both matches listed', 2, #lines)
	h.ok('the key combo leads', lines[1]:find('first', 1, true) ~= nil)
	h.ok('the description trails', lines[2]:find('second', 1, true) ~= nil)

	key_help.filter:confirm(false)
	h.ok('abort closes the input', not key_help.filter._enabled)
	h.eq('abort restores the full tab', #key_help._entries, #key_help.pager.lines)
	key_help.enabled = false
	layer.enabled = false
end)

-- Confirming the filter runs the selected line's mapping and keeps the narrowed view.
T.key_help_filter_confirm_runs_the_line = with_env(function(h)
	sai.mode = 'viewer'
	local fired = 0
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() fired = fired + 1 end, 'run this probe')
	layer.enabled = true
	key_help.enabled = true
	key_help:open_filter()
	key_help.filter.text = 'run this probe'
	h.eq('one match', 1, #key_help.pager.lines)
	key_help.filter:confirm()
	h.eq('the mapping ran', 1, fired)
	h.ok('the input closed', not key_help.filter._enabled)
	h.eq('the narrowed view stands', 1, #key_help.pager.lines)
	key_help.enabled = false
	layer.enabled = false
end)

-- Navigation follows the filter: the line cursor walks while narrowing,
-- the window scrolls again once the input closes.
T.key_help_filter_nav_walks_lines = with_env(function(h)
	sai.mode = 'viewer'
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() end, 'walk probe')
	layer.map('F14', function() end, 'walk probe')
	layer.enabled = true
	key_help.enabled = true
	key_help:open_filter()
	key_help.filter.text = 'walk probe'
	h.eq('two matches', 2, #key_help.pager.lines)
	H.press(raw_binds, 'Down')
	h.eq('the cursor walked', 2, key_help.pager.line)
	key_help.filter:confirm(false)
	h.eq('abort parks the cursor back up', 1, key_help.pager.line)
	key_help.tab = 2 -- the viewer tab: long enough to scroll
	H.press(raw_binds, 'Down')
	h.eq('idle the cursor stands', 1, key_help.pager.line)
	h.eq('idle the window scrolled', 2, key_help.pager.scroll)
	key_help.tab = 1 -- the tab poke was this test's own: later tests list the pushed layer
	key_help.enabled = false
	layer.enabled = false
end)

-- `/` opens the status filter from the overlay's keys.
T.key_help_slash_opens_the_filter = with_env(function(h)
	sai.mode = 'viewer'
	key_help.enabled = true
	H.press(raw_binds, 'slash')
	h.ok('the status input opened', key_help.filter._enabled)
	key_help.filter:confirm(false)
	key_help.enabled = false
end)

-- Escape settles the filter bar alone: the overlay stands, the full tab returns.
T.key_help_filter_escape_aborts_only_the_filter = with_env(function(h)
	sai.mode = 'viewer'
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() end, 'escape probe')
	layer.map('F14', function() end, 'unrelated line')
	layer.enabled = true
	key_help.enabled = true
	key_help:open_filter()
	key_help.filter.text = 'escape probe'
	h.eq('one match', 1, #key_help.pager.lines)
	H.press(raw_binds, 'Escape')
	h.ok('the overlay stands', key_help._enabled)
	h.ok('the input closed', not key_help.filter._enabled)
	h.ok('the narrowing dropped', not key_help._filtering)
	h.eq('the full tab restored', #key_help._entries, #key_help.pager.lines)
	key_help.enabled = false
	layer.enabled = false
end)

-- Return accepts through the keys: the line runs, the input closes,
-- the narrowed view stands for the window to scroll.
T.key_help_filter_return_accepts = with_env(function(h)
	sai.mode = 'viewer'
	local fired = 0
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() fired = fired + 1 end, 'return probe')
	layer.enabled = true
	key_help.enabled = true
	key_help:open_filter()
	key_help.filter.text = 'return probe'
	h.eq('one match', 1, #key_help.pager.lines)
	H.press(raw_binds, 'Return')
	h.eq('the mapping ran', 1, fired)
	h.ok('the input closed', not key_help.filter._enabled)
	h.eq('the narrowed view stands', 1, #key_help.pager.lines)
	key_help.enabled = false
	layer.enabled = false
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

-- The overlay window is the only writer on its block: a resize
-- recalibrates every enabled display, the open tab must survive it.
T.key_help_resize_keeps_the_window = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	key_help.tab = 1
	key_help.enabled = true
	h.ok('the overlay pager builds no display of its own', not key_help.pager.help_pager)
	h.contains('the window shows the open tab', rendered_header 'topright', 'Viewer')

	local ws = { width = 1200, height = 900 }
	local orig_size = env.swayimg.get_window_size
	env.swayimg.get_window_size = function() return ws end
	e.trigger { event = 'WinResized', data = ws }
	env.swayimg.get_window_size = orig_size
	h.contains('the open tab survives the resize', rendered_header 'topright', 'Viewer')
	h.not_contains('no mode-name-only window appears', rendered_header 'topright', 'Pager')

	key_help.enabled = false
end)

-- Var help keeps its corner display: the control binds list on the
-- topright while the overlay itself sits on the topleft.
T.var_help_corner_display = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	var_help.tab = 1
	var_help.enabled = true
	h.ok('the mode brings its corner display up', var_help.help_pager._enabled)
	h.ok('the overlay pager builds no display of its own', not var_help.pager.help_pager)
	local function corner() return table.concat(sai.viewer.text.topright or {}, '\n') end
	h.contains('the corner lists the control binds', corner(), 'Exit help overlay')

	local ws = { width = 1200, height = 900 }
	local orig_size = env.swayimg.get_window_size
	env.swayimg.get_window_size = function() return ws end
	e.trigger { event = 'WinResized', data = ws }
	env.swayimg.get_window_size = orig_size
	h.contains('the corner keeps the binds after a resize', corner(), 'Exit help overlay')
	h.contains('the overlay window keeps its content', (sai.viewer.text.topleft or {})[1] or '', 'Main API Settings')

	var_help.enabled = false
	h.ok('the corner goes down with the mode', not var_help.help_pager._enabled)
end)

-- F1 cycles the key help: off -> effective listing -> full listing -> off.
-- The listing flip must re-render the open tab, not only the option.
T.key_help_cycle = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	local function f1() raw_binds['viewer:unassigned'] 'F1' end
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
