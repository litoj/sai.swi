---@module 'swi.lib.bind_override'
---@diagnostic disable: invisible

local U = require 'swi.lib.utils'
local kp = require 'swi.lib.keybind_processor'
local backer = require 'swi.lib.backer'

---Keybind override: temporarily replace keybindings in current mode.
---Implements the same map/unmap interface as mode_base.
---@class swi.lib.bind_override: swi.lib.keybind_processor, swi.lib.backer
---@field mode? appmode_t in which mode should we set the bindings
---@field enabled? boolean
local M = {
	warn_on_duplicates = true, --- for keybind_processor

	---@type appmode_t|false
	_mode = false, ---@protected
	---@type swi.api.mode_base|false
	_mode_api = false, ---@private
	_enabled = false, ---@protected
	---@type bind_map saved original mappings per mode
	_omaps = {}, ---@private
}

---@return swi.lib.bind_override
function M:new()
	if self._trigger == nil then self._trigger = not not self._path end
	return backer.new(kp.new(U.new_object(self, M)))
end

local function rawmap(api, b, cfg)
	if cfg then
		api.remap(b, cfg)
	else
		api.unmap(b)
	end
end

-- for keybind_processor
function M:_rawmap(b, _, cfg)
	if self._enabled then
		self._omaps[b] = self._mode_api._mappings[b]
		rawmap(self._mode_api, b, cfg)
	end
end

function M:set_mode(mode)
	if self._mode == mode then return false end

	local oe = self._enabled
	M.set_enabled(self, false)
	self._mode = mode
	M.set_enabled(self, oe)
	return false
end

function M:set_enabled(val)
	if val == self._enabled then return false end
	self._enabled = val

	if val then
		---@diagnostic disable-next-line: assign-type-mismatch
		self._mode_api = swi[self._mode or swi.mode] -- keey mode dynamic if not set by the user
		local cur = self._mode_api._mappings
		for b, cfg in pairs(self._mappings) do
			self._omaps[b] = cur[b]
			rawmap(self._mode_api, b, cfg)
		end
	else
		for b, cfg in pairs(self._omaps) do
			rawmap(self._mode_api, b, cfg)
		end
		self._omaps = {}
	end
	return true
end

return M
