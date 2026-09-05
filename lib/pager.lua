---@diagnostic disable: invisible
---@module 'sai.lib.pager'

local backer = require 'sai.lib.backer'
local reconfigurer = require 'sai.lib.reconfigurer'
local U = require 'sai.lib.utils'

---@class sai.lib.pager: sai.lib.remapper
---Activation toggle. Configure all the preceding definition fields before enabling.
---@field page integer
---@field page_size integer Readonly - useful to advance by all visible lines instead of fixed page
---@field total_pages integer Readonly
---@field line integer
-- setup options
---@field location block_position_t where should we output to
---@field title string title in the non-scrollable header
---@field lines extended_text_template[] the output to be paged, always processed as text layer templates
---@field max_height number|integer max winheight to take up - 0-1 for percentage, >1 for line count
---@field sai_text sai.lib.reconfigurer our text override: writes the content through it, it restores the original blocks with itself
local M = {
	_trigger = false,

	-- Live config
	_enabled = false, ---@protected
	---@see sai.lib.pager.location
	---@type block_position_t
	_location = 'topleft', ---@protected

	-- Visible state
	_title = '', ---@protected
	---@type extended_text_template[]
	_lines = {}, ---@protected
	_line = 1, ---@protected
	_page = 1, ---@protected
	_max_height = 1, ---@protected

	_page_size = 1, ---@protected
	_total_pages = 1, ---@protected

	-- Private state
	---@type string[]
	_last_render = {}, ---@private
	_last_start = -1, ---@private
	_last_end = 0, ---@private

	size_factor = 0.75,
}

---@return sai.lib.pager
function M:new()
	-- Listen for WinResized and OptionSet updates to recalculate per_page and re-render pager
	local function recal(_) self:_recalibrate(true, false) end
	self.eventloop = reconfigurer.new_evloop()
	self.eventloop {
		{
			event = 'WinResized',
			callback = recal,
		},
		{
			event = 'OptionSet',
			pattern = { 'sai.text.size', 'sai.text.line_spacing' },
			callback = recal,
		},
		{
			-- appmode changes: bracket our text override around the flip so the
			-- blocks restore into the old mode and re-blank into the new one.
			-- Needed only while a standalone display holds the pager up: the help
			-- mode brackets its own pager through enable/disable, and then this
			-- hook no-ops.
			event = { 'ModeChangedPre', 'ModeChanged' },
			callback = function(ev)
				if ev.event == 'ModeChangedPre' then
					if not self._enabled then return end
					self.sai_text(false) -- the vars restore the blocks into the old mode
				elseif self._enabled then
					self.sai_text(true) -- re-blank the new mode's blocks
					self:render(true)
				end
			end,
		},
	}

	-- the pager owns the text layer: locations and the enable/disable, nothing else
	self.sai_text = reconfigurer.new { super = sai.text }
	self.sai_text.enabled = true

	return backer.new(U.new_object(self, M))
end

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
	if self._total_pages > 1 then
		out[0] = ('%s[Page %d/%d]'):format(self._title, self._page, self._total_pages)
	else
		out[0] = self._title:gsub('\t$', '')
	end
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

	-- the one write path: through our override, so the original block stays
	-- tracked for the restore and the templates always get processed
	self.sai_text[self._location] = out
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
---@param lines extended_text_template[]
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
	self._max_height = height
	self:_recalibrate(true, false)
end

--- Setup handlers

---@protected
---@param val block_position_t
function M:set_location(val)
	if val == self._location then return false end
	self:_on_dst_change(val)
	return true
end

---@private
---@param loc block_position_t
function M:_on_dst_change(loc)
	-- release the old location's var: its restore puts the original block back
	if self._enabled and loc ~= self._location then self.sai_text[self._location] = nil end

	self._location = loc

	if self._enabled then self:render(true) end
end

---@protected
---@param val boolean
function M:set_enabled(val)
	if val == self._enabled then return end

	if val then
		self.sai_text(true) -- the layer up first: the block clearing must precede our renders
		self:_recalibrate(true, true)
	end
	self._enabled = val
	self.eventloop(val)
	if val then self:_on_dst_change(self._location) end
	if not val then self.sai_text(false) end -- the vars restore the blocks

	return true
end

return M
