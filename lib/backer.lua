---@module 'swi.lib.backer'

local e = require 'swi.api.eventloop'

---Field backer
--- Define set_xxx(self,val,idx) to use a custom setter for var named (idx=) `xxx`
--- Define get_xxx(self,idx) to use a custom getter for var named (idx=) `xxx`
---@class swi.lib.backer
---@field protected _path string object path to this new api (swi.xxx) or just a name for errors
---@field protected _trigger boolean? trigger events on setting a field (default: true)

local M = {}

function M.__index(self, idx)
	local v = rawget(self, 'get_' .. idx)
	if v then return v(self, idx) end

	v = rawget(self, '_' .. idx)
	if v ~= nil then return v end -- read local copy of the last set value

	error('tried to get: ' .. self._path .. '.' .. idx)
end

local trig = e.trigger
local function spoof_trigger(ev)
	if ev.event ~= 'OptionSet' then return trig(ev) end
end

function M.__newindex(self, idx, val)
	local old = rawget(self, '_' .. idx)

	local ot = e.trigger
	e.trigger = spoof_trigger
	local res = rawget(self, 'set_' .. idx)(self, val, idx)
	e.trigger = ot

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
---@generic O: swi.lib.backer
---@return O self
function M:new()
	---@diagnostic disable-next-line: inject-field
	if self._trigger == nil then self._trigger = true end
	return setmetatable(self, M)
end

return M
