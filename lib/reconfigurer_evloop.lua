---@module 'sai.lib.reconfigurer_evloop'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'

---@overload fun(enable:sai.eventloop.hook[]|boolean)
---@class sai.lib.reconfigurer.eventloop: sai.lib.reconfigurer,sai.eventloop
---@field _new {[hook_cfg]:1} hooks to register
local M = {}

local eventloop_mt = {
	__index = function(_, idx) error('sai.lib.reconfigurer.eventloop does not support index: ' .. idx) end,
	__call = function(self, enable)
		if type(enable) == 'table' then
			for _, v in ipairs(enable) do
				self.subscribe(v)
			end
			return
		end

		if enable == self._enabled then return false end
		self._enabled = enable

		if enable then
			for h, _ in pairs(self._new) do
				e.subscribe(h)
			end
		else
			for h, _ in pairs(self._new) do
				e.unsubscribe { id = h }
			end
		end
	end,

	__tostring = function(self)
		-- one-line event=selector label; empty selector matches all
		local function hook_str(h)
			local ev = type(h.event) == 'table' and table.concat(h.event, ',') or h.event or '*'
			local sel = h.match or h.pattern or h.group or h.id
			return ('%s=%s'):format(ev, tostring(sel or ''))
		end
		local hooks = {}
		for h in pairs(self._new) do
			hooks[#hooks + 1] = hook_str(h)
		end
		return U.tbl_to_str { hooks = hooks }
	end,
}

---@param self {_enabled?:boolean}
---@return sai.lib.reconfigurer.eventloop
function M:new()
	---@type sai.lib.reconfigurer.eventloop
	self._enabled = self._enabled or false
	self._new = {}

	self.subscribe = function(h)
		self._new[h] = 1
		if self._enabled then e.subscribe(h) end
		return h
	end

	return setmetatable(self, eventloop_mt)
end

return M
