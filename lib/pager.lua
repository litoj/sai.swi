---@diagnostic disable: invisible
---@module 'sai.lib.pager'

local e = sai.eventloop
local backer = require 'sai.lib.backer'
local U = require 'sai.lib.utils'

---@class sai.lib.pager
---Activation toggle. Configure all the preceding definition fields before enabling.
---@field page integer
---@field page_size integer Readonly - useful to advance by all visible lines instead of fixed page
---@field total_pages integer Readonly
---@field line integer
-- setup options
---@field enabled boolean
---@field mode appmode_t|false in which mode should we set the data (false to use current mode)
---@field location block_position_t where should we output to
---@field title string title in the non-scrollable header
---@field lines string[] the output to be paged
---@field max_height number|integer max winheight to take up - 0-1 for percentage, >1 for line count
local M = {
	_trigger = false,

	-- Live config
	escaping = false, ---Should lines be checked for sai.text escape sequences or set as pure text
	_enabled = false, ---@protected
	---@see sai.lib.pager.mode
	---@type appmode_t|false
	_mode = false, ---@protected
	---@see sai.lib.pager.location
	---@type block_position_t
	_location = 'topleft', ---@protected

	-- Visible state
	_title = '', ---@protected
	---@type string[]
	_lines = {}, ---@protected
	_line = 1, ---@protected
	_page = 1, ---@protected
	_max_height = 1, ---@protected

	_page_size = 1, ---@protected
	_total_pages = 1, ---@protected

	-- Private state
	_hooks = {}, ---@private
	---@type mode_base.text|false
	_mode_text = false, ---@private
	---@type extended_text_template[]|false
	_original_text = false, ---@private
	---@type string[]
	_last_render = {}, ---@private
	_last_start = -1, ---@private
	_last_end = 0, ---@private

	size_factor = 0.75,
}

---@return sai.lib.pager
function M:new() return backer.new(U.new_object(self, M)) end

---@private
function M:_prepare_renderer()
	self._last_render = {}
	local out = self._last_render
	for i, v in ipairs(self._lines) do
		out[i] = v
	end
	out[#out + 1] = '' -- to keep the size and make pairs() traverse it in order - as an array
	self._last_start = 2 -- to ensure the initial sizes differ and hence will cause an update
	self._last_end = #self._lines
end

---@protected
function M:render(redraw_if_unchanged)
	if not self._enabled then return end

	local lines = self._lines
	local from = self._line
	local to = math.min(#lines, from + self._page_size - 1)
	local ls, le = self._last_start, self._last_end

	local out = self._last_render
	out[0] = ('%s[%d/%d]'):format(self._title, self._page, self._total_pages)
	if ls ~= from or le ~= to then
		if from > ls then
			local _end = math.min(from - 1, le)
			for i = ls, _end do
				out[i] = nil
			end
			self._last_start = from
			if le > from then from = le + 1 end
		elseif ls < to then
			for i = from, ls - 1 do
				out[i] = lines[i]
			end
			self._last_start = from
			from = le + 1
		else
			self._last_start = from
		end

		if to < le then
			local start = math.max(to + 1, ls)
			for i = start, le do
				out[i] = nil
			end
			self._last_end = to
			if ls <= to then to = ls - 1 end
		elseif le > from then
			for i = le + 1, to do
				out[i] = lines[i]
			end
			self._last_end = to
			to = ls - 1
		else
			self._last_end = to
		end

		for i = from, to do
			out[i] = lines[i]
		end
	elseif not redraw_if_unchanged then
		return
	end

	if self.escaping then
		self._mode_text[self._location] = out
	else -- this is faster but doesn't allow the lines to contain escape sequences
		---@diagnostic disable-next-line: undefined-field
		self._mode_text.super.set_text(self._location, out)
	end
end

---@private
---Update the renderer with minimum work.
---@param resize boolean does the screen need redrawing
---@param reset boolean should we redraw all data, not just the resized amount
function M:_recalibrate(resize, reset)
	if resize then
		local size = sai.text.size
		local spacing = sai.text.line_spacing
		local linepx = math.floor(spacing * size) + size * M.size_factor
		local height = sai.get_window_size().height
		if self._max_height <= 1 then height = height * self._max_height end
		self._page_size = math.floor(height / linepx) - 1 -- -1 for header
		if self._max_height > 1 then self._page_size = math.min(self._page_size, self._max_height) end
	end

	if resize or reset then
		self._total_pages = math.max(1, math.ceil(#self._lines / self._page_size))
		self._page = math.ceil((self._line - 1) / self._page_size) + 1
	end

	if reset then self:_prepare_renderer() end

	self:render(true)
end

---Make multiple changes simultaneously and render only once at the end.
---@param applicator fun(it:sai.lib.pager)
function M:bulk_change(applicator)
	if not self._enabled then return applicator(self) end
	---@type false|fun(self,val):boolean?
	local set_enabled = self.set_enabled
	---@diagnostic disable-next-line: redefined-local
	self.set_enabled = function(self, val)
		if val == false then
			self.set_enabled = set_enabled
			set_enabled = false
		end
		return false
	end

	self._enabled = false
	applicator(self)
	self._enabled = true
	if set_enabled then
		self.set_enabled = set_enabled
		self:_recalibrate(false, true)
	else
		self.enabled = false
	end
end

---@protected
---@param title string
function M:set_title(title)
	self._title = title
	self:render(true)
end

---@protected
---@param lines string[]
function M:set_lines(lines)
	self._lines = lines
	if self._enabled then self:_recalibrate(false, true) end
	return false
end

---@protected
---@param linenr integer
function M:set_line(linenr)
	if #self._lines == 0 then return false end
	--- sets max to the beginning of last page
	-- self._line = math.max(1, math.min(self._page_size * (self._total_pages - 1) + 1, linenr))
	--- sets max to leave max 1 line empty at the end
	self._line = math.max(1, math.min(#self._lines - self._page_size + 2, linenr))
	self._page = math.ceil((self._line - 1) / self._page_size) + 1
	self:render()
	return true
end

---@protected
---@param pagenr integer
function M:set_page(pagenr) return self:set_line((pagenr - 1) * self._page_size + 1) end

---@protected
---@param height integer
function M:set_max_height(height)
	self._height = height
	self:_recalibrate(true, false)
end

--- Setup handlers

---@protected
---@param mode appmode_t
function M:set_mode(mode)
	self:_on_dst_change(mode, self._location)
	return false
end

---@protected
---@param val block_position_t
function M:set_location(val)
	if val == self._location then return false end
	self:_on_dst_change(self._mode, val)
	return true
end

---@private
---@param mode appmode_t
---@param loc block_position_t
function M:_on_dst_change(mode, loc)
	if self._original_text then
		self._mode_text[self._location] = self._original_text
		self._original_text = false
	end

	self._mode = mode
	self._location = loc

	if self._enabled then
		self._mode_text = sai[mode or sai.mode].text
		self._original_text = self._mode_text[self._location]
		self:render(true)
	end
end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then
		self:_recalibrate(true, true)
		self._enabled = true
		self:_on_dst_change(self._mode, self._location)

		-- Listen for WinResized and OptionSet updates to recalculate per_page and re-render pager
		local function recal(_) self:_recalibrate(true, false) end
		self._hooks = {
			e.subscribe {
				event = 'WinResized',
				callback = recal,
			},
			e.subscribe {
				event = 'OptionSet',
				pattern = { 'sai.text.size', 'sai.text.line_spacing' },
				callback = recal,
			},
		}
	else
		self._enabled = false
		for _, v in ipairs(self._hooks) do
			e.unsubscribe { id = v }
		end

		self:_on_dst_change(self._mode, self._location)
	end
	return true
end

return M
