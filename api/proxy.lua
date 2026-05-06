---@module 'swi.api.proxy'

local e = require 'swi.api.eventloop'

---Api conversion provider
---@class swi.api.proxy: swi.lib.backer
---@field protected super table the api that we are replacing and redirecting calls to

---@private
---@class proxy: swi.api.proxy
local M = {}

function M.__index(self, idx)
	local fnname = 'get_' .. idx
	local v = rawget(self, fnname)
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
		---@diagnostic disable-next-line: cast-local-type
		fn = fn(self, val, idx)
		if fn == nil then
			rawset(self, '_' .. idx, val)
			---@diagnostic disable-next-line: cast-local-type
			fn = true
		elseif fn then
			val = self['_' .. idx]
		end
	else
		fn = type(val) == 'boolean' and self.super['enable_' .. idx] or self.super[fnname]
		if not fn then error('tried to assign: ' .. self._path .. '.' .. idx) end

		fn(val)
		rawset(self, '_' .. idx, val) -- set in case a getter isn't available
	end

	if fn and self._trigger then
		e.trigger { event = 'OptionSet', match = ('%s.%s'):format(self._path, idx), data = val, old_data = old }
	end
end

---Create a dynamic table where variable I/O can be custom-defined
---Practically a metatable designed for automatic passthrough to a different api.
---@generic O: swi.api.proxy
---@return O self
function M:new()
	if self._trigger == nil then self._trigger = true end
	return setmetatable(self, M)
end

return M
