---Tests for sai.mode.var_help: settings and varset tabs.
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
local with_env = env.with_env
local remapper = require 'sai.lib.remapper'

local function render_pager(pager)
	local out = {}
	for _, line in ipairs(pager.lines) do
		---@cast line string|mode_base.text.dyntext
		out[#out + 1] = type(line) == 'string' and line or line.callback()
	end
	return table.concat(out, '\n')
end

local function rendered_header(block) return (sai.viewer.text[block] or {})[1] or '' end

local T = {}

T.var_help_dynamic_layers = with_env(function(h)
	local layer = remapper.new { _path = 'sai.mode.test_layer' }
	layer.sai.text.size = 42 -- an override to list in the varset sublist

	var_help.enabled = true
	h.contains('the settings tab shows', var_help.pager.title, 'Settings')

	layer.enabled = true
	h.contains('the layer push keeps the settings tab', var_help.pager.title, 'Settings')

	var_help.tab = 2
	h.contains('the layer varset tab opens', var_help.pager.title, 'Test Layer')
	h.contains('the layer varset lists its vars', render_pager(var_help.pager), 'enabled\ttrue')
	h.contains('sai override listed as a fixed value', render_pager(var_help.pager), 'text.size\t42')

	var_help.tab = 3
	h.contains('own varset tab comes last', var_help.pager.title, 'Var Help')

	layer.enabled = false
	h.contains('pop regenerated the tabs, first one shown', var_help.pager.title, 'Settings')

	var_help.enabled = false
end)

T.var_help_live_values = with_env(function(h)
	key_help.enabled = true
	var_help.enabled = true

	var_help.tab = 3 -- key_help's varset
	h.contains('the key_help varset tab shows', var_help.pager.title, 'Key Help')

	-- the mode's variables are event definitions subscribed to the exact option
	local line_dyne
	for _, line in ipairs(var_help.pager.lines) do
		---@cast line string|mode_base.text.dyntext
		if type(line) == 'table' and line.pattern == 'sai.mode.key_help.pager.scroll' then line_dyne = line end
	end
	h.ok('nested display line is an event definition', line_dyne ~= nil)

	-- the text layer arms only the displayed rows: scroll the var row
	-- into the window so its event definition goes live
	local var_lines, var_scroll = var_help.pager.lines, var_help.pager.scroll
	for i, line in ipairs(var_help.pager.lines) do
		if line == line_dyne then var_help.pager.scroll = i end
	end

	-- seed lines so the scroll has somewhere to advance; saved back after,
	-- later tests render this pager again
	local kh_lines, kh_height = key_help.pager.lines, key_help.pager.max_height
	key_help.pager.lines = { 'a', 'b', 'c', 'd', 'e' }
	key_help.pager.max_height = 0.2 -- constrain the page so the line position can advance
	key_help.pager.scroll = 2
	h.eq('callback renders the live value', '    scroll\t2', line_dyne.callback())

	-- the text layer received the update through the event definition
	local updated = false
	local txt = swayimg[sai.mode].text
	if type(txt) == 'table' and type(txt.topleft) == 'table' then
		for _, v in pairs(txt.topleft) do
			if v == '    scroll\t2' then updated = true end
		end
	end
	h.ok('text layer shows the live value', updated)

	-- no re-render feedback exists anymore: own paging cannot be clobbered
	var_help.pager.scroll = 2
	h.eq('own pager scroll kept', 2, var_help.pager.scroll)

	key_help.pager.lines, key_help.pager.max_height = kh_lines, kh_height
	key_help.pager.scroll = 0
	var_help.pager.lines, var_help.pager.scroll = var_lines, var_scroll
	var_help.enabled = false
	key_help.enabled = false
end)

T.var_help_lifecycle = with_env(function(h)
	var_help.enabled = true
	h.ok('mode enabled', var_help._enabled)
	h.contains('pager title, settings tab first', var_help.pager.title, 'Settings')
	h.ok('settings lines listed', #var_help.pager.lines >= 6)

	var_help.tab = var_help.tab + 1
	h.contains('own overrides listed as a varset tab', var_help.pager.title, 'Var Help')
	h.ok('varset lines listed', #var_help.pager.lines > 0)

	var_help.enabled = false
	h.ok('mode disabled without pager errors', not var_help._enabled)
end)

T.var_help_mode_varsets = with_env(function(h)
	key_help.enabled = true
	var_help.enabled = true
	var_help.tab = 1 -- a previous test may have left it on another tab
	-- tabs: all settings + one varset per active mode, topmost first
	h.contains('the header counts three tabs', rendered_header 'topleft', '1/3')
	var_help.tab = 3 -- skip our own varset, land on key_help's
	h.contains('the key_help varset tab shows', var_help.pager.title, 'Key Help')
	h.ok('key_help overrides listed', #var_help.pager.lines > 0)
	h.contains('var lines show fixed override values', render_pager(var_help.pager), 'default_scale\tkeep_width')
	local key_help_varset = render_pager(var_help.pager)
	h.contains('nested display vars listed', key_help_varset, '  pager:')
	h.contains('nested display field shown', key_help_varset, '    enabled\ttrue')
	h.ok('super not listed', not key_help_varset:find('super', 1, true))
	h.ok('internal _path not listed', not key_help_varset:find('_path', 1, true))
	h.ok('sai reconfigurer not listed', not key_help_varset:find('  sai:', 1, true))

	var_help.enabled = false
	key_help.enabled = false
end)

-- title_fmt is a plain field: no option event, no message on write
T.var_help_title_fmt = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	var_help.tab = 1
	var_help.enabled = true
	var_help.pager.max_height = 0.2 -- a page per line: the settings tab pages

	local orig = var_help.pager.title_fmt
	var_help.pager.title_fmt = function(_, title, page_block)
		return (page_block and (page_block .. ' ') or '') .. title:upper()
	end
	var_help.tab = 1 -- re-render through the new composition
	h.contains('page block handed to the composition', rendered_header 'topleft', '[Page 1/')
	h.contains('custom composition applies', rendered_header 'topleft', 'SETTINGS')

	var_help.pager.title_fmt = orig
	var_help.tab = 1 -- re-render so the default composition comes back
	h.contains('default shows the plain title again', rendered_header 'topleft', 'Settings')
	h.ok('custom composition gone', not rendered_header('topleft'):find('SETTINGS', 1, true))

	var_help.pager.max_height = 1
	var_help.enabled = false
end)

-- var help groups the same way, but the machinery stays out: the
-- completion is a component on the filter's tree - no group of its own,
-- the shared tree's overrides show under the root only
T.components_grow_no_varset_groups = with_env(function(h)
	local m = require('sai.mode.image_filter').new { _path = 'sai.mode.image_filter' }
	m.sai.text.size = 42 -- a shared-tree override: the root's to list
	m.enabled = true
	-- the menu rides the filter's layer, its tree is the filter's

	var_help.enabled = true
	var_help.tab = 3 -- settings + var help (newest) + the filter's group
	h.contains('the filter varset tab shows', var_help.pager.title, 'Image Filter')

	local out = render_pager(var_help.pager)
	h.contains('the shared sai override listed under the root', out, 'text.size\t42')
	-- a section is a standalone line: the machinery's binds ride the
	-- corner display, whose lines var dump mentions as plain data
	local section = false
	for _, line in ipairs(var_help.pager.lines) do
		---@cast line string|mode_base.text.dyntext
		if (type(line) == 'string' and line or line.callback()) == '[Completion]' then section = true end
	end
	h.ok('the completion machinery grows no sub-list', not section)
	local first = out:find('sai overrides', 1, true)
	h.ok(
		'no second overrides block under the sub-list',
		first ~= nil and out:find('sai overrides', first + 1, true) == nil
	)

	m.enabled = false
	var_help.enabled = false
end)

-- Confirming a filtered var prompts for its new value and sets it.
T.var_help_filter_prompts_for_value = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	key_help.enabled = true
	var_help.enabled = true
	local idx = 1
	for i, tab in ipairs(var_help._tabs) do
		if tab.title == 'Key Help' then idx = i end
	end
	var_help.tab = idx
	var_help:open_filter()
	var_help.filter.text = 'short_binds'
	h.ok('the name leads the value matches', #var_help.pager.lines >= 1)
	h.eq('the variable line first', '  short_binds\tfalse', var_help.filter:filter_render(var_help.pager.lines[1]))
	var_help.filter:confirm()
	h.ok('the input closed', not var_help.filter._enabled)

	local input
	for _, m in ipairs(sai.modes) do
		local prompt = rawget(m, '_prompt')
		if type(prompt) == 'string' and prompt:find('short_binds', 1, true) then input = m end
	end
	h.ok('the value prompt opened', input ~= nil)
	if input then
		input.text = 'true'
		input:confirm()
	end
	h.eq('the variable took the value', true, key_help.short_binds)
	key_help.short_binds = false
	var_help.enabled = false
	key_help.enabled = false
end)

-- Mode-bound getters throw outside their mode: unreadable vars stay out of
-- the varset entirely, so neither the display nor the filtering can trip them.
T.var_help_skips_unreadable_vars = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.test_unreadable' }
	-- rawset: the backer rejects plain writes without a setter
	rawset(mode, '_fine', 1)
	rawset(mode, 'set_fine', function() end)
	rawset(mode, '_boom', 1)
	rawset(mode, 'set_boom', function() end)
	rawset(mode, 'get_boom', function() error 'gone with the mode' end)

	local out = {}
	for _, entry in ipairs(var_help:varset_lines(mode, false)) do
		-- rendering the row reads the var: an included boom would throw here
		out[#out + 1] = type(entry.line) == 'string' and entry.line or entry.line.callback()
	end
	local text = table.concat(out, '\n')
	h.contains('readable var listed', text, 'fine')
	h.ok('unreadable var absent', not text:find('boom', 1, true))
	mode.enabled = false
end)

H.maybe_standalone(T)

return T
