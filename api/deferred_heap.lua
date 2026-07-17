---@module 'sai.api.deferred_heap'

--- Min-heap for keeping track of the next deferred cb to be excuted
---@private
---@class sai.api.deferred_heap
---@field private [integer] {time: integer, cb: function}
local M = {}

---Push a callback to be executed after ms milliseconds
---@param ms number milliseconds from now until execution
---@param cb function callback to execute
function M:push(ms, cb)
	local exec_time = os.time() * 1000 + ms -- estimate intended time of execution
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
	local now = os.time() * 1000
	local remaining = self[1].time - now
	return math.max(0, remaining)
end

return M
