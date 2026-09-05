---@module 'sai.lib.remapper'
---@diagnostic disable: invisible

local U = require 'sai.lib.utils'
local kp = require 'sai.lib.keybind_processor'
local backer = require 'sai.lib.backer'
local reconfigurer = require 'sai.lib.reconfigurer'

---Keybind override: temporarily replace keybindings and settings of the
---current mode. Implements the same map/unmap interface as mode_base.
---Supports also eventloop auto registration and deregistration +
--- - `find_all` gets just your mode changes
--- - `unsubscribe` temporarily disables filtered events or permanently removes mode event by id
---@class sai.lib.remapper: sai.lib.keybind_processor, sai.lib.backer
---@field enabled? boolean
---@field auto_help boolean display sai.mode.key_help while the mode is active
---@field map fun(bind:string|string[],fn:fun(self:self),desc:string?)
---Unbound key handler with auto-injected _self_
---On set() the function will get wrapped with _self_, so the value on get() will differ
---@field on_unassigned fun(self:sai.lib.remapper, bind:string)
---@field sai? sai.lib.reconfigurer.sai fakeapi to set changes to apply only when mode is enabled
local M = {
	warn_on_duplicates = true, --- for keybind_processor
	--- Filter of existing mappings for which should be kept and which disabled while mode is enabled
	--- Return `true` to remove.
	---@type false|fun(bind:string,bindcfg:bindcfg):boolean
	map_filter = false,
	persist_mode_change = false, --- should mode change shift this object to work in the new mode
	auto_help = true, --- should key_help be automatically displayed while the mode is active

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

	self.sai = reconfigurer.new { super = sai }
	self.sai.eventloop.subscribe {
		event = { 'ModeChangedPre', 'ModeChanged' },
		callback = function(ev)
			if not self.persist_mode_change then self.enabled = false end
			if self._enabled then self:_on_mode_change(ev) end
		end,
	}
	return backer.new(kp.new(U.new_object(self, M)))
end

---@param ev event.ModeChanged
function M:_on_mode_change(ev)
	if ev.event == 'ModeChangedPre' then -- undo keybind changes on old mode
		M.set_enabled(self, false)
		self._enabled = true
		-- disabling also unsubscribed our eventloop hooks: resubscribe so that
		-- the following ModeChanged event still reaches us
		self.sai.eventloop(true)
	else -- apply keybind changes to new mode
		self._enabled = false
		M.set_enabled(self, true)
	end
end

local fndbg = debug.getinfo

---Inject the mode instance into single-argument callbacks.
---@param fn string|fun(self:self)? action to wrap
function M:_rawmap(b, cfg, fn)
	if cfg and not cfg._wrapped then
		---@diagnostic disable-next-line: inject-field
		cfg._wrapped = true
		if type(fn) == 'function' and fndbg(fn, 'u').nparams == 1 then cfg.cb = function() fn(self) end end
	end

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
		-- this is the correct behaviour
		self._on_unassigned = wrapped
		self._mode_api.on_unassigned = fn or self._api_on_unassigned
	end
	return false
end

function M:set_enabled(val)
	if val == self._enabled then return false end
	self._enabled = val

	if val then
		self.sai(val) -- also changes mode to the desired one so keymaps get applied correctly
		self._mode_api = sai[sai.mode]

		if self.map_filter then -- unmap existing keybinds by filter
			local fn = self.map_filter
			for b, cfg in pairs(self._mode_api._mappings) do
				---@diagnostic disable-next-line: need-check-nil
				if fn(b, cfg) then M._rawmap(self, b) end
			end
		end
		for b, cfg in pairs(self._mappings) do -- enable all override mappings
			self:_rawmap(b, cfg, cfg.cb)
		end

		if self._on_unassigned then
			self._api_on_unassigned = self._mode_api._on_unassigned
			self._mode_api.on_unassigned = self._on_unassigned
		end
	else
		if self._api_on_unassigned then
			-- reset only if our value hasn't been overwritten
			if self._mode_api._on_unassigned == self._on_unassigned then
				self._mode_api.on_unassigned = self._api_on_unassigned
			end
			self._api_on_unassigned = false
		end

		for b, cfg in pairs(self._omaps) do -- restore original mappings
			self._mode_api:_setmap(b, cfg)
		end
		self._omaps = {}

		self.sai(val)
	end
	self._mode_api.active_mode = self
	return true
end

return M
