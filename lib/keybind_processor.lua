---@module 'sai.lib.keybind_processor'
local U = require 'sai.lib.utils'

---@class sai.lib.keybind_processor: keybind_processor
---@field _path string path to the module for error processing
---@field _mappings bind_map|{[string]:{_traced:boolean}}
---Function to set a mapping directly without updating the active mappings.
---Nil action gets replaced with the default handler for unbound keys
---@field warn_on_duplicates boolean
local M = {}

-- TODO: make modebase translate multimaps (`cd`) correctly and use sig USR1 for fallback
---Must be overriden by inheriting class
---@protected
---@param bind string
---@param cfg bindcfg
---@param action fun()
function M:_rawmap(bind, cfg, action) end

---Must be overriden by inheriting class
---@protected
---@param bind string
function M:_rawunmap(bind) end

---@private
---@param bind string
---@param cfg bindcfg?
function M:_setmap(bind, cfg)
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
			local newkey = U.normalize_key(k)
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
		b = U.normalize_key(b)
		local old = self._mappings[b]
		cfg.trace = cfg.trace or cfg.kind or debug.traceback()
		self:_setmap(b, cfg)
		return old
	end

	self.unmap = function(b) M:_setmap(U.normalize_key(b)) end

	local function pretty_trace(trace) return U.pretty_trace('keybind_processor.+map', trace) end

	self.map = function(bind, action, opts_or_desc)
		local bindcfg = type(opts_or_desc) == 'table' and opts_or_desc or {} ---@type bindcfg
		bindcfg.cb = action
		if type(opts_or_desc) == 'string' then bindcfg.desc = opts_or_desc end
		bindcfg.trace = debug.traceback()

		for _, b in ipairs(U.tabled(bind)) do
			local old = self.remap(b, bindcfg)
			if self.warn_on_duplicates and old and not old.kind then
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
