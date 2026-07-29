---@diagnostic disable: invisible
---@module 'sai.mode.help'

local U = require 'sai.lib.utils'
local binds = require('sai.binds').help

-- Paging object to manage scrollable output
---@class help_pager
---@class sai.mode.help: sai.mode.custom
---@field enabled boolean
---@field pager sai.lib.pager
---@field tab integer which help tab are we on
local M = {
	super = require 'sai.mode.custom',
	_path = 'sai.mode.help',
	_persist_mode_change = true,
	auto_help = true,

	_tab = 1, ---@protected
	_active_binds = { '', { '' } }, ---@protected cache

	bind_fmt = '%20s: %s', ---Default format for keybind list and description
}

---@diagnostic disable-next-line: missing-fields
M.pager = require('sai.lib.pager').new {
	_path = M._path .. '.pager',
	_trigger = true,
	_location = 'topleft',
}

function M:new()
	M.super.new(U.new_object(self, M))
	binds(self)

	self.sai.viewer.default_scale = 'keep_width'
	self.sai.slideshow.default_scale = 'keep_width'
	self.sai.text.enabled = true
	local gspace = sai.gallery.thumb_size + sai.gallery.padding_size
	---@diagnostic disable-next-line: param-type-mismatch
	self.sai.gallery(function(g) ---@param g sai.gallery
		g.thumb_size = gspace / 3
		g.padding_size = gspace / 3
		g.cache_size = 0
		g.preload = false
	end)
	self.sai.eventloop.subscribe {
		event = 'ModeChanged',
		callback = function(ev)
			self.mode = ev.mode
			self:set_tab(self._tab) -- regenerate content in case we're on keybindings
		end,
	}

	return self
end

local modes = { 'gallery', 'viewer', 'slideshow' }

---@return string title
---@return string[] lines
local function mode_bindlist(mode, fmt_str)
	mode = mode or sai.mode
	---@diagnostic disable-next-line: param-type-mismatch
	return ('%s%s Binds'):format(mode:sub(1, 1):upper(), mode:sub(2)), U.str_bindlist(sai[mode], fmt_str or M.bind_fmt)
end

---@return string title
---@return string[] lines
local function complete_bindlist()
	local mode_order = {}
	local mode = sai.mode
	for _, m in ipairs(modes) do -- do all other modes except the active
		if mode ~= m then mode_order[#mode_order + 1] = m end
	end

	local out = {}
	for _, m in ipairs(mode_order) do
		local name, lines = mode_bindlist(m)
		out[#out + 1] = ('%s: %d bindings'):format(name, #lines)
		for _, line in ipairs(lines) do
			out[#out + 1] = '  ' .. line
		end
	end

	return 'All Binds', out
end

---@param wrapper sai.api.proxy API object to inspect
---@return table<string,any>[] fields List of settable fields with their current values
local function discover_settable_fields(wrapper)
	local backed
	for k, v in pairs(wrapper.super) do
		if type(k) == 'userdata' then
			backed = v
			break
		end
	end
	if not backed then backed = {} end
	local fields = {}

	for backer, value in pairs(wrapper) do
		if backer:sub(1, 1) == '_' then
			local field = backer:sub(2)

			-- Check if backing field has an official setter, enabler, or override
			if rawget(wrapper, 'set' .. backer) or backed[field] then
				fields[#fields + 1] = { name = field, value = value }
			end
		end
	end

	return fields
end

---@return string title
---@return string[]
local function settings_list()
	local out = {}
	for _, wrapper in ipairs {
		sai,
		sai.text,
		sai.imagelist,
		sai.gallery,
		sai.viewer,
		sai.slideshow,
	} do
		out[#out + 1] = ('%s:'):format(wrapper._path:upper())

		for _, field in ipairs(discover_settable_fields(wrapper)) do
			out[#out + 1] = ('  %s\t{%s.%s}'):format(field.name, wrapper._path, field.name)
		end
	end

	M.pager.escaping = true
	return 'Settings', out
end

local tab_generators = { function() return unpack(M._active_binds) end, settings_list, complete_bindlist }
function M:set_tab(idx)
	self._tab = (idx - 1) % #tab_generators + 1
	self.pager:bulk_change(function(pager)
		M.pager.escaping = false
		local name, lines = tab_generators[self._tab]()
		pager.title = ('[Help %d/%d]: %s\t'):format(self._tab, #tab_generators, name)
		pager.lines = lines
		pager.line = 1
	end)
	return true
end

function M:set_mode(mode)
	self._active_binds = { mode_bindlist(mode) }
	self.pager.mode = mode
	M.super.set_mode(self, mode)
	return false
end

function M:set_enabled(val)
	if val == self._enabled then return true end
	if val then
		local mode = sai.mode
		self.mode = mode

		self.tab = 1

		--- 100px
		if mode ~= 'gallery' then self.sai[mode].scale = 100 / sai[mode].get_image().width end
	end

	self.pager.enabled = val
	self.super.set_enabled(self, val)
	return true
end

--- TODO: in the future: add ways to select a variable and list help and its possible values

return M:new()
