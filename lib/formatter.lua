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
		local r = self._rendered
		---@cast r any
		for i = from, to do
			local row = r[i]
			if row == nil then
				row = format(i, self[i])
				r[i] = row
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
function M:set(a, b)
	if type(a) == 'table' then
		for i = 1, #self do
			self[i] = nil
		end
		for i, v in ipairs(a) do
			self[i] = v
		end
		self._rendered = {}
		return
	end

	if type(b) == 'number' then
		local len = #self
		if b < a then error 'formatter: range end before its start' end
		if a < 1 or b > len then error 'formatter: delete out of range' end

		local n = b - a + 1
		for i = a, len - n do -- the tail shifts, its paint in lockstep
			self[i] = self[i + n]
			self._rendered[i] = self._rendered[i + n]
		end
		for i = len - n + 1, len do
			self[i] = nil
			self._rendered[i] = nil
		end
		return
	end

	if b == nil then
		if a < 1 or a > #self then error 'formatter: delete out of range' end
		M.set(self, a, a)
		return
	end

	if a < 1 or a > #self + 1 then error 'formatter: index out of range' end
	self[a] = b
	self._rendered[a] = nil
end

---Mark rows dirty: a paint hook reading live state (the cursor, the
---selection) needs this when that state moved without a set().
function M:touch(...)
	for i = 1, select('#', ...) do
		self._rendered[(select(i, ...))] = nil
	end
end

return M
