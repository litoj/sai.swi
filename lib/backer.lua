---@module 'swi.lib.backer'

local e = require 'swi.api.eventloop'

---@class swi.lib.backer: proxy
---@field super? table unused element of proxy definition
local M = {}

function M.__index(self, idx)
	local v = rawget(self, 'get_' .. idx)
	if v then return v(self, idx) end

	v = rawget(self, '_' .. idx)
	if v ~= nil then return v end -- read local copy of the last set value

	error('tried to get: ' .. self._path .. '.' .. idx)
end

function M.__newindex(self, idx, val)
	local old = rawget(self, '_' .. idx)
	local res = rawget(self, 'set_' .. idx)(self, val, idx)
	if res == nil then -- set the field only if the setter allows it
		rawset(self, '_' .. idx, val)
	elseif res then -- trigger allowed but value has been updated
		val = self['_' .. idx]
	end

	if res ~= false and self._trigger then
		e.trigger { event = 'OptionSet', match = ('%s.%s'):format(self._path, idx), data = val, old_data = old }
	end
end

---Add field backing logic to the current object; no `super` lookups
---Inheritors are required to copy all functions from super to self themselves!
---@generic O: proxy
---@param base `O`
---@return O base
function M.new(base)
	---@diagnostic disable-next-line: inject-field
	if base._trigger == nil then base._trigger = true end
	return setmetatable(base, M)
end

return M
