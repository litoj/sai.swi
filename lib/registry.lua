---@module 'sai.lib.registry'

---Single override of a field or a bind.
---@class sai.lib.registry.record<O>
---@field layer? table the record's owner, set when the record takes its stack over
---@field new O
---@field old O? value captured when the override took the field over; nil while the record is only parked (its layer cannot apply it yet)

---@class sai.lib.registry.override_reg
---@field [string] sai.lib.registry.stack

---@class sai.lib.registry.api_reg
---@field [table] sai.lib.registry.override_reg modified api

---@class sai.lib.registry
---@field vars sai.lib.registry.api_reg
---@field binds sai.lib.registry.api_reg
local M = {}

---@class sai.lib.registry.stack<O>
---@field [integer] sai.lib.registry.record<O> the applied records, last is the top
---@field [table] sai.lib.registry.record<O> simplified lookup of override by layer
local stack_meta = {
	-- parked records die with their layer; the applied ones are removed by the layer's own disable
	---@private
	__mode = 'k',
	---@private
	__index = function(self, key)
		for i = 1, #self do
			if self[i].layer == key then return self[i] end
		end
	end,
	__newindex = function() error 'Stack may be written to only via stack.set()' end,
}

---Push a record, move an existing one to the top, or delete with `record=nil`.
---@generic O
---@param self sai.lib.registry.stack<O>
---@param layer table
---@param record? sai.lib.registry.record<O>
---@return O? restore value when the removed record was on top, nil to keep the newer value
function stack_meta:set(layer, record)
	local i
	for j = 1, #self do
		if self[j].layer == layer then
			i = j
			break
		end
	end
	local old = i and self[i].old
	local top = i == #self

	if i then
		if not top then self[i + 1].old = old end
		table.remove(self, i)
	end

	if record then
		record.layer = layer
		if top then record.old = old end
		rawset(self, #self + 1, record)
	elseif top then
		return old
	end
end

---@return sai.lib.registry.api_reg
function M.new()
	return setmetatable({}, {
		__mode = 'k',
		__index = function(apireg, api)
			local oreg = setmetatable({}, {
				__mode = 'k',
				__index = function(self, key)
					local stack = setmetatable({ set = stack_meta.set }, stack_meta)
					rawset(self, key, stack)
					return stack
				end,
			})
			apireg[api] = oreg
			return oreg
		end,
	})
end

M.vars = M.new()
M.binds = M.new()

return M
