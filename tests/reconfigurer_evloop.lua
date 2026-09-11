---Tests for sai.lib.reconfigurer_evloop: the callable enable/disable, bulk
---subscribe, live subscribe while on, and the strict index.
---Runs over a recording api stack (hooks land in the real eventloop).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local e = require 'sai.api.eventloop'
local EV = require 'sai.lib.reconfigurer_evloop'

---@type event_name_t
---@diagnostic disable-next-line: assign-type-mismatch
local EVTEST = 'EvLoopTest'

local function hooked()
	local n = 0
	for _ in pairs(e.find_all { event = EVTEST }) do
		n = n + 1
	end
	return n
end

local T = {}

-- off by default: hooks collect only; on applies all; off drops all
T.enable_table_call_disable_cycle = with_env(function(h)
	local el = EV.new {}
	el.subscribe { event = EVTEST, callback = function() end }
	el.subscribe { event = EVTEST, callback = function() end }
	h.eq('nothing live while off', 0, hooked())

	el { { event = EVTEST, callback = function() end } }
	local n = 0
	for _ in pairs(el._new) do
		n = n + 1
	end
	h.eq('the bulk call queues a third hook', 3, n)
	h.eq('still nothing live before the enable', 0, hooked())

	el(true)
	h.eq('on applies all hooks', 3, hooked())
	h.eq('re-enabling is a no-op', false, el(true))

	el(false)
	h.eq('off drops every hook', 0, hooked())
end)

-- subscribe lands directly in the loop while enabled
T.subscribe_while_enabled = with_env(function(h)
	local el = EV.new {}
	el(true)
	el.subscribe { event = EVTEST, callback = function() end }
	h.eq('subscription goes live immediately', 1, hooked())
	el(false)
	h.eq('subscription drops with the disable', 0, hooked())
end)

-- reads off the metatable error with the value's path, loudly
T.strict_index_errors = with_env(function(h)
	local el = EV.new {}
	local ran, err = pcall(function() return el.something end)
	h.ok('missing hook index errors', not ran)
	h.contains('the error names the value type', tostring(err), 'reconfigurer.eventloop')
end)

-- the hooks listing maps one event=selector line per hook
T.tostring_lists_hooks = with_env(function(h)
	local el = EV.new {}
	el.subscribe { event = 'User', match = 'ModePush', callback = function() end }
	local s = tostring(el)
	h.contains('tostring lists one line per hook', s, 'hooks={ [1]="User=ModePush" }')
end)

H.maybe_standalone(T)

return T
