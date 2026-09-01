---Tests for sai.api.eventloop: hook matching and the trigger/unsubscribe
---interaction. Runs in plain luajit with a stubbed swayimg table.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local ok, eq = H.ok, H.eq

local e = require 'sai.api.eventloop'

-- the eventloop reads the current mode and logs callback errors through
-- these globals; stub them only for the duration of each method - other
-- test modules (ipc) run in the same process and must not see them
local function stubbed(fn)
	return function()
		local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')
		_G.swayimg = { mode = 'viewer' }
		_G.sai = { log = function() end }
		local ran, err = pcall(fn)
		_G.swayimg = old_swi
		_G.sai = old_sai
		if not ran then H.fail('scenario crashed', err) end
	end
end

local function count(event)
	local n = 0
	for _ in pairs(e.find_all { event = event, match = 'x' }) do
		n = n + 1
	end
	return n
end

local T = {}

-- the double-exit regression: a self-deregistering hook used to shift the
-- list under the iterating matcher, skipping every hook after it
T.self_deregister_shift = stubbed(function()
	local fired = {}
	e.subscribe {
		event = 'Shift1',
		callback = function()
			fired[#fired + 1] = 'a'
			return true
		end,
	}
	e.subscribe {
		event = 'Shift1',
		callback = function()
			fired[#fired + 1] = 'b'
			return true
		end,
	}
	e.trigger { event = 'Shift1', match = 'x' }
	eq('both hooks fired in one trigger', 2, #fired)
	ok('first hook fired', fired[1] == 'a')
	ok('second hook fired despite index shift', fired[2] == 'b')
	eq('both deregistered', 0, count 'Shift1')
end)

T.once_deregister_shift = stubbed(function()
	local fired = {}
	e.subscribe { event = 'Shift2', once = true, callback = function() fired[#fired + 1] = 'a' end }
	e.subscribe { event = 'Shift2', callback = function() fired[#fired + 1] = 'b' end }
	e.trigger { event = 'Shift2', match = 'x' }
	eq('both hooks fired in one trigger', 2, #fired)
	e.trigger { event = 'Shift2', match = 'x' }
	eq('only the persistent hook refires', 3, #fired)
	ok('persistent hook fired again', fired[3] == 'b')
	e.unsubscribe { event = 'Shift2' }
end)

T.unsubscribe_other_during_trigger = stubbed(function()
	local fired_b = false
	local b = e.subscribe { event = 'Shift3', callback = function() fired_b = true end }
	e.subscribe { event = 'Shift3', callback = function() e.unsubscribe { id = b } end }
	e.trigger { event = 'Shift3', match = 'x' }
	ok('unsubscribed hook still fired (snapshot)', fired_b)
	local found_b = false
	for h in pairs(e.find_all { event = 'Shift3', match = 'x' }) do
		if h == b then found_b = true end
	end
	ok('but is gone after the trigger', not found_b)
	e.unsubscribe { event = 'Shift3' }
end)

T.exit_pattern = stubbed(function()
	-- like SwiLeavePre cleanup hooks: N self-deregistering hooks must all
	-- run on a single trigger, leaving none behind
	for _ = 1, 5 do
		e.subscribe { event = 'Leave', callback = function() return true end }
	end
	e.trigger { event = 'Leave', match = '0' }
	eq('no hooks left after one trigger', 0, count 'Leave')
end)

T.match_filtering = stubbed(function()
	local hits = 0
	e.subscribe { event = 'Shift4', match = 'go', callback = function() hits = hits + 1 end }
	e.trigger { event = 'Shift4', match = 'other' }
	eq('no match, no fire', 0, hits)
	e.trigger { event = 'Shift4', match = 'go' }
	eq('match fires', 1, hits)
	e.trigger { event = 'Shift4', match = 'go' }
	eq('without once it refires', 2, hits)

	local hits_once = 0
	e.subscribe { event = 'Shift4', match = 'go', once = true, callback = function() hits_once = hits_once + 1 end }
	e.trigger { event = 'Shift4', match = 'go' }
	e.trigger { event = 'Shift4', match = 'go' }
	eq('once fires exactly once', 1, hits_once)
	e.unsubscribe { event = 'Shift4' }
end)

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
