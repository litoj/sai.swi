---@diagnostic disable: invisible
---@module 'sai.mode.custom'

local U = require 'sai.lib.utils'
local pager = require 'sai.lib.pager'

---@class sai.mode.custom: sai.lib.remapper
--- Wrapper for auto-changing settings when the mode is active.
--- Supports also eventloop auto registration and deregistration +
--- - `find_all` gets just your mode changes
--- - `unsubscribe` temporarily disables filtered events or permanently removes mode event by id
---
--- Changes are active only while the mode is enabled, then they're reverted.
---@field help_pager? sai.lib.pager included to provide custom keybind help `_path` is defined
---@field map fun(bind:string|string[],fn:fun(self:self),desc:string?)
local M = {
	super = require 'sai.lib.remapper',
	-- protected vars - readonly after initialization
	_help_bind_fmt = '%s\t%s', ---@protected

	-- runtime vars - may be changed by the user any time
	auto_help = false, --- should help_pager be automatically enabled while mode is active
}
setmetatable(M, { __index = M.super })

local fndbg = debug.getinfo

---@param fn fun(self:self)
function M:_rawmap(b, cfg, fn)
	if cfg and not cfg._wrapped then
		---@diagnostic disable-next-line: inject-field
		cfg._wrapped = true
		if type(fn) == 'function' and fndbg(fn, 'u').nparams == 1 then
			cfg.cb = function() fn(self) end
			M.super._rawmap(self, b, cfg)
			return
		end
	end

	M.super._rawmap(self, b, cfg)
end

---@generic O: sai.mode.custom
---@param self `O`|sai.mode.custom
---@return O|sai.mode.custom
function M:new()
	U.new_object(self, M)
	if self._path then
		local name = self._path:gsub('^sai%.', '')
		---@diagnostic disable-next-line: missing-fields
		self.help_pager = pager.new {
			_path = self._path .. '.help_pager',
			_title = name:sub(1, 1):upper() .. name:sub(2) .. ' binds:\t',
			_location = 'topright',
		}
	end

	---@diagnostic disable-next-line: return-type-mismatch
	return M.super.new(self)
end

function M:set_enabled(val)
	if val == self._enabled then return false end
	M.super.set_enabled(self, val)

	-- cache the bind help, but don't display it automatically
	if val and rawget(self.help_pager, '_last_cnt') ~= #self._mappings then
		self.help_pager.lines = U.str_bindlist(self, self._help_bind_fmt)
		rawset(self.help_pager, '_last_cnt', #self._mappings)
	end

	if self.auto_help then self.help_pager.enabled = val end

	return true
end

return M
