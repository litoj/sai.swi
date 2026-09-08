---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for sai.lib.remapper: the bind and setting overrides and their
---restoration, on custom modes purposefully written inline - the same
---calls a user mode makes. Each test is a crafted scenario of execution
---order over one or two modes, verified on the expected results as they
---develop (the raw binds, the text layer, the display). Doubles as the
---reference for writing a mode of your own.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local sai, key_help = env.sai, env.key_help
local raw_binds, with_env = env.raw_binds, env.with_env
local remapper = require 'sai.lib.remapper'

local T = {}

-- The bind override: an existing bind gets replaced (its restore target
-- recorded), a previously unmapped key gets mapped (its restore writes the
-- unmap back instead of skipping)
T.bind_override_and_restore = with_env(function(h)
	local escape = sai.viewer._mappings['Escape'] -- the original cfg table

	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.map('Escape', function() end, 'custom exit')
	mode.map('x', function() end, 'custom action')

	mode.enabled = true
	h.eq('existing bind overridden', 'custom exit', sai.viewer._mappings['Escape'].desc)
	h.ok('new bind applied to the raw api', raw_binds['viewer:x'] ~= nil)

	mode.enabled = false
	h.eq('original bind restored', escape, sai.viewer._mappings['Escape'])
	h.eq('new bind unmapped again', nil, sai.viewer._mappings['x'])
end)

-- Two modes stacked, disabled out of order: the top keeps the screen, the
-- lower disable only hands its restore target up (no write), the last one
-- out unwinds to the unmapped base
T.bind_stack_out_of_order = with_env(function(h)
	local a = remapper.new { _path = 'sai.mode.a' }
	a.map('x', function() end, 'from a')
	local b = remapper.new { _path = 'sai.mode.b' }
	b.map('x', function() end, 'from b')
	b.map('y', function() end, 'only b')

	a.enabled = true
	b.enabled = true
	h.eq('topmost bind owns the mode', 'from b', sai.viewer._mappings['x'].desc)

	a.enabled = false -- below the top
	h.eq('top bind kept through the lower disable', 'from b', sai.viewer._mappings['x'].desc)
	h.eq('untouched bind of the top kept', 'only b', sai.viewer._mappings['y'].desc)

	b.enabled = false
	h.eq('bind gone with the last mode', nil, sai.viewer._mappings['x'])
end)

-- map_filter unmaps existing binds for the mode's duration
T.bind_filter = with_env(function(h)
	local escape = sai.viewer._mappings['Escape']

	local mode = remapper.new {
		_path = 'sai.mode.custom',
		map_filter = function(bind) return bind == 'Escape' end,
	}
	mode.map('x', function() end, 'custom action')

	mode.enabled = true
	h.eq('filtered bind removed', nil, sai.viewer._mappings['Escape'])
	h.eq('own bind applied', 'custom action', sai.viewer._mappings['x'].desc)

	mode.enabled = false
	h.eq('filtered bind restored', escape, sai.viewer._mappings['Escape'])
	h.eq('own bind unmapped', nil, sai.viewer._mappings['x'])
end)

-- Setting overrides: field writes on the mode's own sai tree, applied
-- while enabled, restored on disable
T.var_override_and_restore = with_env(function(h)
	sai.text.size = 12

	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.sai.text.size = 42

	mode.enabled = true
	h.eq('setting applied while enabled', 42, sai.text.size)

	mode.enabled = false
	h.eq('setting restored on disable', 12, sai.text.size)
end)

-- The auto help display over a custom mode, and the heal: the full key_help
-- mode disabled below ours must leave a re-derived display and a text
-- layer that still stands - the mode's own status write holds it up, and
-- with the last mode gone the layer reverts to the user's config
T.auto_display_heal = with_env(function(h)
	sai.text.enabled = false -- the text overlay is off in the user config

	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.map('Escape', function() end, 'custom exit')
	mode.sai.text.status = 'custom status'

	key_help.enabled = true -- F1: the full mode
	h.ok('full mode on', key_help._enabled)
	mode.enabled = true
	h.eq('overlay on with the mode', true, sai.text.enabled)

	key_help.enabled = false
	h.ok('display re-derived', key_help.pager._enabled)
	h.ok('overlay healed', sai.text.enabled == true)
	h.contains('the mode shown by the display', key_help.pager.title, 'Custom')
	h.ok('strict again', not key_help._enabled)

	mode.enabled = false
	h.ok('display off with the last mode', not key_help.pager._enabled)
	h.eq('overlay reverted with the display', false, sai.text.enabled)
end)

-- A mode owning a text block under the full key_help mode: the block write
-- arms the layer and blanks the other locations (their base is captured
-- for the restore), the full-mode bracket must heal the layer and keep our
-- block, and our disable cleans its block up while the display holds the
-- layer
T.auto_display_block_heal = with_env(function(h)
	sai.text.enabled = false -- the text overlay is off in the user config
	local mode_text = sai.viewer.text
	sai.text.topleft = {} -- the user's topleft is empty: ours is all there is
	h.ok('user blocks in place', #mode_text.bottomleft > 0) -- the default viewer scheme

	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.sai.text.topleft = { 'our block' }

	mode.enabled = true
	h.eq('layer up with the block write', true, sai.text.enabled)
	h.eq('our block shown', 'our block', mode_text.topleft[1])
	h.ok('other locations blanked by the takeover', #mode_text.bottomleft == 0)

	key_help.enabled = true -- F1: the full mode over the display
	key_help.enabled = false
	h.ok('display re-derived', key_help.pager._enabled)
	h.eq('layer healed', true, sai.text.enabled)
	h.eq('our block survived the bracket', 'our block', mode_text.topleft[1])

	key_help.enabled = true -- the full mode: holds the layer up
	mode.enabled = false -- our disable: the block cleaned, the base held
	h.eq('empty base restored', 0, #mode_text.topleft)
	h.eq('layer kept by the display', true, sai.text.enabled)

	-- the display inherited our takeover of the layer (the restore target
	-- hands up in the registry): the blanked base comes back with it
	key_help.enabled = false
	h.eq('layer off with the display', false, sai.text.enabled)
	h.ok('user blocks restored with the layer', #mode_text.bottomleft > 0)
end)

-- A persist mode survives appmode changes: the remapper brackets its tree
-- around the flip, restoring the blocks into the old mode and re-blanking
-- them into the new one
T.mode_change_bracket = with_env(function(h)
	local mode_text = sai.viewer.text
	local gallery_text = sai.gallery.text
	mode_text.topleft = { 'viewer stale' }
	gallery_text.bottomright = { 'gallery stale' }
	sai.text.enabled = false

	local mode = remapper.new { _path = 'sai.mode.custom', persist_mode_change = true }
	mode.sai.text.topleft = { 'persist block' }

	mode.enabled = true
	h.eq('own block shown', 'persist block', mode_text.topleft[1])
	h.ok('other viewer block emptied', not next(mode_text.bottomright))

	sai.mode = 'gallery' -- fires ModeChangedPre, then ModeChanged

	h.eq('restored into the old mode', 'viewer stale', mode_text.topleft[1])
	h.eq('layer still on', true, sai.text.enabled)
	h.eq('own block re-shown in the new mode', 'persist block', gallery_text.topleft[1])
	h.ok('re-blanked in the new mode', not next(gallery_text.bottomright))

	mode.enabled = false
	h.eq('new mode block restored', 'gallery stale', gallery_text.bottomright[1])
	h.eq('own block released', 'viewer stale', mode_text.topleft[1])
end)

H.maybe_standalone(T)

return T
