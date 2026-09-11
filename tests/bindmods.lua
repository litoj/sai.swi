---Tests for the bind modifier machinery: parse, dispatch, bursts, retirement.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local sai = env.sai
local raw_binds, with_env = env.raw_binds, env.with_env
local remapper = require 'sai.lib.remapper'
local B = require 'sai.lib.bindmods'

-- one shared closure: the api proxy caches the pointer getter on first read
local at = H.mouse_stub(env.swayimg)

local T = {}

-- The canonical form: tokens parse off the front, count before section,
-- the event part normalized through userbind_to_xkb.
T.canonical_forms = function(h)
	h.eq('plain key stays', 'a', B.canonical 'a')
	h.eq('section token stays', 'TL+a', B.canonical 'TL+a')
	h.eq('count token stays', '2+MouseLeft', B.canonical '2+MouseLeft')
	h.eq('dash count normalizes', '2+MouseLeft', B.canonical '2-MouseLeft')
	h.eq('count renders before section', '2+TL+MouseLeft', B.canonical 'TL+2+MouseLeft')
	h.eq('canonical is idempotent', '2+TL+MouseLeft', B.canonical '2+TL+MouseLeft')
	h.eq('brackets strip', 'TL+a', B.canonical '<TL+a>')
	h.eq('status section stays', 'ST+ScrollDown', B.canonical 'ST+ScrollDown')
	h.eq('event modifiers stay', 'Ctrl+ScrollUp', B.canonical 'Ctrl+ScrollUp')
	h.eq('section over event modifiers', 'TL+Ctrl+ScrollUp', B.canonical 'TL+Ctrl+ScrollUp')
end

T.split_tokens = function(h)
	local toks, ev, count = B.split '2+TL+MouseLeft'
	h.eq('the event without tokens', 'MouseLeft', ev)
	h.eq('the count token', 2, count)
	h.eq('the section token', 'TL', toks.section)

	toks, ev, count = B.split 'a'
	h.eq('the plain event', 'a', ev)
	h.eq('no count on a plain bind', nil, count)
	h.eq('no tokens on a plain bind', nil, next(toks))
end

-- A trailing separator is a typo, not a crash: no token matches, the
-- bind stays on the (dead) event the string spells out.
T.parse_edges = function(h)
	h.eq('a lone section prefix is no token', 'TL+', B.canonical 'TL+')
	h.eq('a lone status prefix is no token', 'ST+', B.canonical 'ST+')
	h.eq('a lone count prefix is no token', '2+', B.canonical '2+')

	local toks, ev, count = B.split '10+Ctrl+x'
	h.eq('multi-digit counts parse', 10, count)
	h.eq('the event under a multi-digit count', 'Ctrl+x', ev)
	h.eq('no section token on a plain bind', nil, toks.section)
	h.eq('dash-separated counts on keys', 3, select(3, B.split '3-x'))
end

-- The burst dimension is a single slot: a second burst modifier is a
-- programming error, caught at registration.
T.burst_slot_is_single = function(h)
	local ok = pcall(B.register, 'another', {
		order = 15,
		burst = true,
		parse = function() end,
		render = function(tok) return tok end,
	})
	h.ok('a second burst modifier is rejected', not ok)
end

-- Section binds on a keyboard key: the pointer decides, the callback
-- receives the row, a miss falls through to the plain bind.
-- Stub 800x600, linepx 42, padding 10.
T.keyboard_section_binds = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local got, plain = {}, 0
	mode.map('TL+F13', function(row, loc) got = { row, loc } end, 'top-left key')
	mode.map('F13', function() plain = plain + 1 end, 'plain key')
	mode.enabled = true

	-- seeded after the enable: the corner arming blanks stale content
	sai.viewer.text.topleft = { 'the header row', 'the first row', 'the second row' }

	at(100, 10 + 42 + 21) -- the first content row
	raw_binds['viewer:F13']()
	h.eq('the qualified key fired with the row', '1\ntopleft', table.concat(got, '\n'))
	h.eq('the plain key did not fire', 0, plain)

	-- off the block: the plain key runs
	at(700, 100)
	raw_binds['viewer:F13']()
	h.eq('off the block: the plain key ran', 1, plain)

	-- no pointer: the position-independent bind still fires
	at()
	raw_binds['viewer:F13']()
	h.eq('no pointer: the plain key ran', 2, plain)

	mode.enabled = false
end)

-- A section bind without a plain sibling: a miss behaves as unmapped,
-- the unassigned chain answers.
T.keyboard_section_decline = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired = false
	mode.map('TL+F13', function(_, _) fired = true end, 'top-left key')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row' }

	local ran, err = pcall(function()
		local recs = H.capture_notify(env.sai, function()
			at(700, 100)
			raw_binds['viewer:F13']()
		end)
		h.ok('the qualified bind did not fire', not fired)
		h.contains('the miss reached the unassigned fallback', recs[1].trace, 'api/mode_base.lua')
	end)
	mode.enabled = false
	if not ran then error(err, 0) end
end)

-- The dispatcher outlives the binds it serves: unmapping one form of a
-- key keeps the others working, unmapping the last one retires the key.
T.rebind_and_unmap_matrix = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired, plain = {}, 0
	local function tl(row, _) fired[#fired + 1] = 'tl' .. tostring(row) end
	mode.map('TL+F13', tl, 'top-left key')
	mode.map('F13', function() plain = plain + 1 end, 'plain key')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row' }

	local on_block = { x = 100, y = 10 + 42 + 21 }
	local off_block = { x = 700, y = 100 }

	local ran, err = pcall(function()
		-- both forms live
		at(on_block)
		raw_binds['viewer:F13']()
		at(off_block)
		raw_binds['viewer:F13']()
		h.eq('both forms fire', 'tl1', table.concat(fired, ','))
		h.eq('the plain key fired off the block', 1, plain)

		-- drop the qualified one: the plain serves everywhere
		mode.map 'TL+F13'
		h.eq('the unmap tombstone carries no action', nil, (sai.viewer._mappings['TL+F13'] or {}).cb)
		at(on_block)
		raw_binds['viewer:F13']()
		h.eq('the plain key took the block over', 2, plain)

		-- bring the qualified one back, drop the plain one
		mode.map('TL+F13', tl, 'top-left key')
		mode.map 'F13'
		at(on_block)
		raw_binds['viewer:F13']()
		h.eq('the qualified bind kept working', 'tl1,tl1', table.concat(fired, ','))

		-- no plain sibling: off the block runs the unassigned path
		local recs = H.capture_notify(env.sai, function()
			at(off_block)
			raw_binds['viewer:F13']()
		end)
		h.contains('off the block reaches the fallback', recs[1].trace, 'api/mode_base.lua')

		-- the last form goes: the key retires to the fallback
		mode.map 'TL+F13'
		recs = H.capture_notify(env.sai, function()
			at(on_block)
			raw_binds['viewer:F13']()
		end)
		h.contains('the retired key reaches the fallback', recs[1].trace, 'api/mode_base.lua')
	end)
	mode.enabled = false
	if not ran then error(err, 0) end
end)

-- A fully retired button installs the unhandled notice, the app side
-- gets a callback for every registered event either way.
T.mouse_retirement = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired = 0
	mode.map('MouseLeft', function() fired = fired + 1 end, 'plain click')
	mode.enabled = true

	raw_binds['viewer:MouseLeft']()
	h.eq('the click fired', 1, fired)

	-- an unmap stores a bindless cfg until the layer pops it: the
	-- dispatch must act on the removal either way
	mode.map 'MouseLeft'
	h.eq('the unmap tombstone carries no action', nil, (sai.viewer._mappings['MouseLeft'] or {}).cb)
	local recs = H.capture_notify(env.sai, function() raw_binds['viewer:MouseLeft']() end)
	h.contains('the retired button shows the unhandled notice', recs[1].trace, 'api/mode_base.lua')
end)

-- Burst counting over any event: a higher count registered holds the
-- burst open, the deferred fire plays only through the defer pump.
T.burst_counts = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local log = {}
	mode.map('1+MouseLeft', function() log[#log + 1] = 'single' end, 'single')
	mode.map('2+MouseLeft', function() log[#log + 1] = 'double' end, 'double')
	mode.enabled = true

	raw_binds['viewer:MouseLeft']()
	h.eq('the single waits for the double', '', table.concat(log, ','))
	env.flush_defers()
	h.eq('the deferred single fired', 'single', table.concat(log, ','))

	log = {}
	raw_binds['viewer:MouseLeft']()
	raw_binds['viewer:MouseLeft']()
	h.eq('the double fired immediately', 'double', table.concat(log, ','))
	env.flush_defers() -- the first click's wait: superseded, fires nothing
	h.eq('no second fire after the burst ended', 'double', table.concat(log, ','))

	mode.enabled = false
end)

-- A gap-only count waits out the window and fires nothing; the burst
-- only completes at the registered count.
T.burst_gap_only = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired = 0
	mode.map('3+MouseLeft', function() fired = fired + 1 end, 'triple')
	mode.enabled = true

	raw_binds['viewer:MouseLeft']()
	raw_binds['viewer:MouseLeft']()
	env.flush_defers()
	h.eq('below the registered count: nothing fires', 0, fired)

	raw_binds['viewer:MouseLeft']()
	raw_binds['viewer:MouseLeft']()
	raw_binds['viewer:MouseLeft']()
	h.eq('the third click of the burst fires', 1, fired)

	mode.enabled = false
end)

-- The burst machinery is event-agnostic: a double keypress fires the
-- count bind.
T.burst_on_keys = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired = 0
	mode.map('2+F14', function() fired = fired + 1 end, 'double press')
	mode.enabled = true

	raw_binds['viewer:F14']()
	h.eq('the first press waits', 0, fired)
	raw_binds['viewer:F14']()
	h.eq('the second press fires', 1, fired)

	mode.enabled = false
end)

-- Unmapping a key that never dispatched still claims the app slot: a
-- native default behind it falls to the unassigned path - the keypad
-- sweep in binds.default relies on this.
T.unmap_claims_native_key = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.map 'F13'
	mode.enabled = true

	local recs = H.capture_notify(env.sai, function() raw_binds['viewer:F13']() end)
	h.contains('the claimed key reaches the fallback', recs[1].trace, 'api/mode_base.lua')

	mode.enabled = false
end)

-- One burst per event: a completion on one qualified path cancels the
-- pending waits of the event's other paths, the same way a same-path
-- completion does. Stub 800x600, linepx 42, padding 10.
T.burst_cancels_across_paths = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local log = {}
	local function tl() log[#log + 1] = 'block' end
	mode.map('TL+MouseLeft', tl, 'single over the block')
	mode.map('2+TL+MouseLeft', tl, 'double over the block')
	mode.map('MouseLeft', function() log[#log + 1] = 'plain' end, 'plain click')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row' }

	env.flush_defers() -- drain defers left by earlier tests: a stale one could eat a burst

	-- the burst straddles the block edge: the plain completion ends it
	at(100, 10 + 42 + 21) -- over the block
	raw_binds['viewer:MouseLeft']()
	at(700, 100) -- off it
	raw_binds['viewer:MouseLeft']()
	h.eq('the plain single completed the burst', 'plain', table.concat(log, ','))
	env.flush_defers()
	h.eq('the block bind wait died with the burst', 'plain', table.concat(log, ','))

	-- the whole burst over the block: the double serves it
	at(100, 10 + 42 + 21)
	raw_binds['viewer:MouseLeft']()
	raw_binds['viewer:MouseLeft']()
	h.eq('a full block burst fires the double', 'plain,block', table.concat(log, ','))

	mode.enabled = false
end)

-- Unmapping the higher count mid-burst: the pending wait serves the
-- count that is still registered, later clicks fire immediately.
T.unmap_mid_burst = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local log = {}
	mode.map('MouseLeft', function() log[#log + 1] = 'single' end, 'single')
	mode.map('2+MouseLeft', function() log[#log + 1] = 'double' end, 'double')
	mode.enabled = true

	env.flush_defers() -- drain defers left by earlier tests: a stale one could eat a burst

	raw_binds['viewer:MouseLeft']() -- waits for the double
	mode.map '2+MouseLeft' -- the double is gone
	env.flush_defers()
	h.eq('the single fired after the removal', 'single', table.concat(log, ','))

	raw_binds['viewer:MouseLeft']()
	h.eq('later clicks fire immediately', 'single,single', table.concat(log, ','))

	mode.enabled = false
end)

-- A qualified burst: the row resolves per click, the fire carries the
-- position of the click that completed it. Stub 800x600, linepx 42, padding 10.
T.qualified_burst = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local got
	mode.map('2+TL+MouseLeft', function(row, loc) got = { row, loc } end, 'double over the block')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row', 'the second row' }

	at(100, 10 + 42 + 21) -- the first content row
	raw_binds['viewer:MouseLeft']()
	at(100, 10 + 2 * 42 + 21) -- moved a row down before the second click
	raw_binds['viewer:MouseLeft']()
	h.eq('the double fired with the completing row', '2\ntopleft', table.concat(got, '\n'))

	mode.enabled = false
end)

-- A layer's qualified bind restores fully: after the disable the base
-- behavior is back, nothing stale serves the key.
T.layer_disable_restores = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.map('TL+F13', function(_, _) end, 'top-left key')
	mode.enabled = true
	h.ok('the layer bind is live', sai.viewer._mappings['TL+F13'] ~= nil)

	mode.enabled = false
	h.eq('the layer bind is gone', nil, sai.viewer._mappings['TL+F13'])

	at(100, 100)
	local recs = H.capture_notify(env.sai, function() raw_binds['viewer:F13']() end)
	h.contains('the base fallback answers the retired key', recs[1].trace, 'api/mode_base.lua')
end)

-- The corner display lists modifier binds: just the keybinds, no
-- modifier legends - their tokens are README material.
T.help_lists_modifiers = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.map('TL+F13', function(_, _) end, 'top-left key')
	mode.map('2+MouseLeft', function() end, 'double click')
	mode.enabled = true

	local lines = {}
	for _, l in ipairs(require('sai.mode.key_help').mode_tab(mode).lines) do
		lines[#lines + 1] = tostring(l)
	end
	local text = table.concat(lines, '\n')
	h.contains('the section bind listed', text, 'TL+F13')
	h.contains('the count bind listed', text, '2+MouseLeft')
	h.eq('no section legend line', nil, text:match '%[section%]')
	h.eq('no count legend line', nil, text:match '%[count%]')

	mode.enabled = false
end)

H.maybe_standalone(T)

return T
