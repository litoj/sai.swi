---Tests for sai.bridge.deferred_heap: due-order scheduling of defer_fn.
---Development tool: not used during normal swayimg operation.
---
---Owns the scheduling half of the api defer story: heap order, earliest
---first, reentrant pushes. The notify half (what the restore does to the
---text) lives in tests/api.lua.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')

-- the defer stub queues fires like the app timers, pumped manually below
local defer_queue = {}
local swayimg = H.raw_swayimg()
swayimg.defer = function(_, cb) defer_queue[#defer_queue + 1] = cb end

local sai, sai_proxy = H.fresh_api_stack(swayimg)
local heap = require 'sai.bridge.deferred_heap'

_G.swayimg, _G.sai = old_swi, old_sai

---Fire the armed deferred fires until the queue and the heap settle: each
---fire pops the earliest entry, exactly like the app's timers would.
local function run_deferred()
	for _ = 1, 100 do
		local fire = table.remove(defer_queue, 1)
		if not fire then break end
		fire()
	end
end

local function with_env(fn)
	return function(h)
		_G.swayimg, _G.sai = swayimg, sai_proxy
		run_deferred() -- a leftover fire would silence or double this test's timers
		local ran, err = pcall(fn, h)
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

local T = {}

T.monotonic_ms_precision = function(h)
	-- whole-second clock truncation would record this due time up to 1s early
	heap:push(500, function() end)
	local remaining = heap:time_to_next()
	h.ok('due time keeps sub-second precision', remaining > 250 and remaining <= 500)
	heap:pop()
end

T.pushes_all_run_in_due_order = with_env(function(h)
	local order = {}
	sai.defer_fn(function() order[#order + 1] = 'a' end, 1)
	sai.defer_fn(function() order[#order + 1] = 'b' end, 2)
	sai.defer_fn(function() order[#order + 1] = 'c' end, 3)
	run_deferred()
	h.eq('every pushed callback ran once, earliest first', 'a,b,c', table.concat(order, ','))
	h.eq('no timers left pending', 0, #heap)
end)

-- An earlier callback must run before the later ones it was pushed after.
-- (distinct delays: equal dues would tie on the ms clock, leaving the
-- heap order between them to array positions instead of time)
T.earlier_push_runs_first = with_env(function(h)
	local order = {}
	sai.defer_fn(function() order[#order + 1] = 'late' end, 60000)
	sai.defer_fn(function() order[#order + 1] = 'early' end, 1)
	sai.defer_fn(function() order[#order + 1] = 'later' end, 30000)
	run_deferred()
	h.eq('earliest runs first', 'early,later,late', table.concat(order, ','))
	h.eq('no timers left pending', 0, #heap)
end)

-- A defer_fn called from inside a running fire must still run
T.reentrant_push_runs = with_env(function(h)
	local ran_inner = false
	sai.defer_fn(function()
		sai.defer_fn(function() ran_inner = true end, 1)
	end, 1)

	run_deferred()
	h.ok('the reentrant push ran', ran_inner)
	h.eq('no timers left pending', 0, #heap)
end)

-- every push re-arms swayimg's single defer slot: the armed fires of the
-- superseded slots must stay silent, only the newest may pop
T.stale_arm_stays_silent = with_env(function(h)
	local fired = {}
	heap:schedule(function() fired[#fired + 1] = 'late' end, 60000)
	heap:schedule(function() fired[#fired + 1] = 'early' end, 1)
	h.eq('two defer fires queued', 2, #defer_queue)

	defer_queue[1]() -- superseded arm: gen check drops it
	h.eq('the superseded fire ran no callback', 0, #fired)
	defer_queue[2]() -- the live arm: pops the earliest and re-arms for the rest
	h.eq('the live fire popped the earliest callback', 'early', table.concat(fired, ','))
	h.eq('a new fire queued for the remaining entry', 3, #defer_queue)
	defer_queue[3]()
	h.eq('remaining entry fires last', 'early,late', table.concat(fired, ','))
	h.eq('heap drained', 0, #heap)
end)

-- a throwing callback lands in the print, never in the chain: the entries
-- behind it still pop in due order
T.callback_error_is_isolated = with_env(function(h)
	local printed, ran_after = {}, false
	local old_print = _G.print
	---@diagnostic disable-next-line: duplicate-set-field
	_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, '\t') end
	local ran, err = pcall(function()
		heap:schedule(function() error 'boom' end, 1)
		heap:schedule(function() ran_after = true end, 2)
		run_deferred()
	end)
	_G.print = old_print
	if not ran then error(err, 0) end

	h.ok('thrown error was printed', printed[1] ~= nil and printed[1]:find('boom', 1, true) ~= nil)
	h.ok('the entry behind the error ran', ran_after)
	h.eq('heap drained', 0, #heap)
end)

-- schedule defaults the delay: no ms means the app's minimum step
T.schedule_defaults_the_delay = with_env(function(h)
	local ran_immediate = false
	heap:schedule(function() ran_immediate = true end)
	run_deferred()
	h.ok('default 1ms callback ran', ran_immediate)
end)

H.maybe_standalone(T)

return T
