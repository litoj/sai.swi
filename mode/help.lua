---@diagnostic disable: invisible
---@module 'swi.mode.help'

local U = require 'swi.lib.utils'
local binds = require('swi.binds').help

-- Paging object to manage scrollable output
---@class help_pager
---@class swi.mode.help: swi.mode.custom
---@field enabled boolean
---@field pager swi.lib.pager
---@field tab integer which help tab are we on
local M = {
	super = require 'swi.mode.custom',
	_path = 'swi.mode.help',
	_persist_mode_change = true,
	auto_help = true,

	_tab = 1, ---@protected
	_active_binds = { '', { '' } }, ---@protected cache

	bind_fmt = '%20s: %s', ---Default format for keybind list and description
}

---@diagnostic disable-next-line: missing-fields
M.pager = require('swi.lib.pager').new {
	_path = M._path .. '.pager',
	_trigger = true,
	_location = 'topleft',
}

function M:new()
	M.super.new(U.new_object(self, M))
	binds(self)

	self.swi.viewer.default_scale = 'keep_width'
	self.swi.slideshow.default_scale = 'keep_width'
	self.swi.text.enabled = true
	local gspace = swi.gallery.thumb_size + swi.gallery.padding_size
	self.swi.gallery(function(g)
		g.thumb_size = gspace / 3
		g.padding_size = gspace / 3
		g.cache_limit = 0
		g.preload = false
	end)
	self.swi.eventloop.subscribe {
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
	mode = mode or swi.mode
	---@diagnostic disable-next-line: param-type-mismatch
	return ('%s%s Binds'):format(mode:sub(1, 1):upper(), mode:sub(2)), U.str_bindlist(swi[mode], fmt_str or M.bind_fmt)
end

---@return string title
---@return string[] lines
local function complete_bindlist()
	local mode_order = {}
	local mode = swi.mode
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

---@param target swi.api.proxy API object to inspect
---@return table<string,any>[] fields List of settable fields with their current values
local function discover_settable_fields(target)
	local raw_api = target.super
	local fields = {}

	for field, value in pairs(target) do
		if field:sub(1, 1) == '_' then
			local field_name = field:sub(2)
			local setter_name = 'set_' .. field_name
			local enabler_name = 'enable_' .. field_name

			-- Check if backing field has an official setter, enabler, or override
			if rawget(target, '_' .. setter_name) or raw_api[setter_name] or raw_api[enabler_name] then
				fields[#fields + 1] = { name = field_name, value = value }
			end
		end
	end

	return fields
end

---@return string title
---@return string[]
local function settings_list()
	local out = {}
	for _, swiapi in ipairs {
		swi,
		swi.text,
		swi.imagelist,
		swi.gallery,
		swi.viewer,
		swi.slideshow,
	} do
		---@diagnostic disable-next-line: cast-type-mismatch
		---@cast swiapi swi.api.proxy
		out[#out + 1] = ('%s:'):format(swiapi._path:upper())

		for _, field in ipairs(discover_settable_fields(swiapi)) do
			out[#out + 1] = ('  %s\t{%s.%s}'):format(field.name, swiapi._path, field.name)
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
		local mode = swi.mode
		self.mode = mode

		self.tab = 1

		--- 100px
		if mode ~= 'gallery' then self.swi[mode].scale = 100 / swi[mode].get_image().width end
	end

	self.pager.enabled = val
	self.super.set_enabled(self, val)
	return true
end

--- TODO: in the future: add ways to select a variable and list help and its possible values

return M:new()
