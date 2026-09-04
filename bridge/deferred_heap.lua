---@module 'sai.bridge.deferred_heap'

local ffi = require 'ffi'

-- os.time() has whole-second resolution: a due time recorded just before a
-- second boundary lands up to 1s early, so every re-arm of the single
-- swayimg.defer slot (each push re-aims at the earliest item) can fire
-- callbacks far too soon. The monotonic clock gives exact milliseconds.
-- ffi.cdef is process-global: a re-require (like the test runner dropping
-- the module cache) must not declare the struct a second time
if not pcall(ffi.typeof, 'struct sai_monotonic_ts') then
	ffi.cdef [[
	struct sai_monotonic_ts { long tv_sec; long tv_nsec; };
	int clock_gettime(int clk_id, struct sai_monotonic_ts *tp);
	]]
end
local CLOCK_MONOTONIC = 1
-- lls cannot resolve cdef'd struct fields on cdata
local ts = ffi.new 'struct sai_monotonic_ts'
---@cast ts any
local function now_ms()
	ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
	-- tonumber: int64 cdata does not auto-convert for math.floor
	return tonumber(ts.tv_sec) * 1000 + math.floor(tonumber(ts.tv_nsec) / 1e6)
end

--- Min-heap for keeping track of the next deferred cb to be excuted
---@private
---@class sai.api.deferred_heap
---@field private [integer] {time: integer, cb: function}
local M = {}

---Push a callback to be executed after ms milliseconds
---@param ms number milliseconds from now until execution
---@param cb function callback to execute
function M:push(ms, cb)
	local exec_time = now_ms() + ms -- estimate intended time of execution
	local i = #self + 1
	self[i] = { time = exec_time, cb = cb }

	-- bubble up to maintain heap property
	while i > 1 do
		local parent = math.floor(i / 2)
		if self[parent].time <= self[i].time then break end
		self[parent], self[i] = self[i], self[parent]
		i = parent
	end
end

---Pop and return the earliest callback (if any)
---@return function? cb
function M:pop()
	if #self == 0 then return nil end

	local result = self[1].cb
	self[1] = self[#self]
	self[#self] = nil

	-- bubble down to maintain heap property
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

---Get the time until the next callback should execute
---@return integer? ms_remaining until next execution, or nil if empty
function M:time_to_next()
	if #self == 0 then return nil end
	local now = now_ms()
	local remaining = self[1].time - now
	return math.max(0, remaining)
end

return M
