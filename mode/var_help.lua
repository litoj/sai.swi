---@module 'sai.mode.var_help'

local U = require 'sai.lib.utils'
local help = require 'sai.mode.help'

---Variable help overlay: all live-settable options plus, for each active custom
---mode, the mode's own variables and the sai settings it currently overrides.
---TODO: in the future: add ways to select a variable and list help and its possible values
---@class sai.mode.var_help: sai.mode.help
local M = { _path = 'sai.mode.var_help' }

---@param ident string
---@param obj sai.lib.backer
---@param var string
---@return mode_base.text.dyntext
function M.generate_var_updater(ident, obj, var)
	return {
		event = 'OptionSet',
		pattern = ('%s.%s'):format(obj._path, var),
		callback = function()
			return ('%s%s\t%s'):format(ident, var, tostring(obj[var])):gsub('\n%s*', ' '):gsub('{', '{{')
		end,
	}
end

---All live-settable options, grouped by the api object that provides them.
function M:settings_list()
	local out = {}
	for _, obj in ipairs {
		sai,
		sai.text,
		sai.imagelist,
		sai.gallery,
		sai.viewer,
		sai.slideshow,
	} do
		out[#out + 1] = ('%s:'):format(obj._path:upper())

		for _, field in ipairs(U.get_dynvars(obj)) do
			out[#out + 1] = M.generate_var_updater('  ', obj, field.name)
		end
	end
	return out
end

---The layer's own variables, its directly nested option objects (the pager, ...)
---and the sai settings it currently overrides.
---@param mode sai.lib.remapper
---@return extended_text_template[] lines
function M:varset_lines(mode)
	local out = {}
	-- Backed vars
	for _, var in ipairs(U.get_dynvars(mode)) do
		out[#out + 1] = M.generate_var_updater('  ', mode, var.name)
	end

	-- Nested objects
	local nested = {}
	for name, obj in pairs(mode) do
		if type(obj) == 'table' and name:sub(1, 1) ~= '_' and name ~= 'super' and name ~= 'help_pager' then
			local vars = U.get_dynvars(obj)
			if vars[1] then nested[#nested + 1] = { name = name, obj = obj, vars = vars } end
		end
	end
	table.sort(nested, function(a, b) return a.name < b.name end)

	for _, sub in ipairs(nested) do
		out[#out + 1] = ('  %s:'):format(sub.name)
		for _, var in ipairs(sub.vars) do
			out[#out + 1] = M.generate_var_updater('    ', sub.obj, var.name)
		end
	end

	-- Swayimg/Sai opt overrides: the reconfigurer does not fire events on
	-- changes, so the lines are fixed strings of the overridden values
	local overrides = {}
	for name, v in pairs(rawget(mode.sai, '_vars') or {}) do
		overrides[name] = v.new
	end
	for name, sub in pairs(mode.sai) do
		-- sub-reconfigurers (sai.text, ...) carry their own overrides;
		-- rawget: their sibling fields error on unknown keys
		local subvars = type(sub) == 'table' and rawget(sub, '_vars')
		if subvars then
			for k, v in pairs(subvars) do
				overrides[('%s.%s'):format(name, k)] = v.new
			end
		end
	end

	local paths = {}
	for path in pairs(overrides) do
		paths[#paths + 1] = path
	end
	if paths[1] then
		table.sort(paths)
		out[#out + 1] = '  sai overrides:'
		for _, path in ipairs(paths) do
			out[#out + 1] = ('    %s\t%s'):format(path, tostring(overrides[path])):gsub('\n%s*', ' '):gsub('{', '{{')
		end
	end
	return out
end

---All tabs, generated straight-up (see sai.mode.help).
function M:tabs()
	local tabs = {
		{ title = 'Settings', lines = self:settings_list() },
	}
	for _, mode in ipairs(U.get_active_modes(sai[sai.mode])) do
		tabs[#tabs + 1] = {
			title = U.pretty_name(mode._path),
			lines = self:varset_lines(mode),
		}
	end
	return tabs
end

return help.new(M)
