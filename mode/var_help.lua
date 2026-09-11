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

---A listed variable reads through its getter: mode-bound values (viewer
---scale outside the viewer) throw on the inactive object. Those stay out of
---the listing entirely, so neither the display nor the filtering can trip them.
---@param obj table the api object owning the variable
---@param var string
---@return boolean
local function readable(obj, var)
	return pcall(function() return obj[var] end)
end

---Prompt for a new value of a listed variable and set it, coercing the obvious scalars.
---@param obj sai.lib.backer the api object owning the variable
---@param var string
---@return fun()
local function prompt_for(obj, var)
	return function()
		require('sai.lib.ui').input {
			prompt = ('New value for %s:'):format(var),
			text = tostring(obj[var]),
			on_confirm = function(text)
				if text == false then return end
				local value = table.concat(text, '\n')
				local coerced = value == 'true' and true or value == 'false' and false or tonumber(value) or value
				local ok, err = pcall(function() obj[var] = coerced end)
				if not ok then sai.notify(tostring(err)) end
			end,
		}
	end
end

---All live-settable options, grouped by the api object that provides them.
---@return {line:extended_text_template, action:fun()?}[]
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
		local section = {}
		for _, field in ipairs(U.get_dynvars(obj)) do
			if readable(obj, field.name) then
				section[#section + 1] =
					{ line = M.generate_var_updater('  ', obj, field.name), action = prompt_for(obj, field.name) }
			end
		end
		-- an emptied section names nothing: unreadable throughout, it drops out
		if section[1] then
			---@diagnostic disable-next-line: invisible -- the api object's own path names its section
			out[#out + 1] = { line = ('%s:'):format(obj._path:upper()) }
			for _, entry in ipairs(section) do
				out[#out + 1] = entry
			end
		end
	end
	return out
end

---A custom mode's own vars, nested objects and sai overrides.
---@param mode sai.lib.remapper
---@param own_sai? boolean list the sai overrides; a sub-mode shares the root's tree, so overrides show under the root only (default true)
---@return {line:extended_text_template, action:fun()?}[]
function M:varset_lines(mode, own_sai)
	local out = {}
	-- Backed vars
	for _, var in ipairs(U.get_dynvars(mode)) do
		if readable(mode, var.name) then
			out[#out + 1] = { line = M.generate_var_updater('  ', mode, var.name), action = prompt_for(mode, var.name) }
		end
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
		local sublines = {}
		for _, var in ipairs(sub.vars) do
			if readable(sub.obj, var.name) then
				sublines[#sublines + 1] =
					{ line = M.generate_var_updater('    ', sub.obj, var.name), action = prompt_for(sub.obj, var.name) }
			end
		end
		if sublines[1] then
			out[#out + 1] = { line = ('  %s:'):format(sub.name) }
			for _, entry in ipairs(sublines) do
				out[#out + 1] = entry
			end
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
		out[#out + 1] = { line = '  sai overrides:' }
		for _, path in ipairs(paths) do
			out[#out + 1] =
				{ line = ('    %s\t%s'):format(path, tostring(overrides[path])):gsub('\n%s*', ' '):gsub('{', '{{') }
		end
	end
	return out
end

---@param entries {line:extended_text_template, action:fun()?}[]
---@return extended_text_template[], {line:extended_text_template, action:fun()?}[]
local function split_entries(entries)
	local lines = {}
	for _, entry in ipairs(entries) do
		lines[#lines + 1] = entry.line
	end
	return lines, entries
end

function M:gen_tabs()
	local settings = self:settings_list()
	local lines, entries = split_entries(settings)
	self._tabs = { { title = 'Main API Settings', lines = lines, entries = entries } }
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
		local entries = self:varset_lines(group.root)
		for _, sub in ipairs(group.subs) do
			-- ' ' not '' - the app skips truly empty lines
			if entries[1] then entries[#entries + 1] = { line = ' ' } end
			entries[#entries + 1] = { line = ('[%s]'):format(U.pretty_name(sub._path, group.root._path)) }
			for _, entry in ipairs(self:varset_lines(sub, false)) do
				entries[#entries + 1] = entry
			end
		end
		local lines
		lines, entries = split_entries(entries)
		self._tabs[#self._tabs + 1] = {
			title = U.pretty_name(group.root._path),
			lines = lines,
			entries = entries,
		}
	end
end

help.new(M)
return M
