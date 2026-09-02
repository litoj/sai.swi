---@module 'sai.lib.remapper'
---@diagnostic disable: invisible

local U = require 'sai.lib.utils'
local kp = require 'sai.lib.keybind_processor'
local backer = require 'sai.lib.backer'

---Keybind override: temporarily replace keybindings in current mode.
---Implements the same map/unmap interface as mode_base.
---@class sai.lib.remapper: sai.lib.keybind_processor, sai.lib.backer
---@field mode? appmode_t in which mode should we set the bindings
---@field enabled? boolean
---Unbound key handler with auto-injected _self_
---On set() the function will get wrapped with _self_, so the value on get() will differ
---@field on_unassigned fun(self:sai.lib.remapper, bind:string)
local M = {
	warn_on_duplicates = true, --- for keybind_processor

	---@type appmode_t|false
	_mode = false, ---@protected
	---@type sai.api.mode_base|false
	_mode_api = false, ---@protected
	_enabled = false, ---@protected
	---@type bind_map saved original mappings per mode
	_omaps = {}, ---@private
	---@type fun(string)|false
	_on_unassigned = false, ---@protected
	---@type fun(string)|false
	_api_on_unassigned = false, ---@private original value of the api
}

---@generic O: sai.lib.remapper
---@return O self
function M:new()
	if self._trigger == nil then self._trigger = not not self._path end
	return backer.new(kp.new(U.new_object(self, M)))
end

function M:set_mode(mode)
	if self._mode == mode then return false end

	local oe = self._enabled
	M.set_enabled(self, false)
	self._mode = mode
	M.set_enabled(self, oe)
	return false
end

---@param _ nil action cannot differ from config in remapper
function M:_rawmap(b, cfg, _)
	if self._enabled then
		self._omaps[b] = self._mode_api._mappings[b] or false
		self._mode_api:_setmap(b, cfg)
	end
end

function M:set_on_unassigned(fn)
	local wrapped = fn and function(key) fn(self, key) end
	if self._enabled then
		if
			not wrapped -- disabling the override
			and self._mode_api._on_unassigned ~= self._on_unassigned -- the active handler impl changed
			and self._mode_api._on_unassigned ~= self._api_on_unassigned -- but not to the original impl
		then -- silently disable without overriding the mode impl back to the original
			self._on_unassigned = wrapped
			self._api_on_unassigned = false
			return false
		end

		if not self._api_on_unassigned then self._api_on_unassigned = self._mode_api._on_unassigned end
		-- NOTE: if someone changes the active mode's handler directly, we override it without recovery
		self._on_unassigned = wrapped
		self._mode_api.on_unassigned = fn or self._api_on_unassigned
	end
	return false
end

function M:set_enabled(val)
	if val == self._enabled then return false end
	self._enabled = val

	if val then
		---@diagnostic disable-next-line: assign-type-mismatch
		self._mode_api = sai[self._mode or sai.mode] -- keey mode dynamic if not set by the user
		for b, cfg in pairs(self._mappings) do
			self:_rawmap(b, cfg, cfg.cb)
		end

		if self._on_unassigned then
			self._api_on_unassigned = self._mode_api._on_unassigned
			self._mode_api.on_unassigned = self._on_unassigned
		end
	else
		for b, cfg in pairs(self._omaps) do
			self._mode_api:_setmap(b, cfg)
		end
		self._omaps = {}

		if self._on_unassigned then
			-- reset only if our value hasn't been overwritten
			if self._mode_api._on_unassigned == self._on_unassigned then
				self._mode_api.on_unassigned = self._api_on_unassigned
			end
			self._api_on_unassigned = false
		end
	end
	return true
end

return M
