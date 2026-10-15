---@module 'sai.lib.formatter'

---Line cache over raw items: the paint stays in sync with every write.
---@class sai.lib.formatter<I>
---@field format? fun(idx:integer, val:I):string|I the paint hook, captured at construction (not kept on the instance)
---@field [integer] I the raw items, in this very table `1..N` (write through set())
---@field _rendered? {[integer]:string|I}
---@field splice? fun(self:sai.lib.formatter<I>, target:(string|I)[], from:integer, to:integer) append the rendered rows `from..to` onto `target`, painting dirty ones through the captured hook
local M = {}

---@generic I
---@param cfg? sai.lib.formatter<I>
---@return sai.lib.formatter<I>
function M.new(cfg)
	cfg = cfg or {}
	local format = cfg.format or error 'formatter: paint hook (format) required'
	cfg.format = nil
	-- the painted rows sit parallel to the items: a nil slot is dirty
	cfg._rendered = {}
	-- the hook rides a closure, not the instance: splice is the only
	-- consumer and nothing else can reach the paint
	cfg.splice = function(self, target, from, to)
		local rendered = self._rendered
		---@cast rendered any
		for i = from, to do
			local row = rendered[i]
			if row == nil then
				row = format(i, self[i])
				rendered[i] = row
			end
			target[#target + 1] = row
		end
	end
	return setmetatable(cfg, { __index = M })
end

---Replace all content, or edit one line (a value sets, an integer deletes the range `idx..value`).
---A set dirties only its own rows.
---@generic I
---@type fun(self: sai.lib.formatter<I>, lines: I[])|fun(self: sai.lib.formatter<I>, idx: integer, val: I|integer|nil)
function M:set(idx, val)
	if type(idx) == 'table' then
		for i = 1, #self do
			self[i] = nil
		end
		for i, v in ipairs(idx) do
			self[i] = v
		end
		self._rendered = {}
		return
	end

	if type(val) == 'number' then
		local len = #self
		if val < idx then error 'formatter: range end before its start' end
		if idx < 1 or val > len then error 'formatter: delete out of range' end

		local count = val - idx + 1
		for i = idx, len - count do -- the tail shifts, its paint in lockstep
			self[i] = self[i + count]
			self._rendered[i] = self._rendered[i + count]
		end
		for i = len - count + 1, len do
			self[i] = nil
			self._rendered[i] = nil
		end
		return
	end

	if val == nil then
		if idx < 1 or idx > #self then error 'formatter: delete out of range' end
		M.set(self, idx, idx)
		return
	end

	if idx < 1 or idx > #self + 1 then error 'formatter: index out of range' end
	self[idx] = val
	self._rendered[idx] = nil
end

---Mark rows dirty: a paint hook reading live state (the cursor, the
---selection) needs this when that state moved without a set().
function M:touch(...)
	for i = 1, select('#', ...) do
		self._rendered[(select(i, ...))] = nil
	end
end

return M
