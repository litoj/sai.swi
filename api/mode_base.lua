---@diagnostic disable: invisible
---@module 'swi.api.mode_base'

local proxy = require 'swi.lib.proxy'
local e = require 'swi.api.eventloop'
local kp = require 'swi.lib.keybind_processor'

---@class swi.api.mode_base: mode_base, swi.lib.keybind_processor
---@field super swayimg_appmode
local M = { warn_on_duplicates = true }

---@generic O: swi.api.mode_base
---@param self `O`
---@param api_name appmode_t
---@return O
function M.new(self, api_name)
	local api = self.super ---@diagnostic disable-line: undefined-field
	---@diagnostic disable: inject-field
	self._path = 'swi.' .. api_name

	--- https://github.com/artemsen/swayimg/blob/master/src/appmode.cpp#L11
	self._mark_color = 0xff808080
	if not self._pinch_factor then self._pinch_factor = 1.0 end

	for _, sig in ipairs { 'USR1', 'USR2' } do
		api.on_signal(sig, function() e.trigger { event = 'Signal', match = sig } end)
	end

	function self:_rawmap(b, action)
		if b:match 'Mouse' or b:match 'Scroll' then
			api.on_mouse(b, action or function() swi.text.status = 'Unhandled mouse: ' .. b end)
		else
			api.on_key(b, action or function() swi.text.status = 'Unhandled key: ' .. b end)
		end
	end
	self.warn_on_duplicates = M.warn_on_duplicates
	kp.new(self)

	return proxy.new(self)
end

return M
