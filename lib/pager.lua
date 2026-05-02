---@diagnostic disable: invisible
---@module 'swi.lib.pager'

local e = swi.eventloop
local backer = require 'swi.lib.backer'
local U = require 'swi.lib.utils'

---@class swi.lib.pager: help_pager
---Activation toggle. Configure all the preceding definition fields before enabling.
---@field enabled boolean
---@field mode appmode_t in which mode should we set the data
---@field position block_position_t where should we output to
---@field title string title in the non-scrollable header
---@field lines string[] the output to be paged
local M = {
	_trigger = false,
	_hooks = {}, ---@protected

	---@type appmode_t|false
	_mode = false, ---@protected
	---@type mode_base.text|false
	_mode_text = false, ---@private
	_enabled = false, ---@protected
	---@type block_position_t
	_position = 'topleft', ---@protected
	---@type extended_text_template[]|false
	_original_text = false, ---@protected

	_title = '', ---@protected
	---@type string[]
	_lines = {}, ---@protected

	_line = 1, ---@protected
	_page = 1, ---@protected

	_page_size = 1, ---@protected
	_total_pages = 1, ---@protected

	---@type string[]
	_last_render = {}, ---@protected
	_last_start = -1, ---@protected
	_last_end = 0, ---@protected

	size_factor = 0.75,
}

---@return swi.lib.pager
function M:new()
	if self._mode then self._mode_text = swi[self._mode].text end
	return backer.new(U.new_object(self, M))
end

function M:prepare_renderer()
	self._last_render = {}
	local out = self._last_render
	for i, v in ipairs(self._lines) do
		out[i] = v
	end
	out[#out + 1] = '' -- to keep the size and make pairs() traverse it in order - as an array
	self._last_start = 2 -- to ensure the initial sizes differ and hence will cause an update
	self._last_end = #self._lines
end

function M:render(redraw_if_unchanged)
	if not self._enabled then return end

	local lines = self._lines
	local from = self._line
	local to = math.min(#lines, from + self._page_size - 1)
	local ls, le = self._last_start, self._last_end
	if ls == from and le == to then
		if redraw_if_unchanged then self._mode_text[self._position] = self._last_render end
		return
	end

	local out = self._last_render
	out[0] = ('%s[%d/%d]'):format(self._title, self._page, self._total_pages)

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

	self._mode_text[self._position] = out
	-- this is faster but doesn't allow the lines to contain escape sequences
	-- self._mode_text.super.set_text(self._position, out)
end

---@private
function M:_restore_original()
	if self._original_text then
		self._mode_text[self._position] = self._original_text
		self._original_text = false
	end
end

---@private
function M:_on_dst_change()
	if self._mode_text then
		self._original_text = self._mode_text[self._position]
		-- nullify the text to then set it directly without any possible side-updates from prev events
		-- self._mode_text[self._position] = {}
		self:render(true)
	end
end

---@private
---Update the renderer with minimum work.
---@param resize boolean does the screen need redrawing
---@param reset boolean should we redraw all data, not just the resized amount
function M:recalibrate(resize, reset)
	if resize then
		local size = swi.text.size
		local spacing = swi.text.line_spacing
		local linepx = math.floor(spacing * size) + size * M.size_factor
		local height = swi.get_window_size().height
		self._page_size = math.floor(height / linepx) - 1 -- -1 for header
	end

	if resize or reset then
		self._total_pages = math.max(1, math.ceil(#self._lines / self._page_size))
		self._page = math.ceil((self._line - 1) / self._page_size) + 1
	end

	if reset then self:prepare_renderer() end

	self:render(true)
end

---Make multiple changes simultaneously and render only once at the end.
---@param applicator fun(it:swi.lib.pager)
function M:bulk_change(applicator)
	if not self._enabled then return applicator(self) end
	---@type false|fun(self,val):boolean?
	local set_enabled = self.set_enabled
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
		self:recalibrate(false, true)
	else
		self.enabled = false
	end
end

---@param position block_position_t
function M:set_position(position)
	self:_restore_original()
	self._position = position
	self:_on_dst_change()
	return false
end

---@param title string
function M:set_title(title)
	self._title = title
	self:render()
end

---@param lines string[]
function M:set_lines(lines)
	self._lines = lines
	if self._enabled then self:recalibrate(false, true) end
	return false
end

---@param linenr integer
function M:set_line(linenr)
	if #self._lines == 0 then return false end
	--- sets max to the beginning of last page
	-- self._line = math.max(1, math.min(self._page_size * (self._total_pages - 1) + 1, linenr))
	--- sets max to leave max 1 line empty at the end
	self._line = math.max(1, math.min(#self._lines - self._page_size + 2, linenr))
	self._page = math.ceil((self._line - 1) / self._page_size) + 1
	self:render()
	return false
end

---@param pagenr integer
function M:set_page(pagenr)
	self:set_line((pagenr - 1) * self._page_size + 1)
	return false
end

---@param mode appmode_t
function M:set_mode(mode)
	self:_restore_original()
	self._mode = mode
	self._mode_text = swi[mode].text
	self:_on_dst_change()
	return false
end

function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then
		if not self._mode then self.mode = swi.mode end
		self:_on_dst_change()
		self._enabled = true
		self:recalibrate(true, true)

		-- Listen for WinResized and OptionSet updates to recalculate per_page and re-render pager
		local function recal(e) self:recalibrate(true, false) end
		self._hooks = {
			e.subscribe {
				event = 'WinResized',
				callback = recal,
			},
			e.subscribe {
				event = 'OptionSet',
				pattern = { 'swi.text.size', 'swi.text.line_spacing' },
				callback = recal,
			},
		}
	else
		self._enabled = false
		for _, v in ipairs(self._hooks) do
			e.unsubscribe { id = v }
		end

		self:_restore_original()
	end
	return false
end

return M
