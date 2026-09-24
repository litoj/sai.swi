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

-- A lone unqualified bind fires on a plain press: one callback per
-- press, no deferred wait, no condition - keys and buttons alike.
T.plain_bind_fires_without_condition = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired = 0
	mode.map('F19', function() fired = fired + 1 end, 'direct key')
	mode.map('MouseLeft', function() fired = fired + 1 end, 'direct click')
	mode.enabled = true

	raw_binds['viewer:F19']()
	h.eq('a plain key press fires immediately', 1, fired)
	raw_binds['viewer:MouseLeft']()
	h.eq('a plain click fires immediately', 2, fired)
	raw_binds['viewer:F19']()
	h.eq('every press fires once', 3, fired)

	mode.enabled = false
end)

-- The mapping is order-independent: a qualified bind mapped first, the
-- plain base second - and unmapping either form leaves the other live.
T.qualified_then_base_share_the_key = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local tl, plain = 0, 0
	mode.map('TL+F21', function(_, _) tl = tl + 1 end, 'top-left key')
	mode.map('F21', function() plain = plain + 1 end, 'plain key')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row' }

	at(100, 10 + 42 + 21) -- the first content row
	raw_binds['viewer:F21']()
	at(700, 100)
	raw_binds['viewer:F21']()
	h.eq('both forms serve', '1,1', table.concat({ tl, plain }, ','))

	-- the plain base goes: the qualified form alone keeps the block
	mode.map 'F21'
	at(100, 10 + 42 + 21)
	raw_binds['viewer:F21']()
	h.eq('the qualified form survives the base unmap', 2, tl)

	-- the base comes back, the qualified form goes: the base serves all
	mode.map('F21', function() plain = plain + 1 end, 'plain key')
	mode.map 'TL+F21'
	at(100, 10 + 42 + 21)
	raw_binds['viewer:F21']()
	at(700, 100)
	raw_binds['viewer:F21']()
	h.eq('the plain base serves everywhere', 3, plain)

	mode.enabled = false
end)

-- Scroll binds reach their callback through the single on_scroll
-- handler swayimg calls. The wheel drives that handler the way the app
-- delivers it.
T.scroll_through_on_scroll = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local log = {}
	mode.map('ScrollUp', function() log[#log + 1] = 'up' end, 'wheel up')
	-- the axis tier, not a direction: the viewer default maps the wheel
	-- zoom to Ctrl+ScrollVertical, which outranks direction binds
	mode.map('Ctrl+ScrollVertical', function(mv, _) log[#log + 1] = 'ctrl axis' end, 'ctrl wheel')
	mode.enabled = true

	-- a corner window owns TR+Scroll by default: keep the pointer neutral
	at(400, 300)
	H.wheel(raw_binds, '', 'ScrollUp')
	h.eq('a plain wheel fired its bind', 'up', table.concat(log, ','))
	H.wheel(raw_binds, 'Ctrl', 'ScrollDown')
	h.eq('a modifier combo fired', 'up,ctrl axis', table.concat(log, ','))
	H.wheel(raw_binds, 'Shift', 'ScrollUp')
	h.eq('an unmapped combo does nothing', 'up,ctrl axis', table.concat(log, ','))
	H.wheel(raw_binds, '', 'ScrollUp')
	h.eq('a lone scroll bind fires again', 'up,ctrl axis,up', table.concat(log, ','))

	mode.enabled = false
end)

-- Same order-dependence on the wheel: a block-qualified scroll bound
-- before its plain base; each form unmapped on its own.
T.scroll_qualified_then_base = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local block, plain = 0, 0
	mode.map('TL+ScrollDown', function() block = block + 1 end, 'block wheel')
	mode.map('ScrollDown', function() plain = plain + 1 end, 'plain wheel')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row' }

	at(100, 10 + 42 + 21) -- the first content row
	H.wheel(raw_binds, '', 'ScrollDown')
	at(400, 300) -- center, away from the corner windows
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('both wheel forms serve', '1,1', table.concat({ block, plain }, ','))

	-- the plain base goes: the block form alone keeps the wheel
	mode.map 'ScrollDown'
	at(100, 10 + 42 + 21)
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('the block form survives the base unmap', 2, block)

	-- the base comes back, the block form goes: the base serves all
	mode.map('ScrollDown', function() plain = plain + 1 end, 'plain wheel')
	mode.map 'TL+ScrollDown'
	at(100, 10 + 42 + 21)
	H.wheel(raw_binds, '', 'ScrollDown')
	at(400, 300)
	H.wheel(raw_binds, '', 'ScrollDown')
	h.eq('the plain wheel serves everywhere', 3, plain)

	mode.enabled = false
end)

-- A raw `Scroll` bind receives the unquantized deltas, once per frame;
-- every more specific form of the axis outranks it.
T.scroll_raw_generic_receives_deltas = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local got = {}
	mode.map('Scroll', function(mh, mv) got[#got + 1] = { mh, mv } end, 'pan by scroll')
	mode.enabled = true

	at(400, 300) -- neutral: the corner wheels stay out of it
	raw_binds['viewer:scroll']('', 3, -2)
	h.eq('the raw scroll got the deltas', '3,-2', table.concat(got[1], ','))
	h.eq('one raw event per frame', 1, #got)
	raw_binds['viewer:scroll']('', 0, 0.3)
	h.eq('a fractional frame reaches the raw scroll too', 2, #got)

	mode.enabled = false
end)

-- A plain direction bind consumes its axis in full accumulated steps
-- while no raw axis bind holds it. The fraction carries over; the step
-- fires once per whole unit.
T.scroll_direction_quantizes = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired = 0
	mode.map('ScrollDown', function() fired = fired + 1 end, 'scroll down')
	mode.enabled = true

	raw_binds['viewer:scroll']('', 0, 2.3)
	h.eq('two full steps from a 2.3 frame', 2, fired)
	raw_binds['viewer:scroll']('', 0, 0.4)
	raw_binds['viewer:scroll']('', 0, 0.7) -- the accumulated 0.4 + 0.7 crosses one
	h.eq('the carried fraction completed a step', 3, fired)

	mode.enabled = false
end)

-- The axes resolve separately: a plain direction bind on one axis does
-- not take the other axis away from the raw binds. The claimed axis
-- zeroes out, the rest of the frame falls through.
T.scroll_direction_leaves_the_other_axis = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local up, rawgot = 0, {}
	mode.map('ScrollUp', function() up = up + 1 end, 'wheel up')
	mode.map('Scroll', function(mh, mv) rawgot[#rawgot + 1] = { mh, mv } end, 'pan by scroll')
	mode.enabled = true

	at(400, 300)
	raw_binds['viewer:scroll']('', 2, 0) -- a purely horizontal frame
	h.eq('the horizontal frame reached the raw scroll', '2,0', table.concat(rawgot[1], ','))
	h.eq('the direction bind stayed out', 0, up)

	raw_binds['viewer:scroll']('', 2, -1) -- diagonal: the vertical axis is claimed
	h.eq('the claimed axis fired its direction', 1, up)
	h.eq('the raw scroll carried the unclaimed axis only', '2,0', table.concat(rawgot[2], ','))

	raw_binds['viewer:scroll']('', 0, 0.5) -- a fraction waits in the accumulator
	h.eq('no step from a fraction', 1, up)
	h.eq('the raw scroll got nothing', 2, #rawgot)

	mode.enabled = false
end)

-- ScrollVertical/ScrollHorizontal relay one axis raw, without
-- quantization: the magnitude rides along. They sit between the
-- direction steps and the fully generic `Scroll`.
T.scroll_axis_raw_receives_magnitude = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local got = {}
	-- two params: a one-param callback would read as a mode-self bind to
	-- the remapper and receive the mode instead of the magnitude
	mode.map('ScrollVertical', function(mv, _) got[#got + 1] = { 'v', mv } end, 'raw vertical')
	mode.map('ScrollHorizontal', function(mh, _) got[#got + 1] = { 'h', mh } end, 'raw horizontal')
	mode.enabled = true

	at(400, 300)
	raw_binds['viewer:scroll']('', 0, 1.5)
	h.eq('the vertical magnitude is raw', 'v,1.5', table.concat(got[1], ','))
	raw_binds['viewer:scroll']('', 0, -0.7)
	h.eq('the opposite direction rides too', 'v,-0.7', table.concat(got[2], ','))
	raw_binds['viewer:scroll']('', 2.5, 0)
	h.eq('the horizontal magnitude is raw', 'h,2.5', table.concat(got[3], ','))
	h.eq('the axis binds were not quantized', 3, #got)

	mode.enabled = false
end)

-- The resolution order on an axis: a raw axis bind, then the direction
-- steps, then the generic `Scroll` - removing a layer shifts the wheel
-- down the chain.
T.scroll_resolution_hierarchy = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local dirgot, axisgot, generic = 0, 0, 0
	mode.map('ScrollDown', function() dirgot = dirgot + 1 end, 'step down')
	mode.map('ScrollVertical', function() axisgot = axisgot + 1 end, 'raw vertical')
	mode.map('Scroll', function() generic = generic + 1 end, 'raw scroll')
	mode.enabled = true

	at(400, 300) -- neutral: the corner wheels stay out of it

	-- the raw axis outranks the direction steps
	raw_binds['viewer:scroll']('', 0, 1)
	h.eq('the raw axis answered', 1, axisgot)
	h.eq('the direction step stayed out', 0, dirgot)
	h.eq('the generic stayed out', 0, generic)

	-- the raw axis goes: the direction quantizes again
	mode.map 'ScrollVertical'
	raw_binds['viewer:scroll']('', 0, 1)
	h.eq('the direction step won', 1, dirgot)
	h.eq('the generic still held back', 0, generic)

	-- the direction goes: the generic takes the deltas
	mode.map 'ScrollDown'
	raw_binds['viewer:scroll']('', 0, 1)
	h.eq('the generic took the deltas', 1, generic)

	mode.enabled = false
end)

-- A section-qualified direction keeps its block even over a raw axis
-- bind: the axis owns the rest of the window; the corner owns itself.
T.scroll_section_beats_axis = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local blockgot, axisgot = 0, 0
	mode.map('TL+ScrollUp', function() blockgot = blockgot + 1 end, 'block wheel up')
	mode.map('ScrollVertical', function(mv, _) axisgot = axisgot + 1 end, 'raw vertical')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row' }

	at(100, 10 + 42 + 21) -- the first content row
	H.wheel(raw_binds, '', 'ScrollUp')
	h.eq('the block wheel won on its block', 1, blockgot)
	h.eq('the raw axis stayed out', 0, axisgot)

	at(400, 300)
	H.wheel(raw_binds, '', 'ScrollUp')
	h.eq('the block form survived', 1, blockgot)
	h.eq('the raw axis answered off the block', 1, axisgot)

	mode.enabled = false
end)

-- The section-qualified direction precedes the raw scroll: a block-owned
-- wheel wins under its block; the raw scroll answers off it.
T.scroll_section_precedes_generic = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local blockgot, rawgot = 0, {}
	mode.map('TL+ScrollUp', function() blockgot = blockgot + 1 end, 'block wheel up')
	mode.map('Scroll', function(mh, mv) rawgot[#rawgot + 1] = { mh, mv } end, 'pan by scroll')
	mode.enabled = true
	sai.viewer.text.topleft = { 'the header row', 'the first row' }

	at(100, 10 + 42 + 21) -- the first content row
	H.wheel(raw_binds, '', 'ScrollUp')
	h.eq('the block wheel won on its block', 1, blockgot)
	h.eq('the raw scroll stayed out', 0, #rawgot)

	at(400, 300)
	H.wheel(raw_binds, '', 'ScrollUp')
	h.eq('the block form survived', 1, blockgot)
	h.eq('the raw scroll answered off the block', 1, #rawgot)
	h.eq('the raw scroll carried the delta', -1, rawgot[1][2])

	mode.enabled = false
end)

-- A scroll combo no bind claims reaches the unassigned chain with the
-- raw `Scroll` key.
T.scroll_unassigned_chain = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	mode.enabled = true

	local recs = H.capture_notify(env.sai, function()
		at(400, 300)
		H.wheel(raw_binds, 'Shift', 'ScrollUp')
	end)
	h.ok('the unbound combo reached the fallback', recs[1] and (recs[1].msg:find('Shift+Scroll', 1, true) ~= nil))

	mode.enabled = false
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

-- The burst machinery is mouse-only for now: a count token on a key
-- warns and maps as a plain single press.
T.key_counts_warn_and_map_as_plain = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local fired = 0
	mode.map('2+F14', function() fired = fired + 1 end, 'double press')
	-- the warning rides sai.log, which routes through notify without a file
	local recs = H.capture_notify(env.sai, function() mode.enabled = true end)

	h.ok('the count-on-key warning fired', recs[1] and (recs[1].msg:find 'not supported' ~= nil))
	raw_binds['viewer:F14']()
	h.eq('a count on a key is a single press', 1, fired)

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

-- Unmapping the higher count mid-burst cancels the pending wait: the
-- burst may only complete while its bind is registered.
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
	h.eq('the pending wait died with the unmap', '', table.concat(log, ','))

	raw_binds['viewer:MouseLeft']()
	h.eq('later clicks fire immediately', 'single', table.concat(log, ','))

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
