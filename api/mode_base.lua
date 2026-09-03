---@diagnostic disable: invisible
---@module 'sai.api.mode_base'

local proxy = require 'sai.api.proxy'
local e = require 'sai.api.eventloop'
local kp = require 'sai.lib.keybind_processor'

---@class sai.api.mode_base: mode_base, sai.lib.keybind_processor
---@field super swayimg_appmode
---@field _active_binders sai.lib.keybind_processor[] for help mode awareness of various bind layers
---@field private _mc_map {[string]:function[]} multi-click map TODO: generalize for any key combo
local M = { warn_on_duplicates = true, multiclick_delay = 175 }

---@return {_path:string, _mappings: sai.lib.keybind_processor.bindmap }}[]
function M:get_active_bindsets()
	local bindsets = {}
	local all = {}
	for k, v in self._mappings do
		all[k] = v
	end
	for i = #self._active_binders, 1, -1 do
		local binder = self._active_binders[i]
		local mappings = {}
		for k, v in pairs(binder._mappings) do
			local used = all[k]
			-- recognize only if it is this mapping and if this is a mapping, not un-mapping
			if used and used.cb == v.cb then
				all[k] = nil
				if used.cb then mappings[k] = v end
			end
		end
		bindsets[#bindsets + 1] = { _path = binder._path, _mappings = mappings }
	end
	bindsets[#bindsets + 1] = { _path = self._path, _mappings = all } -- the rest is the main mode
	return bindsets
end

function M:set_on_unassigned(fn)
	self._on_unassigned = fn
	self.super.on_unassigned_key(fn)
	return false
end

function M:_rawmap(b, cfg, action)
	if type(action) == 'string' then action = function() sai.exec(cfg.cb) end end

	if b:match 'Mouse' or b:match 'Scroll' then
		local rep_nr
		b = b:gsub('(%d+)[+-]', function(x)
			rep_nr = tonumber(x)
			return ''
		end)
		rep_nr = rep_nr or 1

		if not action then
			self._mc_map[b][rep_nr] = nil
			if not next(self._mc_map[b]) then
				self.super.on_mouse(b, function() sai.notify('Unhandled mouse: ' .. b) end)
				self._mc_map[b] = nil
			end
			return
		end

		if self._mc_map[b] then -- handler already registered
			self._mc_map[b][rep_nr] = action
			return
		end

		local map = { [rep_nr] = action }
		self._mc_map[b] = map

		local cnt = 0
		local function exec()
			map[cnt]()
			cnt = 0
		end

		-- TODO: maybe rework to generally map for any sequence of keys? -> vim
		self.super.on_mouse(b, function()
			cnt = cnt + 1
			if not map[cnt + 1] then -- multiclick not registered
				exec()
				return
			end

			local old_cnt = cnt
			sai.defer_fn(function()
				if cnt == old_cnt then -- user didn't click again
					if map[cnt] then -- run the action for cnt
						exec()
					end
					cnt = 0
				end
			end, self.multiclick_delay)
		end)
	else
		self.super.on_key(b, action or function() self._on_unassigned(b) end)
	end
end
M._rawunmap = M._rawmap

---@generic O: sai.api.mode_base
---@param self `O`
---@param api_name appmode_t
---@return O
function M.new(self, api_name)
	local api = self.super ---@diagnostic disable-line: undefined-field
	---@diagnostic disable: inject-field
	self._path = 'sai.' .. api_name
	self._active_binders = {}
	for k, v in pairs(M) do
		self[k] = v
	end
	self.new = nil

	--- https://github.com/artemsen/swayimg/blob/master/src/appmode.cpp#L11
	self._mark_color = 0xff808080
	if not self._pinch_factor then self._pinch_factor = 1.0 end

	for _, sig in ipairs { 'USR1', 'USR2' } do
		api.on_signal(sig, function() e.trigger { event = 'Signal', mode = api_name, match = sig } end)
	end

	self.reload = function(cb)
		if cb then e.subscribe {
			event = 'ImgChanged',
			once = true,
			callback = cb,
		} end
		self.super.reload()
	end

	self._on_unassigned = function(key)
		local sym = key:match '[^+]+$'
		local ok
		if #sym > 1 then
			if sym:sub(1, 3) == 'KP_' then -- try non-kp versions of kp keys
				local k = self._mappings[key:gsub('KP_', '')]
				if k then return k.cb() end
			else
				ok = sym:sub(1, 1):match '%l' -- allow ccaron/aacute, not Next/End
			end
		else
			ok = sym:match '%d'
		end

		if ok then
			-- toggle Shift and try again
			local k = key:find('Shift', 1, true) and key:gsub('Shift%+', '') or key:gsub('([^+]+)$', 'Shift+%1')
			k = self._mappings[k]
			if k then return k.cb() end
		end

		if key == 'ISO_Level3_Shift' then return end -- AltGr
		sai.notify('Unhandled key: ' .. key)
	end
	api.on_unassigned_key(self._on_unassigned)
	self._mc_map = {}
	self.warn_on_duplicates = M.warn_on_duplicates
	kp.new(self)

	return proxy.new(self)
end

return M
