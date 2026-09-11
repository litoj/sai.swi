---Benchmarks over the recording api stack: the timings print per method
---(VERBOSE=1 shows them live, a failure dumps them); the assertions only
---keep the scenarios honest, the numbers themselves are not under test.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/' or ''
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
dir = dir:gsub('/%./', '/'):gsub('/%.?$', '')
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack {}
local sai, with_env = env.sai, env.with_env
local remapper = require 'sai.lib.remapper'
local mouse_box = require 'sai.bridge.mouse_box'
local at = H.mouse_stub(env.swayimg)

---Warm up, then time `n` rounds; prints ns per round.
local function timed(name, n, fire)
	for _ = 1, n do
		fire()
	end -- warmup: the jit and the caches settle
	local t = os.clock()
	for _ = 1, n do
		fire()
	end
	print(('BENCH %-28s %8.0f ns/op'):format(name, (os.clock() - t) / n * 1e9))
end

local T = {}

-- presses per measured loop: enough to smooth the clock, quick to run
local N = 10000

-- the plain keypress: the universal handler runs the bind, no pointer
T.key_press = with_env(function(h)
	local mode = remapper.new { _path = 'sai.bench.keys' }
	local hits = 0
	mode.map('j', function() hits = hits + 1 end, 'bench key')
	mode.enabled = true

	timed('key press', N, function() env.raw_binds['viewer:unassigned'] 'j' end)
	h.eq('the bind fired every press', 2 * N, hits)

	mode.enabled = false
end)

-- the mouse press: every press probes the block geometry before any bind
-- claims it - over rendered text, over a blanked layer, over nothing
T.mouse_press = with_env(function(h)
	local mode = remapper.new { _path = 'sai.bench.mouse' }
	local hits = 0
	mode.map('TL+MouseLeft', function() hits = hits + 1 end, 'bench corner')
	mode.map('MouseLeft', function() hits = hits + 1 end, 'bench plain')
	mode.enabled = true

	sai.viewer.text.topleft = { 'head', 'row one', 'row two' }
	at(100, 10 + 42 + 21) -- over the first content row
	timed('mouse press, text on', N, function() env.raw_binds['viewer:MouseLeft']() end)
	h.eq('the qualified bind fired every press', 2 * N, hits)

	-- the layer went down, the corner text stays configured: exactly one
	-- bind must still fire per press (which one differs by design)
	hits = 0
	sai.text.enabled = false
	timed('mouse press, layer off', N, function() env.raw_binds['viewer:MouseLeft']() end)
	h.eq('exactly one bind fired every press', 2 * N, hits)

	hits = 0
	sai.viewer.text.topleft = {}
	timed('mouse press, nothing to hit', N, function() env.raw_binds['viewer:MouseLeft']() end)
	h.eq('the plain bind fired every press', 2 * N, hits)

	sai.text.enabled = true
	mode.enabled = false
end)

-- the hit-test unit itself, outside the bind dispatch: the gate sits
-- between the caller and the geometry
T.block_probe = with_env(function(h)
	sai.viewer.text.topleft = { 'head', 'row one', 'row two' }
	at(100, 10 + 42 + 21) -- over the first content row

	h.eq('the probe finds the corner', 'TL', mouse_box.block_at { 'TL', 'TR', 'BL', 'BR', 'ST' })
	timed('block_at, text on', N, function() mouse_box.block_at { 'TL', 'TR', 'BL', 'BR', 'ST' } end)

	sai.text.enabled = false
	timed('block_at, layer off', N, function() mouse_box.block_at { 'TL', 'TR', 'BL', 'BR', 'ST' } end)

	sai.text.enabled = true
end)

-- the recalibration: every font or size write re-measures through the
-- real fontconfig/freetype probe; the probe's libraries load once
T.recalibration = with_env(function(h)
	mouse_box._stub_metrics = nil
	timed('font recalibration', 300, function() mouse_box.calibrate('monospace', 24) end)

	local wf = mouse_box.width_factor
	mouse_box._stub_metrics = function() end
	mouse_box.width_factor, mouse_box.hpad_factor = 1, 0
	if wf <= 0 or wf == 1 then return h.skip('font lookup unavailable', wf) end
	h.ok('a character cell measured', wf > 0 and wf < 1)
end)

H.maybe_standalone(T)

return T
