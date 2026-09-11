---@module 'sai.bridge.deferred_heap'

local ffi = require 'ffi'

-- the monotonic clock, not os.time():
-- - os.time() has whole-second resolution: a due time recorded just before a
--   second boundary lands up to 1s early
-- - each earlier push re-arms the single swayimg.defer slot at itself, so the
--   chain would fire callbacks far too soon
-- ffi.cdef is process-global: a re-require (like the test runner dropping
-- the module cache) must not declare the struct a second time
if not pcall(ffi.typeof, 'struct sai_monotonic_ts') then
	ffi.cdef [[
	struct sai_monotonic_ts { long tv_sec; long tv_nsec; };
	int clock_gettime(int clk_id, struct sai_monotonic_ts *tp);
	]]
end
local CLOCK_MONOTONIC = 1
-- lls cannot resolve cdef'd struct fields on cdata: type the struct's fields
---@type {tv_sec: number, tv_nsec: number}
local ts = ffi.new 'struct sai_monotonic_ts'
local function now_ms()
	ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
	-- tonumber: int64 cdata does not auto-convert for math.floor
	return tonumber(ts.tv_sec) * 1000 + math.floor(tonumber(ts.tv_nsec) / 1e6)
end

---@private
---@class sai.api.deferred_heap
---@field private [integer] {time: integer, cb: function}
local M = {}

---@param ms number
---@param cb function
function M:push(ms, cb)
	local exec_time = now_ms() + ms
	local i = #self + 1
	self[i] = { time = exec_time, cb = cb }

	while i > 1 do
		local parent = math.floor(i / 2)
		if self[parent].time <= self[i].time then break end
		self[parent], self[i] = self[i], self[parent]
		i = parent
	end
end

---@return function? cb
function M:pop()
	if #self == 0 then return nil end

	local result = self[1].cb
	self[1] = self[#self]
	self[#self] = nil

	local i = 1
	while true do
		local left = i * 2
		local right = left + 1
		local smallest = i

		if left <= #self and self[left].time < self[smallest].time then smallest = left end
		if right <= #self and self[right].time < self[smallest].time then smallest = right end

		if smallest == i then break end
		self[i], self[smallest] = self[smallest], self[i]
		i = smallest
	end

	return result
end

---@return integer?
function M:time_to_next()
	if #self == 0 then return nil end
	local now = now_ms()
	local remaining = self[1].time - now
	return math.max(0, remaining)
end

-- the single swayimg defer slot is re-armed on every push: stale armed
-- fires must stay silent, so each arm stamps a generation and only the
-- newest one may pop
local gen = 0
function M:arm()
	gen = gen + 1
	local id = gen
	swayimg.defer(math.max(self:time_to_next(), 1) / 1000, function()
		if id ~= gen then return end
		-- a throwing callback must not take the chain down: isolate and carry on.
		-- (pop returns the callback: the old `pcall(heap:pop())` idiom pcalled it)
		local cb = self:pop()
		if not cb then return end
		local ran, err = pcall(cb)
		if not ran then print('sai deferred callback error: ' .. tostring(err)) end
		if #self > 0 then self:arm() end
	end)
end

---@param cb function
---@param ms number? default 1: the app's own minimum step
function M:schedule(cb, ms)
	self:push(ms or 1, cb)
	self:arm()
end

return M
