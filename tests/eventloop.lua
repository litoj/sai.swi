---Tests for sai.api.eventloop hook matching over a recording stack (the
---module reads the mode and the log through the globals, like in the app).
---A callback returning truthy - or subscribed with once = true -
---deregisters itself after firing.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local ok, eq = H.ok, H.eq

local env = H.recording_stack()
local with_env = env.with_env
local e = require 'sai.api.eventloop'

-- private event names: the matching machinery is name-agnostic and these must
-- not collide with real subscribers of the documented events
---@diagnostic disable: assign-type-mismatch -- the event_name_t union cannot know these deliberate private names
---@type event_name_t, event_name_t, event_name_t, event_name_t, event_name_t
local E1, E2, E3, E4, ELeave = 'Shift1', 'Shift2', 'Shift3', 'Shift4', 'Leave'
---@diagnostic disable: assign-type-mismatch
---@type event_name_t, event_name_t, event_name_t, event_name_t, event_name_t
local E5, E6, E7, E8, E9 = 'Shift5', 'Shift6', 'Shift7', 'Shift8', 'Shift9'
---@diagnostic enable: assign-type-mismatch
---@diagnostic enable: assign-type-mismatch

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
T.self_deregister_shift = with_env(function()
	local fired = {}
	e.subscribe {
		event = E1,
		callback = function()
			fired[#fired + 1] = 'a'
			return true
		end,
	}
	e.subscribe {
		event = E1,
		callback = function()
			fired[#fired + 1] = 'b'
			return true
		end,
	}
	e.trigger { event = E1, match = 'x' }
	eq('both hooks fired in one trigger', 2, #fired)
	ok('first hook fired', fired[1] == 'a')
	ok('second hook fired despite index shift', fired[2] == 'b')
	eq('both deregistered', 0, count(E1))
end)

T.once_deregister_shift = with_env(function()
	local fired = {}
	e.subscribe { event = E2, once = true, callback = function() fired[#fired + 1] = 'a' end }
	e.subscribe { event = E2, callback = function() fired[#fired + 1] = 'b' end }
	e.trigger { event = E2, match = 'x' }
	eq('both hooks fired in one trigger', 2, #fired)
	e.trigger { event = E2, match = 'x' }
	eq('only the persistent hook refires', 3, #fired)
	ok('persistent hook fired again', fired[3] == 'b')
	e.unsubscribe { event = E2 }
end)

T.unsubscribe_other_during_trigger = with_env(function()
	local fired_b = false
	local b = e.subscribe { event = E3, callback = function() fired_b = true end }
	e.subscribe { event = E3, callback = function() e.unsubscribe { id = b } end }
	e.trigger { event = E3, match = 'x' }
	ok('unsubscribed hook still fired (snapshot)', fired_b)
	local found_b = false
	for h in pairs(e.find_all { event = E3, match = 'x' }) do
		if h == b then found_b = true end
	end
	ok('unsubscribed hook is gone after the trigger', not found_b)
	e.unsubscribe { event = E3 }
end)

T.exit_pattern = with_env(function()
	-- like SwiLeavePre cleanup hooks: N self-deregistering hooks must all
	-- run on a single trigger, leaving none behind
	for _ = 1, 5 do
		e.subscribe { event = ELeave, callback = function() return true end }
	end
	e.trigger { event = ELeave, match = '0' }
	eq('no hooks left after one trigger', 0, count(ELeave))
end)

T.match_filtering = with_env(function()
	local hits = 0
	e.subscribe { event = E4, match = 'go', callback = function() hits = hits + 1 end }
	e.trigger { event = E4, match = 'other' }
	eq('a non-matching trigger fires no hook', 0, hits)
	e.trigger { event = E4, match = 'go' }
	eq('a matching trigger fires the hook', 1, hits)
	e.trigger { event = E4, match = 'go' }
	eq('hook without once refires', 2, hits)

	local hits_once = 0
	e.subscribe { event = E4, match = 'go', once = true, callback = function() hits_once = hits_once + 1 end }
	e.trigger { event = E4, match = 'go' }
	e.trigger { event = E4, match = 'go' }
	eq('once fires exactly once', 1, hits_once)
	e.unsubscribe { event = E4 }
end)

-- the takeover retires the old hook while it runs, then restores it once
-- the takeover deregisters itself (truthy return)
T.takeover_subscribe_restores_old = with_env(function()
	local fired = {}
	e.subscribe {
		event = E5,
		match = 'x',
		callback = function() fired[#fired + 1] = 'old' end,
	}
	e.takeover_subscribe {
		event = E5,
		match = 'x',
		callback = function()
			fired[#fired + 1] = 'new'
			return true
		end,
	}
	e.trigger { event = E5, match = 'x' }
	eq('only the takeover fired', 'new', table.concat(fired, ','))
	e.trigger { event = E5, match = 'x' }
	eq('the old hook restored after the takeover', 'new,old', table.concat(fired, ','))
	e.unsubscribe { event = E5 }
end)

-- '!' negates a regex the hook would otherwise match: '^x' fires on
-- 'xray' but the '!xyz' pins 'xyz' out; '^g' is a regex, 'go' a literal
T.pattern_negation_and_regex = with_env(function()
	local fired = {}
	e.subscribe {
		event = E6,
		match = { '^x', '!xyz' },
		callback = function() fired[#fired + 1] = 'neg' end,
	}
	e.subscribe {
		event = E6,
		match = '^g',
		callback = function() fired[#fired + 1] = 'regex' end,
	}
	e.subscribe {
		event = E6,
		match = 'go',
		callback = function() fired[#fired + 1] = 'literal' end,
	}
	e.trigger { event = E6, match = 'xray' }
	eq('the ^x regex hook fires on xray', 'neg', table.concat(fired, ','))
	e.trigger { event = E6, match = 'xyz' }
	eq('the !xyz negation keeps the hook silent', 'neg', table.concat(fired, ','))
	e.trigger { event = E6, match = 'go' }
	eq('literal and regex both fire, literal first', 'neg,literal,regex', table.concat(fired, ','))
	e.trigger { event = E6, match = 'ago' }
	eq('neither regex ^g nor literal go fire off-position', 'neg,literal,regex', table.concat(fired, ','))
	e.unsubscribe { event = E6 }
end)

-- find_all filters by hook identity, group and mode without firing
T.filter_by_id_group_mode = with_env(function()
	local a = e.subscribe { event = E7, match = 'x', group = 'ga', callback = function() end }
	local b = e.subscribe { event = E7, match = 'x', group = 'gb', mode = 'gallery', callback = function() end }
	ok('id finds its hook', e.find_all({ id = a })[a] ~= nil)
	local ga = e.find_all { event = E7, match = 'x', group = 'ga' }
	ok('group ga holds its hook', ga[a] ~= nil)
	ok('group ga skips the gb hook', ga[b] == nil)
	local viewer = e.find_all { event = E7, match = 'x', mode = 'viewer' }
	ok('viewer sees the modeless hook', viewer[a] ~= nil)
	ok('viewer skips the gallery hook', viewer[b] == nil)
	local gallery = e.find_all { event = E7, match = 'x', mode = 'gallery' }
	ok('gallery sees both', gallery[a] ~= nil and gallery[b] ~= nil)
	e.unsubscribe { event = E7, group = 'gb' }
	local rest = e.find_all { event = E7, match = 'x' }
	ok('group unsubscribe dropped gb', rest[b] == nil)
	ok('group unsubscribe kept ga', rest[a] ~= nil)
	e.unsubscribe { event = E7 }
end)

-- subscribing without callback or event errors loudly, not silently dead
T.subscribe_validates_args = with_env(function()
	local ran, err = pcall(e.subscribe, { event = E8 })
	ok('missing callback errors', not ran)
	ok('error names the missing callback', tostring(err):find('missing callback', 1, true) ~= nil)
	ran, err = pcall(e.subscribe, { callback = function() end })
	ok('missing event errors', not ran)
	ok('error names the missing event', tostring(err):find('missing event', 1, true) ~= nil)
end)

-- a callback error is isolated: the trigger carries the rest on
T.callback_error_continues_trigger = with_env(function()
	local second = false
	e.subscribe {
		event = E9,
		match = 'x',
		callback = function() error 'boom' end,
	}
	e.subscribe {
		event = E9,
		match = 'x',
		once = true,
		callback = function() second = true end,
	}
	e.trigger { event = E9, match = 'x' }
	ok('the hook behind the error fired', second)
	e.unsubscribe { event = E9 }
end)

-- subscribing fires the Subscribed meta event for the new event
T.subscribed_meta_event = with_env(function()
	local seen
	e.subscribe {
		event = 'Subscribed',
		match = E8,
		once = true,
		callback = function(ev) seen = ev.data end,
	}
	local sub = e.subscribe { event = E8, match = 'x', callback = function() end }
	ok('the meta hook saw the subscription', seen == sub)
	e.unsubscribe { event = E8 }
end)

H.maybe_standalone(T)

return T
