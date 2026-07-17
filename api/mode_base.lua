---@diagnostic disable: invisible
---@module 'sai.api.mode_base'

local proxy = require 'sai.api.proxy'
local e = require 'sai.api.eventloop'
local kp = require 'sai.lib.keybind_processor'

---@class sai.api.mode_base: mode_base, sai.lib.keybind_processor
---@field super swayimg_appmode
local M = { warn_on_duplicates = true }

---@generic O: sai.api.mode_base
---@param self `O`
---@param api_name appmode_t
---@return O
function M.new(self, api_name)
	local api = self.super ---@diagnostic disable-line: undefined-field
	---@diagnostic disable: inject-field
	self._path = 'sai.' .. api_name
	self.multiclick_delay = 0.175

	--- https://github.com/artemsen/swayimg/blob/master/src/appmode.cpp#L11
	self._mark_color = 0xff808080
	if not self._pinch_factor then self._pinch_factor = 1.0 end

	for _, sig in ipairs { 'USR1', 'USR2' } do
		api.on_signal(sig, function() e.trigger { event = 'Signal', match = sig } end)
	end

	self.reload = function(cb)
		if cb then e.subscribe {
			event = 'ImgChanged',
			once = true,
			callback = cb,
		} end
		self.super.reload()
	end

	self._multi_click_map = {}
	function self:_rawmap(b, cfg, action)
		if type(action) == 'string' then action = function() sai.exec(cfg.cb) end end

		if b:match 'Mouse' or b:match 'Scroll' then
			local rep_nr
			b = b:gsub('(%d+)[+-]', function(x)
				rep_nr = tonumber(x)
				return ''
			end)
			rep_nr = rep_nr or 1

			if not action then
				self._multi_click_map[b][rep_nr] = nil
				if not next(self._multi_click_map[b]) then
					api.on_mouse(b, function() sai.text.set_status('Unhandled mouse: ' .. b) end)
					self._multi_click_map[b] = nil
				end
				return
			end

			if self._multi_click_map[b] then -- handler already registered
				self._multi_click_map[b][rep_nr] = action
				return
			end

			local map = { [rep_nr] = action }
			self._multi_click_map[b] = map

			local cnt = 0
			local function exec()
				map[cnt]()
				cnt = 0
			end

			api.on_mouse(b, function()
				cnt = cnt + 1
				if not map[cnt + 1] then -- multiclick not registered
					exec()
					return
				end

				local old_cnt = cnt
				sai.defer(self.multiclick_delay, function()
					if cnt == old_cnt then -- user didn't click again
						if map[cnt] then -- run the action for cnt
							exec()
						end
						cnt = 0
					end
				end)
			end)
		else
			api.on_key(b, action or function() sai.text.set_status('Unhandled key: ' .. b) end)
		end
	end
	self._rawunmap = self._rawmap
	self.warn_on_duplicates = M.warn_on_duplicates
	kp.new(self)

	return proxy.new(self)
end

return M
