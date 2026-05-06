---@module 'swi.lib.keybind_processor'
local U = require 'swi.lib.utils'

---@class swi.lib.keybind_processor: keybind_processor
---@field _path string path to the module for error processing
---@field _mappings bind_map|{[string]:{_traced:boolean}}
---Function to set a mapping directly without updating the active mappings.
---Nil action gets replaced with the default handler for unbound keys
---@field _rawmap fun(self:swi.lib.keybind_processor,b:string,action:fun()?,bindcfg:bindcfg?)
---@field warn_on_duplicates boolean
local M = {}

---@return swi.lib.keybind_processor
function M:new()
	if self._mappings then
		local trace = U.pretty_trace('keybind_processor.+new', debug.traceback())
		for _, v in pairs(self._mappings) do
			v.trace = trace
			v._traced = true
			v.default = true
		end
	else
		self._mappings = {}
	end

	self.remap = function(b, cfg)
		b = U.transform_key(b)
		local old = self._mappings[b]
		cfg.trace = cfg.trace or (cfg.default and 'builtin') or debug.traceback()
		self._mappings[b] = cfg
		self:_rawmap(b, cfg.cb, cfg)
		return old
	end

	self.unmap = function(b)
		b = U.transform_key(b)
		self._mappings[b] = nil
		self:_rawmap(b)
	end

	local function pretty_trace(trace) return U.pretty_trace('keybind_processor.+map', trace) end

	self.map = function(bind, action, desc)
		local bindcfg = { ---@type bindcfg
			cb = action,
			desc = desc,
			trace = debug.traceback(),
		}

		for _, b in ipairs(U.tabled(bind)) do
			local old = self.remap(b, bindcfg)
			if self.warn_on_duplicates and old and not old.default then
				print(
					('Duplicate mapping: %s.map("%s", %s)'):format(
						self.warn_on_duplicates and self._path,
						b,
						pretty_trace(old.trace):match '^[^\n]+'
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
