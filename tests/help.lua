---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for the help mode family: the generic sai.mode.help base and its
---key_help/var_help instances, including the bind-layer awareness they rely on.
---Loads the complete real api stack over a stubbed raw swayimg table, so
---enabling the modes executes the same code as inside swayimg, under plain
---luajit. Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

-- raw C api stand-in: records the binds swayimg would have received;
-- any other method the api stack touches becomes a no-op function
local raw_binds = {}
local function new_raw_mode(name)
	local t = {
		on_key = function(b, fn) raw_binds[name .. ':' .. b] = fn end,
		on_mouse = function(b, fn) raw_binds[name .. ':' .. b] = fn end,
		on_signal = function() end,
		on_unassigned_key = function() end,
		on_image_change = function() end,
		get_image = function() return { width = 500, height = 400, index = 1, path = 'stub', meta = {} } end,
	}
	return setmetatable(t, {
		__index = function()
			return function() end
		end,
	})
end

-- capture the globals before the api stack replaces them: they must be back
-- in place for the test modules that run after this one (like ipc)
local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')

local resize_cb
local gallery_stub = new_raw_mode 'gallery'
gallery_stub.thumb_size = 128 -- read by the help modes for the backdrop sizing
gallery_stub.padding_size = 10
local swayimg = {
	mode = 'viewer',
	viewer = new_raw_mode 'viewer',
	slideshow = new_raw_mode 'slideshow',
	gallery = gallery_stub,
	imagelist = { size = 0 },
	text = {},
	defer = function() end,
	on_window_resize = function(fn) resize_cb = fn end,
	get_window_size = function() return { width = 800, height = 600 } end,
}
_G.swayimg = swayimg

local sai = require 'sai.api.init'
resize_cb() -- app initialization: also registers the default binds
local sai_proxy = _G.sai

local key_help = require 'sai.mode.key_help'
local var_help = require 'sai.mode.var_help'

-- the api stack and the modes read the globals at runtime, so lend them the
-- stubbed environment just for the duration of each method
_G.swayimg, _G.sai = old_swi, old_sai
local function with_env(fn)
	return function(h)
		_G.swayimg, _G.sai = swayimg, sai_proxy
		local ran, err = pcall(fn, h)
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

-- resolve the text layer templates/event definitions into their current text
local function rendered(pager)
	local out = {}
	for _, line in ipairs(pager.lines) do
		---@cast line string|mode_base.text.dyntext
		out[#out + 1] = type(line) == 'string' and line or line.callback()
	end
	return table.concat(out, '\n')
end

local T = {}

T.key_help_lifecycle = with_env(function(h)
	sai.viewer.map('F13', function() end) -- no desc: must fall back to the simplified trace
	key_help.enabled = true
	h.ok('mode enabled', key_help._enabled)
	h.eq('registered as bind layer of the current mode', 1, #sai.viewer._active_modes)
	h.ok('binds applied to the raw api', raw_binds['viewer:Escape'] ~= nil)
	h.eq('pager in the right pane', 'topright', key_help.pager.location)
	h.ok('no display self-recursion', key_help.auto_help == false)

	h.contains('pager title', key_help.pager.title, 'Key Help')
	h.contains('first tab is the topmost bind layer', key_help.pager.title, 'Key Help')
	h.ok('own binds listed', #key_help.pager.lines > 0)
	h.ok('no page counter when it fits one page', not rawget(key_help.pager, '_last_render')[0]:find('[Page', 1, true))
	h.contains('rendered title', rawget(key_help.pager, '_last_render')[0], 'Key Help')

	key_help.tab = key_help.tab + 1
	h.contains('second tab is the main mode', key_help.pager.title, 'Viewer')
	h.ok('mode binds listed', #key_help.pager.lines > 0)
	h.contains('page counter when paging', rawget(key_help.pager, '_last_render')[0], '[Page 1/2]')

	-- a bind without a description must fall back to the simplified trace, not the raw traceback
	local raw_trace_bind
	for _, line in ipairs(key_help.pager.lines) do
		if line:find('stack traceback', 1, true) then raw_trace_bind = line end
	end
	h.ok('no raw stack traces in the bind list', raw_trace_bind == nil)
	h.ok(
		'undescribed bind shows the simplified call site',
		(function()
			for _, line in ipairs(key_help.pager.lines) do
				if line:find('F13', 1, true) then return not line:find('keybind_processor', 1, true) end
			end
		end)()
	)
	h.ok(
		'undescribed bind shows only the first trace line',
		(function()
			for _, line in ipairs(key_help.pager.lines) do
				if line:find('F13', 1, true) then return not line:find('\n', 1, true) end
			end
		end)()
	)

	key_help.tab = 2
	key_help.enabled = false
	key_help.enabled = true
	h.contains('reenable shows the same tab', key_help.pager.title, 'Viewer')
	h.eq('reenable keeps the tab number', 2, key_help.tab)

	sai.viewer.unmap 'F13'
	key_help.enabled = false
	h.ok('mode disabled', not key_help._enabled)
	h.eq('bind layer removed', 0, #sai.viewer._active_modes)
	h.eq('original bind restored', 'Exit application', sai.viewer._mappings['Escape'].desc)
end)

T.key_help_mode_change = with_env(function(h)
	key_help.enabled = true

	sai.mode = 'gallery' -- fires ModeChangedPre + ModeChanged
	h.eq('re-registered on the new mode', 1, #sai.gallery._active_modes)
	h.eq('old mode cleaned', 0, #sai.viewer._active_modes)
	h.ok('binds re-applied on the new mode', sai.gallery._mappings['Escape'] ~= nil)

	key_help.tab = 2
	h.contains('tabs regenerated for the new mode', key_help.pager.title, 'Gallery')

	key_help.enabled = false
	h.eq('bind layer removed after mode change', 0, #sai.gallery._active_modes)
	h.ok('pager disabled', not key_help.pager._enabled)
end)

T.key_help_dynamic_layers = with_env(function(h)
	local e = require 'sai.api.eventloop'
	key_help.enabled = true
	h.contains('two tabs before the push', key_help.pager.title, 'Key Help')

	-- a bind layer whose key is also applied to the mode api, so
	-- get_active_bindsets lists it (that is what a real enabled layer looks like)
	local cfg = { cb = function() end, desc = 'dyn', _traced = true }
	sai.viewer._mappings['d'] = cfg
	local layer = { _path = 'sai.mode.test_layer', _mappings = { d = cfg } }
	sai.viewer._active_modes[#sai.viewer._active_modes + 1] = layer
	e.trigger { event = 'User', match = 'ModePush', data = layer }
	h.contains('push regenerated the tabs, first one shown', key_help.pager.title, 'Test Layer')

	key_help.tab = 3
	h.contains('main mode tab is last', key_help.pager.title, 'Viewer')

	table.remove(sai.viewer._active_modes)
	e.trigger { event = 'User', match = 'ModePop', data = layer }
	h.contains('pop regenerated the tabs, first one shown', key_help.pager.title, 'Key Help')

	-- viewing the layer's own tab and popping it: back on the first tab
	sai.viewer._active_modes[#sai.viewer._active_modes + 1] = layer
	e.trigger { event = 'User', match = 'ModePush', data = layer }
	key_help.tab = 1
	h.contains('layer tab viewable', key_help.pager.title, 'Test Layer')
	table.remove(sai.viewer._active_modes)
	e.trigger { event = 'User', match = 'ModePop', data = layer }
	h.contains('viewed layer removed, back on the first tab', key_help.pager.title, 'Key Help')

	sai.viewer._mappings['d'] = nil
	key_help.enabled = false
end)

T.key_help_auto_display = with_env(function(h)
	local custom = require 'sai.lib.remapper'
	local layer = custom.new { _path = 'sai.mode.test_layer' }
	layer.map('F13', function() end, 'do the thing')

	h.ok('no display before the mode', not key_help.pager._enabled)
	layer.enabled = true
	h.ok('displayed for the mode', key_help.pager._enabled)
	h.ok('strict: help mode not enabled', not key_help._enabled)
	h.eq('no help bind layer registered', 1, #sai.viewer._active_modes)
	h.contains('the mode own tab shown', key_help.pager.title, 'Test Layer')
	h.ok('no tab block without the control binds', not key_help.pager.title:find('Tab', 1, true))
	h.contains('mode binds listed', table.concat(key_help.pager.lines, '\n'), 'do the thing')

	-- F1 full mode over the display, then back to the strict display
	key_help.enabled = true
	h.ok('full mode takes over', key_help._enabled)
	h.contains('tab block back with the control binds', key_help.pager.title, 'Tab')
	key_help.enabled = false
	h.ok('display restored after the full mode', key_help.pager._enabled)
	h.ok('strict again', not key_help._enabled)
	h.ok('no tab block again', not key_help.pager.title:find('Tab', 1, true))

	local layer2 = custom.new { _path = 'sai.mode.test_layer2' }
	layer2.map('F14', function() end, 'other thing')
	layer2.enabled = true
	h.contains('push retargets the display', key_help.pager.title, 'Test Layer2')
	layer2.enabled = false
	h.contains('pop falls back to the previous mode', key_help.pager.title, 'Test Layer')

	-- a mode without auto_help on top turns the display off
	local quiet = custom.new { _path = 'sai.mode.test_layer', auto_help = false }
	quiet.map('F15', function() end, 'quiet thing')
	quiet.enabled = true
	h.ok('auto_help false: no display', not key_help.pager._enabled)
	quiet.enabled = false
	h.ok('display back with the layer gone', key_help.pager._enabled)

	layer.enabled = false
	h.ok('display off after the last mode', not key_help.pager._enabled)
end)

T.var_help_dynamic_layers = with_env(function(h)
	local custom = require 'sai.lib.remapper'
	local layer = custom.new { _path = 'sai.mode.test_layer' }
	layer.sai.text.size = 42 -- an override to list in the varset sublist

	var_help.enabled = true
	h.contains('settings tab plus own varset', var_help.pager.title, 'Settings')

	layer.enabled = true
	h.contains('push added the layer varset tab', var_help.pager.title, 'Settings')

	var_help.tab = 2
	h.contains('layer varset tab viewable', var_help.pager.title, 'Test Layer')
	h.contains('mode own var listed', rendered(var_help.pager), 'enabled\ttrue')
	h.contains('sai override listed as a fixed value', rendered(var_help.pager), 'text.size\t42')

	var_help.tab = 3
	h.contains('own varset last', var_help.pager.title, 'Var Help')

	layer.enabled = false
	h.contains('pop regenerated the tabs, first one shown', var_help.pager.title, 'Settings')

	var_help.enabled = false
end)

T.var_help_live_values = with_env(function(h)
	key_help.enabled = true
	var_help.enabled = true

	var_help.tab = 3 -- key_help's varset
	h.contains('key_help varset tab', var_help.pager.title, 'Key Help')

	-- the mode's variables are event definitions subscribed to the exact option
	local line_dyne
	for _, line in ipairs(var_help.pager.lines) do
		---@cast line string|mode_base.text.dyntext
		if type(line) == 'table' and line.pattern == 'sai.mode.key_help.pager.line' then line_dyne = line end
	end
	h.ok('nested pager line is an event definition', line_dyne ~= nil)

	key_help.pager.max_height = 0.2 -- constrain the page so the line position can advance
	key_help.pager.line = 2
	h.eq('callback renders the live value', '    line\t2', line_dyne.callback())

	-- the text layer received the update through the event definition
	local updated = false
	local txt = swayimg[sai.mode].text
	if type(txt) == 'table' and type(txt.topleft) == 'table' then
		for _, v in pairs(txt.topleft) do
			if v == '    line\t2' then updated = true end
		end
	end
	h.ok('text layer shows the live value', updated)

	-- no re-render feedback exists anymore: own paging cannot be clobbered
	var_help.pager.line = 2
	h.eq('own pager line kept', 2, var_help.pager.line)

	var_help.enabled = false
	key_help.enabled = false
end)

T.var_help_lifecycle = with_env(function(h)
	var_help.enabled = true
	h.ok('mode enabled', var_help._enabled)
	h.contains('pager title', var_help.pager.title, 'Settings')
	h.contains('settings tab first', var_help.pager.title, 'Settings')
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
	h.contains('three tabs', var_help.pager.title, '1/3')
	var_help.tab = 3 -- skip our own varset, land on key_help's
	h.contains('key_help varset tab', var_help.pager.title, 'Key Help')
	h.ok('key_help overrides listed', #var_help.pager.lines > 0)
	h.contains('var lines show fixed override values', rendered(var_help.pager), 'default_scale\tkeep_width')
	local key_help_varset = rendered(var_help.pager)
	h.contains('nested pager vars listed', key_help_varset, '  pager:')
	h.contains('nested pager field shown', key_help_varset, '    enabled\ttrue')
	h.ok('super not listed', not key_help_varset:find('super', 1, true))
	h.ok('help_pager not listed', not key_help_varset:find('help_pager', 1, true))
	h.ok('sai reconfigurer not listed', not key_help_varset:find('  sai:', 1, true))

	var_help.enabled = false
	key_help.enabled = false
end)

T.cmd_auto_display = with_env(function(h)
	sai.text.enabled = false -- the text overlay is off in the user config
	-- the full-mode disable below cmd restores binds out of order: fix the
	-- stale viewer mapping afterwards
	local escape = sai.viewer._mappings['Escape']
	local cmd = require('sai.mode.cmd').new {}

	key_help.enabled = true
	h.ok('full mode on', key_help._enabled)
	cmd.enabled = true
	h.ok('overlay on with the display', sai.text.enabled == true)
	key_help.enabled = false
	h.ok('display re-derived', key_help.pager._enabled)
	h.ok('overlay healed', sai.text.enabled == true)
	h.contains('the mode own tab shown', key_help.pager.title, 'Cmd')
	h.ok('strict again', not key_help._enabled)

	cmd.enabled = false
	h.ok('display off with the last mode', not key_help.pager._enabled)
	h.ok('overlay reverted with the display', sai.text.enabled == false)
	sai.viewer._mappings['Escape'] = escape
end)

T.cmd_auto_display_block_location = with_env(function(h)
	sai.text.enabled = false -- the text overlay is off in the user config
	local escape = sai.viewer._mappings['Escape']
	local filter = require('sai.mode.cmd').new { _path = 'test.filter' }
	filter._location = 'topleft' -- the filter shape: a text block, not the status

	filter.enabled = true
	h.ok('layer up with the mode', sai.text.enabled == true)
	h.ok('block armed', #sai.viewer.text.topleft > 0)

	key_help.enabled = true -- F1: the full mode over the display
	key_help.enabled = false
	h.ok('display re-derived', key_help.pager._enabled)

	h.eq('layer healed', true, sai.text.enabled)
	h.ok('our block survived', #sai.viewer.text.topleft > 0)
	h.ok('user blocks restored', #sai.viewer.text.bottomleft > 0)

	filter.enabled = false
	sai.viewer._mappings['Escape'] = escape
end)

T.cmd_block_cleanup_on_disable = with_env(function(h)
	sai.text.enabled = true -- the user config has the overlay on
	local escape = sai.viewer._mappings['Escape']
	local filter = require('sai.mode.cmd').new { _path = 'test.filter' }
	filter._location = 'topleft' -- the filter shape: a text block, not the status

	key_help.enabled = true -- the auto help display holds the layer up
	sai.text.topleft = {} -- the user's topleft is empty

	filter.enabled = true
	h.ok('block armed', #sai.viewer.text.topleft > 0)
	filter.enabled = false
	h.ok('empty block restored', #sai.viewer.text.topleft == 0)
	h.eq('layer kept by the display', true, sai.text.enabled)

	key_help.enabled = false
	sai.viewer._mappings['Escape'] = escape
end)

T.key_help_short_binds = with_env(function(h)
	sai.mode = 'viewer' -- earlier tests may have left another mode active
	sai.viewer.map('Ctrl+q', function() end, 'short test')
	key_help.enabled = true

	-- gather every tab line so the bind is found regardless of which layer it lands in
	local function all_lines()
		local s = {}
		for _, tab in ipairs(key_help:tabs()) do
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

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
