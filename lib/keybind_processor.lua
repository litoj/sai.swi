---@module 'sai.lib.keybind_processor'
local U = require 'sai.lib.utils'
local B = require 'sai.lib.bindmods'

---@class sai.lib.keybind_processor.bindcfg: bindcfg
---@field package _traced? boolean
---@field package _wrapped? boolean the action already carries its mode injection

---@class sai.lib.keybind_processor.bindmap: {[string]: sai.lib.keybind_processor.bindcfg}

---@class sai.lib.keybind_processor: keybind_processor
---@field _path? string path to the module for error processing
---@field _mappings? sai.lib.keybind_processor.bindmap
---@field warn_on_duplicates? boolean warn on duplicate plain binds
--- TODO: make modebase translate multimaps (`cd`) correctly and use sig USR1 for fallback
---@field _rawmap? fun(self:self,bind:string,cfg:bindcfg,action:fun(...)) must be overridden by inheriting class
---@field _rawunmap? fun(self:self,bind:string)
local M = {
	---Default custom handler tries to solve common layout differences (toggled shift)
	---@type fun(key: string)|false
	_on_unassigned = false,
}

---Set a mapping directly without updating the active mappings.
---The key canonicalizes through the bind modifier registry.
---@param bind string
---@param cfg bindcfg? nil drops the bind, falling back to the unbound-keys default
function M:_setmap(bind, cfg)
	bind = B.canonical(bind)
	---@diagnostic disable-next-line: assign-type-mismatch
	self._mappings[bind] = cfg or nil
	if not cfg then
		self:_rawunmap(bind)
	else
		self:_rawmap(bind, cfg, cfg.cb)
	end
end

---@return sai.lib.keybind_processor
function M:new()
	self._setmap = M._setmap
	if self._mappings then
		local trace = U.pretty_trace('keybind_processor.+new', debug.traceback())
		for k, v in pairs(self._mappings) do
			local newkey = B.canonical(k)
			if k ~= newkey then
				self._mappings[k] = nil
				self._mappings[newkey] = v
			end

			v.trace = trace
			v._traced = true
			if not v.kind then v.kind = 'default' end
		end
	else
		self._mappings = {}
	end

	self.remap = function(b, cfg)
		b = B.canonical(b)
		local old = self._mappings[b]
		cfg.trace = cfg.trace or cfg.kind or debug.traceback()
		self:_setmap(b, cfg)
		return old
	end

	self.unmap = function(b) self:_setmap(b) end

	local function pretty_trace(trace) return U.pretty_trace('keybind_processor.+map', trace) end

	self.map = function(bind, action, opts_or_desc)
		local bindcfg = type(opts_or_desc) == 'table' and opts_or_desc or {} ---@type bindcfg
		bindcfg.cb = action
		if type(opts_or_desc) == 'string' then bindcfg.desc = opts_or_desc end
		bindcfg.trace = debug.traceback()

		for _, b in ipairs(U.tabled(bind)) do
			local old = self.remap(b, bindcfg)
			-- factory defaults are meant to be overridden, unmapping is
			-- removal: only a plain bind mapped twice with a real action warns
			if action ~= nil and self.warn_on_duplicates and old and not old.kind and not bindcfg.kind then
				sai.log(
					('Duplicate mapping %s["%s"].\n  old: %s\n  new: %s)'):format(
						self._path,
						b,
						pretty_trace(old.trace):match '^[^\n]+',
						pretty_trace(bindcfg.trace):match '^[^\n]+'
					)
				)
			end
		end
	end

	self.get_mappings = function()
		for _, v in pairs(self._mappings) do
			if not v._traced then
				v.trace = pretty_trace(v.trace)
				v._traced = true
			end
		end
		return self._mappings
	end

	return self
end

return M
