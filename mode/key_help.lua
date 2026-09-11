---@module 'sai.mode.key_help'

local U = require 'sai.lib.utils'
local X = require 'sai.bridge.xkb'
local reg = require 'sai.lib.registry'
local help = require 'sai.mode.help'

---Keybinds help over the help window.
---@class sai.mode.key_help: sai.mode.help
---@field bind_fmt string
---@field short_binds boolean show binds in the short form (C-x, A-y…) instead of full xkb names
---@field list 'effective'|'all' what to list per layer: the binds it currently owns, or all of its declarations
local M = {
	_path = 'sai.mode.key_help',
	_location = 'topright', -- topleft stays the var help window
	bind_fmt = '%s\t%s',

	_short_binds = false,
	---@type 'effective'|'all'
	_list = 'effective',
}

---The display options drive every visible list: the active modes' corner
---displays and, while the overlay runs, the open tab.
function M:set_list(val, idx)
	self['_' .. idx] = val
	for i = 2, #sai.modes do
		local layer = sai.modes[i] ---@type sai.lib.remapper
		local display = layer.help_pager
		if display and display.enabled then layer:render_help_pager() end
	end
	if self._enabled then
		self:gen_tabs()
		self:render()
	end
end
M.set_short_binds = M.set_list

---The layer groups: one per root mode, the root leading, newest first.
---A component joins the root its `_path` extends (longest match owns it); a bindless one is pure display, a `help_pager = false` root drops its group.
---@return {binder:sai.lib.remapper, root:boolean}[][]
local function layer_groups()
	local roots, subs = {}, {}
	for i = 2, #sai.modes do
		local binder = sai.modes[i]
		---@diagnostic disable-next-line: invisible, need-check-nil
		if not rawget(binder, 'component') then
			---@diagnostic disable-next-line: need-check-nil
			subs[binder] = {}
			roots[#roots + 1] = binder
		end
	end
	for i = 2, #sai.modes do
		local binder = sai.modes[i]
		---@diagnostic disable-next-line: invisible, need-check-nil
		if rawget(binder, 'component') then
			---@diagnostic disable-next-line: invisible, need-check-nil -- other layers' binds, listed here
			if next(binder._mappings or {}) then
				local best, blen
				for j = 2, #sai.modes do
					local r = sai.modes[j]
					---@diagnostic disable-next-line: invisible, need-check-nil
					if not rawget(r, 'component') then
						---@diagnostic disable-next-line: invisible, need-check-nil
						local rpath = r._path or ''
						---@diagnostic disable-next-line: invisible, need-check-nil
						if (binder._path or ''):sub(1, #rpath + 1) == rpath .. '.' and (not blen or #rpath > blen) then
							best, blen = r, #rpath
						end
					end
				end
				if best then subs[best][#subs[best] + 1] = binder end
			end
		end
	end

	local out = {}
	for i = #roots, 1, -1 do
		local root = roots[i]
		---@diagnostic disable-next-line: need-check-nil
		if rawget(root, 'help_pager') ~= false then
			local group = { { binder = root, root = true } }
			for _, sub in ipairs(subs[root]) do
				group[#group + 1] = { binder = sub, root = false }
			end
			out[#out + 1] = group
		end
	end
	return out
end

local function ordered_layers()
	local out = {}
	for _, group in ipairs(layer_groups()) do
		for _, entry in ipairs(group) do
			out[#out + 1] = entry
		end
	end
	return out
end

---The effective binds per layer: each bind lands on exactly one tab, the
---base tab keeps the unclaimed keys.
---@return {binder:sai.lib.remapper?, _path:string, _mappings:sai.lib.keybind_processor.bindmap, root:boolean}[]
local function bindsets_effective()
	local base = sai.modes[1]
	local claimed, owned, known = {}, {}, {}
	for key, stack in pairs(reg.binds[base]) do
		for _, rec in ipairs(stack) do
			if rec.layer then known[rec.layer] = true end
		end
		local top = stack[#stack]
		local layer, cfg = top and top.layer, top and top.new
		if layer and cfg and cfg.cb then
			claimed[key] = true
			owned[layer] = owned[layer] or {}
			owned[layer][key] = cfg
		end
	end
	local base_map = {}
	for k, v in pairs(base.get_mappings()) do
		if not claimed[k] then base_map[k] = v end
	end
	local used = {}
	for _, entry in ipairs(ordered_layers()) do
		local binder = entry.binder
		local mappings = owned[binder]
		if not known[binder] then
			-- mid-flip: the registry does not know this layer yet - show its declarations
			mappings = {}
			---@diagnostic disable-next-line: invisible -- other layers' binds, listed here
			for k, v in pairs(binder._mappings) do
				if v.cb then mappings[k] = v end
			end
		end
		---@diagnostic disable-next-line: invisible
		used[#used + 1] = { binder = binder, _path = binder._path, _mappings = mappings or {}, root = entry.root }
	end
	---@diagnostic disable-next-line: invisible
	used[#used + 1] = { _path = base._path, _mappings = base_map, root = true }
	return used
end

---The 'all' listing: every layer's full _mappings; the base tab restores
---overridden keys from the bottom record's `.old` (false: never had it).
---@return {binder:sai.lib.remapper?, _path:string, _mappings:sai.lib.keybind_processor.bindmap, root:boolean}[]
local function bindsets_all()
	local base = sai.modes[1]
	local base_map = {}
	for k, v in pairs(base.get_mappings()) do
		base_map[k] = v
	end
	for key, stack in pairs(reg.binds[base]) do
		local bottom = stack[1]
		if bottom then base_map[key] = bottom.old or nil end
	end
	local used = {}
	for _, entry in ipairs(ordered_layers()) do
		local binder = entry.binder
		local mappings = {}
		---@diagnostic disable-next-line: invisible -- other layers' binds, listed here
		for k, v in pairs(binder._mappings) do
			if v.cb then mappings[k] = v end
		end
		---@diagnostic disable-next-line: invisible
		used[#used + 1] = { binder = binder, _path = binder._path, _mappings = mappings, root = entry.root }
	end
	---@diagnostic disable-next-line: invisible
	used[#used + 1] = { _path = base._path, _mappings = base_map, root = true }
	return used
end

---The bindsets as tab-shaped groups: one per root mode (newest first),
---the base mode's set closing the list.
local function bindset_groups()
	local flat = (M._list == 'all' and bindsets_all or bindsets_effective)()
	local groups, cur = {}, nil
	for _, bindset in ipairs(flat) do
		if bindset.root then
			cur = {}
			groups[#groups + 1] = cur
		end
		cur[#cur + 1] = bindset
	end
	return groups
end

---One tab from a group's bindsets: the root's binds as the list, each sub-mode's under a bracketed sub-header.
---A sub-mode without visible binds shows no section.
---@param bindsets {binder:sai.lib.remapper?, _path:string, _mappings:sai.lib.keybind_processor.bindmap, root:boolean}[]
---@return help_tab
local function group_tab(bindsets)
	local function lines_of(mappings)
		return U.str_bindlist(mappings, M.bind_fmt, M.short_binds and X.short_key_name or nil)
	end
	local tab = { title = '', lines = {} }
	local root_path
	for _, bindset in ipairs(bindsets) do
		if bindset.root then
			root_path = bindset._path
			tab.title = U.pretty_name(bindset._path)
			tab.lines = lines_of(bindset._mappings)
		else
			local lines = lines_of(bindset._mappings)
			if lines[1] then
				local tl = tab.lines
				-- ' ' not '' - the app skips truly empty lines
				if tl[1] then tl[#tl + 1] = ' ' end
				tl[#tl + 1] = ('[%s]'):format(U.pretty_name(bindset._path, root_path))
				for _, l in ipairs(lines) do
					tl[#tl + 1] = l
				end
			end
		end
	end
	return tab
end

---The tab of one mode: its binds plus its sub-modes' under sub-headers.
---@param mode sai.lib.remapper
---@return help_tab
function M.mode_tab(mode)
	for _, group in ipairs(bindset_groups()) do
		if group[1].binder == mode then return group_tab(group) end
	end
	return { title = U.pretty_name(mode._path), lines = {} }
end

---One tab per active root mode: its binds as one list, then a sub-header
---and the binds of each sub-mode; the base mode's tab closes the set.
function M:gen_tabs()
	self._tabs = {}
	for _, group in ipairs(bindset_groups()) do
		self._tabs[#self._tabs + 1] = group_tab(group)
	end
end

---Cycle the F1 overlay: off -> effective listing -> all -> off.
function M.cycle()
	if not M.enabled then
		M.list = 'effective' -- start the cycle over; nothing shows yet
		M.enabled = true -- renders on its own
	elseif M.list == 'effective' then
		M.list = 'all' -- the setter re-renders the open tab
	else
		M.enabled = false
	end
end

help.new(M)
return M
