---Tests for remapper: binds, vars, restore. Doubles as mode-writing reference.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local sai, key_help = env.sai, env.key_help
local raw_binds, with_env = env.raw_binds, env.with_env
local remapper = require 'sai.lib.remapper'

-- one shared closure: the api proxy caches the pointer getter on first read
local at = H.mouse_stub(env.swayimg)

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

-- Overriding a factory default is the normal user flow, not a duplicate;
-- mapping a plain bind twice warns
T.map_override_warnings = with_env(function(h)
	local viewer = sai.viewer
	local orig_escape = viewer._mappings['Escape']
	local logged = {}
	local old_sai = _G.sai
	_G.sai = { log = function(m) logged[#logged + 1] = m end }
	local ran, err = pcall(function()
		viewer.map('Escape', function() end, 'custom exit')
		h.eq('overriding a default does not warn', 0, #logged)
		viewer.map('q', function() end, 'first')
		viewer.map('q', function() end, 'second')
		h.eq('overriding a plain bind warns', 1, #logged)
	end)
	_G.sai = old_sai
	if not ran then error(err, 0) end

	-- leave the stack as found (arbitrary order)
	viewer:_setmap('Escape', orig_escape)
	viewer:_setmap('q', nil)
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
	h.eq('the topmost bind owns the key', 'from b', sai.viewer._mappings['x'].desc)

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

-- Quadrant binds: TL+/... prefix passes row + position, off the text falls through.
-- Stub 800x600, linepx 42, padding 10.
T.mouse_quadrant_modifiers = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local got, plain = {}, 0
	mode.map('TL+MouseLeft', function(line, loc) got = { line, loc } end, 'top-left action')
	mode.map('BL+MouseRight', function(line, loc) got = { line, loc } end, 'bottom-left action')
	mode.map('MouseLeft', function() plain = plain + 1 end, 'plain action')
	mode.enabled = true

	-- seeded after the enable: the corner arming blanks stale content
	-- (9 rows: the block reaches past the window middle at 300)
	sai.viewer.text.topleft = {
		'the header row',
		'the first row',
		'the second row',
		'the third row',
		'the fourth row',
		'the fifth row',
		'the sixth row',
		'the seventh row',
		'the eighth row',
	}
	sai.viewer.text.bottomleft = { 'the header', 'the bottom row' }

	-- top-left, the first content row below the header
	at(100, 10 + 42 + 21)
	raw_binds['viewer:MouseLeft']()
	h.eq('qualified TL handler fired with the row', '1\ntopleft', table.concat(got, '\n'))
	h.eq('the plain handler stayed out of it', 0, plain)

	-- the third content row
	at(100, 10 + 42 + 2 * 42 + 21)
	raw_binds['viewer:MouseLeft']()
	h.eq('row numbers start below the header', '3\ntopleft', table.concat(got, '\n'))

	-- past the middle, still over the tall block: its section owns the pointer
	at(100, 10 + 8 * 42 + 21)
	raw_binds['viewer:MouseLeft']()
	h.eq('past the middle: still the tall block', '8\ntopleft', table.concat(got, '\n'))
	h.eq('the plain handler stayed out of it', 0, plain)

	-- below the tall block: no section owns the pointer
	at(100, 400)
	raw_binds['viewer:MouseLeft']()
	h.eq('below the block: the plain one ran', 1, plain)

	-- over the header row: the callback still fires, with no row
	at(100, 10 + 21)
	raw_binds['viewer:MouseLeft']()
	h.eq('over the header: no row', 'nil\ntopleft', table.concat({ tostring(got[1]), got[2] }, '\n'))

	-- a click in a quadrant without a qualified handler falls through
	at(700, 100) -- top-right
	raw_binds['viewer:MouseLeft']()
	h.eq('no TR handler: the plain one ran', 2, plain)

	-- bottom-left: the last line sits on the window's bottom edge
	at(100, 600 - 10 - 21)
	raw_binds['viewer:MouseRight']()
	h.eq('bottom row answers at the edge', '1\nbottomleft', table.concat(got, '\n'))
	at(100, 600 - 10 - 42 - 21)
	raw_binds['viewer:MouseRight']()
	h.eq('over the header: no row', 'nil\nbottomleft', table.concat({ tostring(got[1]), got[2] }, '\n'))

	-- right of the topleft text: the plain bind runs
	at(395, 10 + 42 + 21)
	raw_binds['viewer:MouseLeft']()
	h.eq('off the text: the plain one ran', 3, plain)

	-- no pointer position: the plain bind still fires (it is position-independent)
	at()
	raw_binds['viewer:MouseLeft']()
	h.eq('no position: the plain bind fires anyway', 4, plain)

	-- unmapping the qualified bind leaves the plain one working
	mode.map 'TL+MouseLeft'
	at(100, 10 + 42 + 21)
	raw_binds['viewer:MouseLeft']()
	h.eq('unmapped qualifier falls through to the plain bind', 5, plain)

	mode.enabled = false
end)

-- Unassigned keys run the layer stack top-down through the raw dispatch:
-- a handler ends the chain by returning, or passes the key on with
-- fallback(bind), the base fallback ends it all
T.unassigned_chain = with_env(function(h)
	local seen, notified = {}, 0
	local old_notify = env.sai.notify
	env.sai.notify = function(...)
		notified = notified + 1
		return old_notify(...)
	end

	local function tag(t, claim)
		return function(_, key, fb)
			seen[#seen + 1] = t .. ':' .. key
			if key == claim then return end
			return fb(key)
		end
	end
	local function fire(key) raw_binds['viewer:unassigned'](key) end

	local a = remapper.new { _path = 'sai.mode.a' }
	a.on_unassigned = tag 'a'
	local b = remapper.new { _path = 'sai.mode.b' }
	b.on_unassigned = tag('b', 'x')

	local ran, err = pcall(function()
		b.enabled = true
		a.enabled = true -- enabled last: on top

		fire 'x'
		h.eq('top declines, the claimer below runs', 'a:x,b:x', table.concat(seen, ','))

		seen = {}
		fire 'y'
		h.eq('decline runs the live stack below', 'a:y,b:y', table.concat(seen, ','))
		h.eq('the base fallback ends the chain', 1, notified)

		-- out-of-order disable: the middle record pops, the install
		-- above resolves below live
		b.enabled = false
		seen = {}
		notified = 0
		fire 'y'
		h.eq('disabled middle never runs', 'a:y', table.concat(seen, ','))
		h.eq('the base still ends the chain', 1, notified)

		-- re-enable chains onto the current top
		b.enabled = true
		seen = {}
		fire 'y'
		h.eq('re-enabled layer runs first again', 'b:y,a:y', table.concat(seen, ','))

		a.enabled = false
		b.enabled = false
		seen = {}
		notified = 0
		fire 'z'
		h.eq('no layers: nobody ran', '', table.concat(seen, ','))
		h.eq('the base runs alone', 1, notified)
	end)
	env.sai.notify = old_notify
	if not ran then error(err, 0) end
end)

-- A persist layer flipping app modes pops its viewer record and pushes a
-- gallery one: the old mode stops routing to it, the new one starts
T.unassigned_persist_flip = with_env(function(h)
	local seen, notified = {}, 0
	local old_notify = env.sai.notify
	env.sai.notify = function(...)
		notified = notified + 1
		return old_notify(...)
	end

	local p = remapper.new { _path = 'sai.mode.p', persist_mode_change = true }
	p.on_unassigned = function(_, key, fb)
		seen[#seen + 1] = 'p:' .. key
		return fb(key)
	end

	local ran, err = pcall(function()
		p.enabled = true
		sai.mode = 'gallery' -- Pre pops the viewer record, Changed pushes a gallery one
		raw_binds['gallery:unassigned'] 'y'
		h.eq('the new mode routes to the layer', 'p:y', table.concat(seen, ','))
		h.eq('the new mode base ends the chain', 1, notified)

		seen = {}
		notified = 0
		raw_binds['viewer:unassigned'] 'y'
		h.eq('the old mode no longer routes to the layer', '', table.concat(seen, ','))
		h.eq('the old mode base runs', 1, notified)

		sai.mode = 'viewer'
		p.enabled = false
	end)
	env.sai.notify = old_notify
	if not ran then error(err, 0) end
end)

-- Base fallback with no layers: digits toggle Shift, AltGr stays silent
T.unassigned_base_fallback = with_env(function(h)
	local notified = 0
	local old_notify = env.sai.notify
	env.sai.notify = function(...)
		notified = notified + 1
		return old_notify(...)
	end

	local fired = false
	sai.viewer.map('Shift+1', function() fired = true end, 'custom one')
	local ran, err = pcall(function()
		raw_binds['viewer:unassigned'] '1'
		h.ok('unmapped digit fell back to its Shift variant', fired)
		raw_binds['viewer:unassigned'] 'ISO_Level3_Shift'
		h.eq('AltGr shows no notice', 0, notified)
	end)
	sai.viewer:_setmap('Shift+1', nil)
	env.sai.notify = old_notify
	if not ran then error(err, 0) end
end)

-- Setting overrides: field writes on the mode's own sai tree, applied
-- while enabled, restored on disable
T.var_override_and_restore = with_env(function(h)
	sai.text.size = 12

	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.sai.text.size = 42

	mode.enabled = true
	h.eq('setting applies while enabled', 42, sai.text.size)

	mode.enabled = false
	h.eq('setting restores on disable', 12, sai.text.size)
end)

-- Full help over a custom mode: the mode's own display re-arms the layer
-- once the overlay leaves, disabling the mode reverts it with the display.
T.auto_display_heal = with_env(function(h)
	sai.text.enabled = false -- the text overlay is off in the user config

	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.map('Escape', function() end, 'custom exit')
	mode.sai.text.status = 'custom status'

	mode.enabled = true
	h.eq('layer up with the mode', true, sai.text.enabled)

	key_help.enabled = true -- F1: the full mode over the display
	h.ok('overlay on with the mode', key_help._enabled)
	key_help.enabled = false
	h.ok('the mode display still up', mode.help_pager._enabled)
	h.ok('layer healed', sai.text.enabled == true)
	h.contains('the display names the mode', mode.help_pager.title, 'Custom')

	mode.enabled = false
	h.ok('display off with the mode', not mode.help_pager._enabled)
	h.eq('layer reverted with the mode', false, sai.text.enabled)
end)

-- Full help over a block takeover: the overlay holds the layer while the
-- mode below disables, the display hands it back when the mode returns.
T.auto_display_block_heal = with_env(function(h)
	sai.text.enabled = false -- the text overlay is off in the user config
	local mode_text = sai.viewer.text
	sai.text.topleft = {} -- the user's topleft is empty: ours is all there is
	h.ok('user blocks stay in place', #mode_text.bottomleft > 0) -- the default viewer scheme

	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.sai.text.topleft = { 'our block' }

	mode.enabled = true
	h.eq('layer up with the block write', true, sai.text.enabled)
	h.eq('written block shows', 'our block', mode_text.topleft[1])
	h.ok('other locations blanked by the takeover', #mode_text.bottomleft == 0)

	key_help.enabled = true -- F1: the full mode over the display
	key_help.enabled = false
	h.ok('mode display returns after the overlay', mode.help_pager._enabled)
	h.eq('layer healed', true, sai.text.enabled)
	h.eq('written block survives the overlay', 'our block', mode_text.topleft[1])

	key_help.enabled = true -- the overlay: holds the layer up
	mode.enabled = false -- our disable: the block cleaned, the base held
	h.eq('empty base restored', 0, #mode_text.topleft)
	h.eq('layer kept by the overlay', true, sai.text.enabled)

	-- the display inherited our takeover of the layer (the restore target
	-- hands up in the registry): the blanked base comes back with it
	key_help.enabled = false
	h.eq('layer off with the overlay', false, sai.text.enabled)
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
	h.eq('layer block shows', 'persist block', mode_text.topleft[1])
	h.ok('other viewer block emptied', not next(mode_text.bottomright))

	sai.mode = 'gallery' -- fires ModeChangedPre, then ModeChanged

	h.eq('stale block restores into the old mode', 'viewer stale', mode_text.topleft[1])
	h.eq('layer still on', true, sai.text.enabled)
	h.eq('layer block re-shows in the new mode', 'persist block', gallery_text.topleft[1])
	h.ok('other block re-blanks in the new mode', not next(gallery_text.bottomright))

	mode.enabled = false
	h.eq('new mode block restored', 'gallery stale', gallery_text.bottomright[1])
	h.eq('layer block releases to the stale', 'viewer stale', mode_text.topleft[1])

	sai.mode = 'viewer' -- restore the app mode: the later tests bind onto it
end)

-- The pager is a full mode: user binds go live while the window shows and
-- leave with it; only the wheel maps by default, so a plain pager stays
-- inert until its host maps it
T.pager_is_a_mode = with_env(function(h)
	local host = remapper.new { _path = 'sai.mode.host' }
	host.enabled = true

	local p = require('sai.lib.pager').new {
		_path = 'sai.mode.host.pager',
		sai = host.sai,
		_location = 'bottomleft',
	}
	local function layer(m)
		for i = 2, #sai.modes do
			if sai.modes[i] == m then return true end
		end
	end

	local default_n = 0
	for _ in pairs(p._mappings) do
		default_n = default_n + 1
	end
	h.ok('only the wheel maps by default', default_n == 2 and p._mappings['ScrollUp'] ~= nil)
	h.ok('not a bind layer while hidden', raw_binds['viewer:F14'] == nil)

	local fired = 0
	p.map('F14', function() fired = fired + 1 end, 'page somewhere')
	p.enabled = true
	h.ok('joins sai.modes while shown', layer(p))
	raw_binds['viewer:F14']()
	h.eq('the bind is live while shown', 1, fired)

	p.enabled = false
	h.ok('leaves sai.modes when hidden', not layer(p))
	-- the unmap restores the app's unassigned fallback, so check the mapping
	h.ok('mapping gone from the api', sai.viewer._mappings['F14'] == nil)
end)

-- The pager's wheel follows its block: the bind is pushed with the section
-- prefix of the location and re-qualified when the block moves there. The
-- host maps a plain wheel so the fall-through does not reach the swipe.
-- Stub 800x600, linepx 42, padding 10.
T.pager_block_scrolls = with_env(function(h)
	local host = remapper.new { _path = 'sai.mode.host' }
	host.enabled = true
	host.map('ScrollDown', function() end, 'plain scroll')
	local p = require('sai.lib.pager').new {
		_path = 'sai.mode.host.pager',
		sai = host.sai,
		_location = 'status',
		_max_height = 8,
		title = '', -- the derived header would shift the block rows
	}
	p.enabled = true
	local lines = {}
	for i = 1, 20 do
		lines[i] = 'status line ' .. i
	end
	p.lines = lines

	at(400, 600 - 10 - 21) -- the status box, bottom row
	raw_binds['viewer:ScrollDown']()
	h.eq('the status wheel scrolled the window', 2, p._scroll)

	at(700, 100) -- off the block: the pager must not move
	raw_binds['viewer:ScrollDown']()
	h.eq('off the block: the pager stays', 2, p._scroll)

	-- the block moves: the bind follows it to the new corner
	p:set_location 'bottomleft'
	at(100, 600 - 10 - 21) -- over the bottom-left block
	raw_binds['viewer:ScrollDown']()
	h.eq('the wheel followed the block', 3, p._scroll)

	at(400, 600 - 10 - 21) -- the old status spot is dead
	raw_binds['viewer:ScrollDown']()
	h.eq('the old location stays inert', 3, p._scroll)

	p.enabled = false
end)

-- The selector's click owns its item: a double-click confirms the row the
-- pointer is over. Single clicks wait out the multiclick window, so only
-- the double is observable without the defer pump.
-- Stub 800x600, linepx 42, padding 10.
T.selector_click_confirms = with_env(function(h)
	local s = require('sai.mode.selector').new { _path = 'sai.mode.selector', _location = 'topleft', title = 'Pick' }
	local confirmed = false
	s.on_confirm = function()
		confirmed = true
		return false
	end
	s.enabled = true
	s.lines = { 'apple', 'banana', 'cherry' }

	at(100, 10 + 2 * 42 + 21) -- over 'banana' (row 2)
	env.raw_binds['viewer:MouseLeft']()
	h.eq('the first click waits', false, confirmed)
	env.raw_binds['viewer:MouseLeft']()
	h.eq('the double-click confirms', true, confirmed)
	h.eq('the clicked row became the cursor', 2, s._line)

	s.enabled = false
end)

H.maybe_standalone(T)

return T
