---@module 'sai.lib.backer'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'

--- Define set_xxx(self,val,idx) to use a custom setter for var named (idx=) `xxx`
--- Define get_xxx(self,idx) to use a custom getter for var named (idx=) `xxx`
---@class sai.lib.backer
---@field _path? string object path to this new api (sai.xxx) or just a name for errors
---@field _trigger boolean? trigger events on setting a field (default: true)

local M = {}

function M.__index(self, idx)
	local v = rawget(self, 'get_' .. idx)
	if v then return v(self, idx) end

	v = rawget(self, '_' .. idx)
	if v ~= nil then return v end

	error('tried to get: ' .. self._path .. '.' .. idx)
end

function M.__newindex(self, idx, val)
	local old = rawget(self, '_' .. idx)

	local oio = e.ignore_opts
	e.ignore_opts = true
	local setter = rawget(self, 'set_' .. idx)
	if not setter then
		e.ignore_opts = oio
		error('tried to set: ' .. self._path .. '.' .. idx)
	end
	-- restore the flag even when the setter throws: a stuck flag
	-- would silence every later OptionSet event
	local ok, res = pcall(setter, self, val, idx)
	e.ignore_opts = oio
	if not ok then error(res, 0) end

	if res == nil then -- set the field only if the setter allows it
		self['_' .. idx] = val
	elseif res then -- trigger allowed but value has been updated
		val = self['_' .. idx]
	end

	if res ~= false and self._trigger then
		e.trigger { event = 'OptionSet', match = ('%s.%s'):format(self._path, idx), data = val, old_data = old }
	end
end

function M:__tostring(indent, visited)
	visited = visited or { [self] = self._path }
	local copy = {}
	visited[copy] = visited[self]
	for _, field in ipairs(U.get_dynvars(self)) do
		copy[field.name] = field.value
	end
	return U.tbl_to_str(copy, indent, visited)
end

---Add field backing logic to the current object; no `super` lookups
---Inheritors are required to copy all functions from super to self themselves!
---@return self
function M:new()
	if self._trigger == nil then self._trigger = true end
	return setmetatable(self, M)
end

return M
