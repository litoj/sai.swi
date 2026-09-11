---@module 'sai.api.proxy'

local e = require 'sai.api.eventloop'
local backer = require 'sai.lib.backer'

---@class sai.api.proxy: sai.lib.backer
---@field protected super table

---@private
---@class proxy: sai.api.proxy
local M = {}

function M.__index(self, idx)
	local fnname = 'get_' .. idx
	local v = rawget(self, fnname) -- test for overrides first
	if v then return v(self, idx) end

	v = self.super[idx] -- get fn
	if v ~= nil then -- directly forward access to the old api
		if type(v) == 'function' then rawset(self, idx, v) end
		return v
	end

	v = self.super[fnname] -- get variable
	if v then return v() end -- idiomatic getter

	v = rawget(self, '_' .. idx)
	if v ~= nil then return v end -- read local copy of the last set value

	error('tried to get: ' .. self._path .. '.' .. idx)
end

function M.__newindex(self, idx, val)
	local old = rawget(self, '_' .. idx)

	local fnname = 'set_' .. idx
	local fn = rawget(self, fnname)
	if fn then
		-- set the field only if the setter allows it
		fn = fn(self, val, idx)
		if fn == nil then
			self['_' .. idx] = val
		elseif fn then
			val = self['_' .. idx]
		else
			return
		end
	else
		self.super[idx] = val
		self['_' .. idx] = val -- set in case a getter isn't available
	end
	e.trigger { event = 'OptionSet', match = ('%s.%s'):format(self._path, idx), data = val, old_data = old }
end

M.__tostring = backer.__tostring

---Create a dynamic table where variable I/O can be custom-defined
---Practically a metatable designed for automatic passthrough to a different api.
---@generic O: sai.api.proxy
---@return O
function M:new() return setmetatable(self, M) end

return M
