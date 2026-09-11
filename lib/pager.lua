---@module 'sai.lib.pager'

local U = require 'sai.lib.utils'
local fmt = require 'sai.lib.formatter'
local mouse_box = require 'sai.bridge.mouse_box'
local section = require 'sai.api.section'

---@alias text_location block_position_t|'status'

---@class sai.lib.pager<I>: sai.lib.remapper paged window over a line list
---@field page_size? integer Readonly - useful to advance by all visible lines instead of fixed page
---@field total_pages? integer Readonly
---@field scroll? integer the first visible line of the window (the scroll offset)
---@field enabled? boolean brings the text layer, the eventloop hooks and the mode side (binds, sai.modes) up and down
---@field _lines? sai.lib.formatter<I>
---@field title_fmt? fun(pager:sai.lib.pager<I>, title:string, page_block?:string):string composes the header row; `''` hides it
---@field line_fmt? fun(pager:sai.lib.pager<I>, item:I, idx:integer):string|I paints one row; a host that needs live state (a cursor, a selection) overrides this
-- setup options
---@field location? text_location
---@field title? string `''` hides it; a construction without one derives it from the last segment of `_path`, first word capitalized (`sai.mode.help_pager` -> `Help pager:\t`)
---@field lines? I[] the output to be paged: raw items, rendered through `line_fmt`
---@field status_fmt? string `[title, text]` format of the status output: `text` is the visible lines joined by newlines
---@field max_height? number|integer max winheight to take up - 0-1 for percentage, >1 for line count
local M = {
	super = require 'sai.lib.remapper',
	-- pure display by default: the host (or the user) maps binds onto it
	component = true,
	-- the host brackets its pagers through mode flips; the subscription
	-- only re-applies the (user-mapped) binds onto the new mode
	persist_mode_change = true,

	-- Live config
	_enabled = false,
	---@type text_location
	_location = 'topleft',

	-- Visible state
	-- plain field: a write repaints nothing, set the lines after it
	title = '',
	_scroll = 1,
	_page = 1,
	_max_height = 1,
	status_fmt = '%s: %s',

	_page_size = 1,
	_total_pages = 1,

	-- plain field, set at creation: a swap after rows exist leaves their
	-- paint stale; '' hides the row
	title_fmt = function(_, title, page_block)
		if not page_block then return (title:gsub('\t$', '')) end
		return title .. page_block
	end,

	-- plain field, set at creation: a swap after rows exist leaves their
	-- paint stale
	line_fmt = function(_, item) return item end,

	-- Private state
	_last_start = math.huge, -- the window currently on screen (none to begin)
	_last_end = 0,

	-- a per-window knob over the text scaling (the calibration default
	-- lives with the mouse geometry)
	height_factor = mouse_box.height_factor,
}

setmetatable(M, { __index = M.super })

---@return sai.lib.pager
function M:new()
	---@diagnostic disable-next-line: cast-type-mismatch
	---@cast self sai.lib.pager
	-- checked before the merge: the class default '' and the subclass
	-- defaults (completion's 'Matching:\t') must not read as user input
	if self.title == nil and self._path then
		local name = self._path:match('[^.]+$'):lower():gsub('_', ' ')
		self.title = name:sub(1, 1):upper() .. name:sub(2) .. ':\t'
	end
	U.new_object(self, M)

	-- the paint rides the line_fmt method: the dispatch picks the
	-- level's hook, the formatter's captured closure stays fixed
	local seed = self._lines
	self._lines = fmt.new {
		format = function(idx, item) return self:line_fmt(item, idx) end,
	}
	if seed and #seed > 0 then self._lines:set(seed) end

	---@diagnostic disable-next-line: param-type-mismatch
	M.super.new(self)

	-- page size follows window and font changes
	local function recal(_) self:_recalibrate(true, false) end
	self.sai.eventloop {
		{
			event = 'WinResized',
			callback = recal,
		},
		{
			event = 'OptionSet',
			pattern = { 'sai.text.size', 'sai.text.line_spacing' },
			callback = recal,
		},
	}

	-- the wheel scrolls this window over its block: the bind declares
	-- the block's code, so it follows the block wherever it moves
	self.map(
		section.key(self._location, 'ScrollUp'),
		function() self.scroll = self.scroll - 1 end,
		{ kind = 'private' }
	)
	self.map(
		section.key(self._location, 'ScrollDown'),
		function() self.scroll = self.scroll + 1 end,
		{ kind = 'private' }
	)

	return self
end

---The `[Page x/x]` title suffix for the title format; nil on a single page.
---@return string?
function M:_page_block() return self._total_pages > 1 and ('[Page %d/%d]'):format(self._page, self._total_pages) or nil end

---@private
---@return boolean
function M:_header_visible() return self.title_fmt(self, self.title, self:_page_block()) ~= '' end

---@param redraw_if_unchanged boolean? also write to the text layer when the window did not move
function M:render(redraw_if_unchanged)
	if not self._enabled then return end

	local lines = self._lines
	---@cast lines sai.lib.formatter
	local from = self._scroll
	local to = math.min(#lines, from + self._page_size - 1)
	if not redraw_if_unchanged and from == self._last_start and to == self._last_end then return end

	-- the consumer walks the table in hash order: only a dense array
	-- from 1, title first, reads back in order
	local out = {}
	if self._location == 'status' then
		-- status is one string, not one line
		lines:splice(out, 1, #lines)
	else
		local title = self.title_fmt(self, self.title, self:_page_block())
		if title ~= '' then out[#out + 1] = title end
		lines:splice(out, from, to)
	end

	self._last_start, self._last_end = from, to
	self:_write_out(out)
end

---The visible line under the pointer, or nil off the window (over its
---header or the padding). The geometry comes from the mouse box's pointer.
---@param p sai.bridge.mouse_box.pointer
---@return integer? line
function M:line_at(p)
	if not self._enabled or #self._lines == 0 then return end
	local from = self._scroll
	local visible = self._last_end - from + 1
	if visible < 1 then return end

	if self._location == 'topleft' or self._location == 'topright' then
		local y0 = p.pad + (self:_header_visible() and p.linepx or 0)
		local rel = math.floor((p.m.y - y0) / p.linepx) + 1
		if rel < 1 or rel > visible then return end
		return from + rel - 1
	end
	-- a bottom-anchored window (a bottom corner or the status): rel 0 = the last line
	local rel = math.floor((p.ws.height - p.pad - p.m.y) / p.linepx)
	if rel < 0 or rel >= visible then return end
	return from + visible - 1 - rel
end

---Single write path through our override: block stays tracked, templates processed.
---@generic I
---@param self sai.lib.pager<I>
---@param out (string|I)[]
function M:_write_out(out)
	if self._location == 'status' then -- status is one string, not one line
		local parts = {}
		for i = 1, #out do
			local text = out[i]
			if type(text) ~= 'string' then text = tostring(text) end
			-- swayimg skips truly empty text: pad the row so it renders blank
			if text == '' then text = ' ' end
			parts[#parts + 1] = text
		end
		local text = table.concat(parts, '\n')
		-- the dense render may omit an empty title: compose it here
		local title = self.title_fmt(self, self.title, self:_page_block())
		local status
		if title == '' or text == '' then
			status = title ~= '' and title or text
		else
			status = self.status_fmt:format(title, text)
		end
		self.sai.text.status = status
	else
		-- swayimg skips truly empty lines: pad them so the layout holds
		for i = 1, #out do
			if out[i] == '' then out[i] = ' ' end
		end
		self.sai.text[self._location] = out
	end
end

---@private
function M:_derive_page_size()
	local height = sai.get_window_size().height
	if self._max_height <= 1 then height = height * self._max_height end
	-- the header hides on `''` from title_fmt: the window gains its line
	local rows = mouse_box.rows_in(height, self.height_factor)
	self._page_size = math.max(1, rows - (self:_header_visible() and 1 or 0))
	if self._max_height > 1 then self._page_size = math.min(self._page_size, self._max_height) end
end

---@private
function M:_clamp_window()
	self._scroll = math.max(1, math.min(self:_max_scroll(), self._scroll))
	self._total_pages = math.max(1, math.ceil(#self._lines / self._page_size))
	self._page = math.ceil((self._scroll - 1) / self._page_size) + 1
	-- a page count flip can flip the header's visibility: re-derive the
	-- page capacity once more when it did, and clamp again
	if self._location ~= 'status' then
		local prev = self._page_size
		self:_derive_page_size()
		if self._page_size ~= prev then
			self._scroll = math.max(1, math.min(self:_max_scroll(), self._scroll))
			self._total_pages = math.max(1, math.ceil(#self._lines / self._page_size))
			self._page = math.ceil((self._scroll - 1) / self._page_size) + 1
		end
	end
end

---@private
---One empty line at the end keeps the last row free.
---@return integer
function M:_max_scroll()
	return self._location == 'status' and math.max(1, #self._lines) or math.max(1, #self._lines - self._page_size + 2)
end

---@private
---Update the renderer with minimum work.
---@param resize boolean does the screen need redrawing
---@param reset boolean should we redraw all data, not just the resized amount
function M:_recalibrate(resize, reset)
	if self._location == 'status' then
		-- status is one string, not one line
		self._page_size = math.huge
	elseif resize then
		self:_derive_page_size()
	end

	if resize or reset then self:_clamp_window() end

	self:render(true)
end

---@protected
---@generic I
---@type fun(self: sai.lib.pager<I>, lines: I[]):false
function M:set_lines(lines)
	self._lines:set(lines)
	if self._enabled then self:_recalibrate(false, true) end
	return false
end

---@protected
---Move the window so that `linenr` becomes the first visible line.
function M:set_scroll(linenr)
	if #self._lines == 0 then return false end
	self._scroll = math.max(1, math.min(self:_max_scroll(), linenr))
	self._page = math.ceil((self._scroll - 1) / self._page_size) + 1
	self:render()
	return true
end

---@protected
function M:set_max_height(height)
	self._max_height = height
	self:_recalibrate(true, false)
	return false
end

---@protected
---@type fun(self: sai.lib.pager, val: text_location):boolean
function M:set_location(val)
	if val == self._location then return false end
	self:_on_dst_change(val)
	return true
end

---@private
---@param loc text_location
function M:_on_dst_change(loc)
	if loc ~= self._location then self.sai.text[self._location] = nil end

	local old = self._location
	self._location = loc

	-- binds declared for the window's block follow the window: they
	-- carry its code and re-declare the new block's
	if loc ~= old then
		-- section.key of an empty bind is the code prefix ('TL+')
		local was, now = section.key(old, ''), section.key(loc, '')
		local moves = {}
		for b, cfg in pairs(self._mappings) do
			if b:sub(1, #was) == was then moves[#moves + 1] = { b, now .. b:sub(#was + 1), cfg } end
		end
		for _, move in ipairs(moves) do
			self:_setmap(move[1], nil)
			self:_setmap(move[2], move[3])
		end
	end

	if self._enabled then self:_recalibrate(true, false) end
end

---@protected
---The remapper chain carries the mode side; this adds the window side.
---@type fun(self: sai.lib.pager, val: boolean):false
function M:set_enabled(val)
	if val == self._enabled then return false end
	M.super.set_enabled(self, val)
	if val then
		self:_recalibrate(true, true)
		self:_on_dst_change(self._location)
	end

	return false
end

return M
