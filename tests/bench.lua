---Benchmarks of the keybind resolution: the time from an input's delivery
---to the mapped action's entry, over a recording stack. Blackbox by
---design: the binds map through the public mode api and the inputs arrive
---the way swayimg delivers them - its own key resolution first, the
---unassigned call for keys only, the registered handler for mouse and
---wheel - so the bind implementation behind them can be swapped without
---touching this file. The timings always print (module load output is not
---buffered): these are not tests, nothing asserts the numbers.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/' or ''
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
dir = dir:gsub('/%./', '/'):gsub('/%.?$', '')
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack {}
local sai, with_env = env.sai, env.with_env
local remapper = require 'sai.lib.remapper'
local at = H.mouse_stub(env.swayimg)
local raw_binds = env.raw_binds

-- the stopwatch: armed at an input's delivery, stopped by the mapped
-- action on entry
local t0, total, hits
local function action()
	total = total + (os.clock() - t0)
	hits = hits + 1
end

---A keypress the way swayimg runs one: its own resolution over the
---registered handlers, the unassigned call only when none took it.
local function press(key)
	t0 = os.clock()
	local fn = raw_binds['viewer:' .. key]
	if fn then
		fn()
	else
		raw_binds['viewer:unassigned'](key)
	end
end

---A mouse or wheel event: only the registered handler, swayimg knows no
---unassigned call for these.
local function click(btn)
	t0 = os.clock()
	raw_binds['viewer:' .. btn]()
end

local function wheel(kmods, h, v)
	t0 = os.clock()
	raw_binds['viewer:scroll'](kmods, h, v)
end

---Warm up, then time `n` rounds; prints ns from delivery to action entry.
local function bench(name, n, deliver)
	total, hits = 0, 0
	for _ = 1, n do
		deliver()
	end -- warmup: the jit and the caches settle
	total, hits = 0, 0
	for _ = 1, n do
		deliver()
	end
	if hits == 0 then return print(('BENCH %-20s the action never ran'):format(name)) end
	print(('BENCH %-20s %4.2f ms'):format(name, total / hits * 1e3))
end

with_env(function()
	local mode = remapper.new { _path = 'sai.bench' }
	mode.enabled = true

	-- inputs per measured loop: enough to smooth the clock, quick to run
	local n = 10000

	mode.map('j', action, 'bench key')
	bench('key', n, function() press 'j' end)
	mode.map('Ctrl+j', action, 'bench key combo')
	bench('key combo', n, function() press 'Ctrl+j' end)
	mode.map('Ctrl+Shift+j', action, 'bench two-mod key combo')
	bench('two-mod key combo', n, function() press 'Ctrl+Shift+j' end)

	mode.map('MouseLeft', action, 'bench click')
	bench('click', n, function() click 'MouseLeft' end)
	mode.map('2+MouseLeft', action, 'bench double click')
	bench('double click', n, function()
		click 'MouseLeft'
		click 'MouseLeft'
		-- the first press arms a burst wait: pump it here (after the
		-- action stopped the clock) so the shared heap never piles up
		env.flush_defers()
	end)

	sai.viewer.text.topleft = { 'head', 'row one', 'row two' }
	at(100, 10 + 42 + 21) -- over the first content row
	mode.map('TL+MouseLeft', action, 'bench section click')
	bench('section click', n, function() click 'MouseLeft' end)

	mode.map('ScrollDown', action, 'bench wheel')
	bench('wheel', n, function() wheel('', 0, 1) end)

	mode.enabled = false
	env.flush_defers() -- drain the burst waits: the shared heap must end empty
end)()

local T = {}

H.maybe_standalone(T)

return T
