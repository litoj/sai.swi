---@module 'sai.mode.var_help'

local U = require 'sai.lib.utils'
local help = require 'sai.mode.help'
local vars = require('sai.lib.registry').vars

---Variable help overlay.
---TODO: add ways to select a variable and toggle it, show its possible values and the help for its meaning (from the docs).
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
		---@diagnostic disable-next-line: invisible -- the api object's own path names its section
		out[#out + 1] = ('%s:'):format(obj._path:upper())

		for _, field in ipairs(U.get_dynvars(obj)) do
			out[#out + 1] = M.generate_var_updater('  ', obj, field.name)
		end
	end
	return out
end

---A custom mode's own vars, nested objects and sai overrides.
---@param mode sai.lib.remapper
---@param own_sai? boolean list the sai overrides; a sub-mode shares the root's tree, so overrides show under the root only (default true)
---@return extended_text_template[]
function M:varset_lines(mode, own_sai)
	local out = {}
	-- Backed vars
	for _, var in ipairs(U.get_dynvars(mode)) do
		out[#out + 1] = M.generate_var_updater('  ', mode, var.name)
	end

	-- Nested objects
	local nested = {}
	for name, obj in pairs(mode) do
		if type(obj) == 'table' and name:sub(1, 1) ~= '_' and name ~= 'super' then
			local objvars = U.get_dynvars(obj)
			if objvars[1] then nested[#nested + 1] = { name = name, obj = obj, vars = objvars } end
		end
	end
	table.sort(nested, function(a, b) return a.name < b.name end)

	for _, sub in ipairs(nested) do
		out[#out + 1] = ('  %s:'):format(sub.name)
		for _, var in ipairs(sub.vars) do
			out[#out + 1] = M.generate_var_updater('    ', sub.obj, var.name)
		end
	end

	if own_sai == false then return out end

	-- the reconfigurer fires no events: these lines are fixed strings
	local overrides = {}
	for name, stack in pairs(vars[rawget(mode.sai, 'super')]) do
		local v = stack[mode.sai]
		if v then overrides[name] = v.new end
	end
	for name, sub in pairs(mode.sai) do
		-- rawget: sibling fields on a reconfigurer error on unknown keys
		local super = type(sub) == 'table' and rawget(sub, 'super')
		if super then
			for k, stack in pairs(vars[super]) do
				local v = stack[sub]
				if v then overrides[('%s.%s'):format(name, k)] = v.new end
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

function M:gen_tabs()
	self._tabs = { { title = 'Main API Settings', lines = self:settings_list() } }
	-- a sub-mode extends the current root's _path: its varset lands on
	-- the root's tab; newest root first
	local groups = {}
	local root_path
	for i = 2, #sai.modes do
		local m = sai.modes[i]
		---@cast m sai.api.mode_base|sai.lib.remapper
		if not m.component then -- components ride their host's tab
			local path = m._path or ''
			if not (root_path and path:sub(1, #root_path + 1) == root_path .. '.') then
				root_path = path
				groups[#groups + 1] = { root = m, subs = {} }
			else
				local subs = groups[#groups].subs
				subs[#subs + 1] = m
			end
		end
	end
	for gi = #groups, 1, -1 do
		local group = groups[gi]
		local lines = self:varset_lines(group.root)
		for _, sub in ipairs(group.subs) do
			-- ' ' not '' - the app skips truly empty lines
			if lines[1] then lines[#lines + 1] = ' ' end
			lines[#lines + 1] = ('[%s]'):format(U.pretty_name(sub._path, group.root._path))
			for _, line in ipairs(self:varset_lines(sub, false)) do
				lines[#lines + 1] = line
			end
		end
		self._tabs[#self._tabs + 1] = {
			title = U.pretty_name(group.root._path),
			lines = lines,
		}
	end
end

help.new(M)
return M
