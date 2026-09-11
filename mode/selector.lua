---@module 'sai.mode.selector'

local U = require 'sai.lib.utils'
local binds = require 'sai.binds'
local mouse_box = require 'sai.bridge.mouse_box'

---Select lines; confirm selected or the line item via result().
---@class sai.mode.selector<I>: sai.lib.pager
---@field lines? I[] the selectable data (readonly - use set_lines to replace)
---@field line? integer 1-based index of the current line
---@field single_select? boolean single-select mode: no marking, the current line is the selection
---@field selected? integer[] ordered indexes of the selected items (readonly - use select/unselect/set_selected)
---@field scroll_ahead? number follow margin: 0 at edge, 0<x<1 page fraction, >=1 line count
---@field line_fmt? fun(selector:sai.mode.selector<I>, item:I, idx:integer):string paints one row; the cursor renders alone, the rest plain with an optional selected mark
---@field on_confirm? fun(self:sai.mode.selector<I>, result:I|I[]|false):boolean?|false final hook; `false` in reports an explicit abort
---@field _verdict? 0|1|-1 confirm state: 0 pending, 1 confirmed, -1 aborted
local M = {
	super = require 'sai.lib.pager',
	_path = 'sai.mode.selector',

	-- a real mode again: the pager base's machinery defaults were for
	-- pure display components
	component = false,
	persist_mode_change = false,

	-- Public, changeable at any time
	single_select = false,

	-- Selection state
	_line = 1,
	---@type integer[]
	_selected = {},
	---@type {[integer]:boolean}
	_selected_idx = {},
	_scroll_ahead = 0.5,

	_verdict = 0,
}
setmetatable(M, { __index = M.super })

---The single row hook, set at creation: the marks read the live state off self.
---A swap after rows exist leaves their paint stale.
function M:line_fmt(item, idx)
	if idx == self._line then return '> ' .. tostring(item) end
	local line = tostring(item)
	if self._selected_idx[idx] then line = '* ' .. line end
	return line
end

---@generic I
---@param self sai.mode.selector<I>
---@param result I|I[]|false success payload, or `false` on explicit abort
---@return boolean? closing verdict
---@diagnostic disable-next-line: unused-local
function M:on_confirm(result) end

---Build confirmation payload; overridable for a richer result.
---@generic I
---@param self sai.mode.selector<I>
---@return I|I[]? selected items in selection order, the line item otherwise; falsy when there is nothing to confirm
function M:result()
	if self.single_select then return self.lines[self.line] end
	if #self.selected > 0 then
		local out = {}
		for _, idx in ipairs(self.selected) do
			out[#out + 1] = self.lines[idx]
		end
		return out
	end
	return self.lines[self.line]
end

---Create a selection mode; config merges over class defaults.
---@generic I
---@return sai.mode.selector<I>
function M:new()
	U.new_object(self, M)
	-- the pager base builds the tree and the backer wrap
	M.super.new(self)

	binds.selector(self)

	return self
end

---@protected
---@generic I
---@type fun(self: sai.mode.selector<I>, lines: I[]):false
function M:set_lines(lines)
	local selected, si = {}, {}
	for _, idx in ipairs(self._selected) do
		if idx <= #lines then
			selected[#selected + 1] = idx
			si[idx] = true
		end
	end
	self._selected, self._selected_idx = selected, si
	self._line = math.max(1, math.min(#lines, self._line))

	M.super.set_lines(self, lines)
	self:_sync_scroll()
	return false
end

---@protected
function M:set_line(idx)
	if #self._lines == 0 then return false end
	local prev = self._line
	self._line = math.max(1, math.min(#self._lines, idx))
	self:_sync_scroll()
	self._lines:touch(prev, self._line) -- the cursor moved between the rows
	self:render(true)
	return false
end

---@private
---Sync the scroll offset with the current line.
---The window moves only when the line exits the margin band.
function M:_sync_scroll()
	local ps = self._page_size
	if self._location == 'status' then
		self.scroll = self._line
		return
	end
	if #self._lines <= ps then return end
	-- the line exits the band only past the margin: window snaps then
	local m = self._scroll_ahead < 1 and math.floor(self._scroll_ahead * (ps - 1)) or self._scroll_ahead
	m = math.max(0, math.min(math.floor((ps - 1) / 2), m))
	local top = self._scroll
	local rel = self._line - top
	if rel < m then
		top = self._line - m
	elseif rel > ps - 1 - m then
		top = self._line - (ps - 1 - m)
	end
	top = math.max(1, math.min(#self._lines - ps + 2, top))
	if top ~= self._scroll then self.scroll = top end
end

---@protected
---The follow margin rides along: the line moves with the window, not free.
function M:set_scroll_ahead(val)
	self._scroll_ahead = val
	local before = self._scroll
	self:_sync_scroll()
	local delta = self._scroll - before
	if delta ~= 0 then self.line = self._line + delta end
	return false
end

---@protected
---@type fun(self: sai.mode.selector, list: integer[]):false
function M:set_selected(list)
	local prev = self._selected_idx
	local selected, si = {}, {}
	for _, idx in ipairs(list) do
		if idx >= 1 and idx <= #self._lines and not si[idx] then
			selected[#selected + 1] = idx
			si[idx] = true
		end
	end
	self._selected, self._selected_idx = selected, si
	for idx in pairs(prev) do
		self._lines:touch(idx)
	end
	for _, idx in ipairs(selected) do
		self._lines:touch(idx)
	end
	self:render(true)
	return false
end

---@param delta integer rows to move the line by, negative to go up
function M:move(delta) self.line = self._line + delta end

---Appends last, keeping the selection order.
---@param idx? integer defaults to the line under the cursor
function M:select(idx)
	if self.single_select then return end
	idx = idx or self._line
	if idx < 1 or idx > #self._lines then return end
	if not self._selected_idx[idx] then
		self._selected_idx[idx] = true
		self._selected[#self._selected + 1] = idx
		self._lines:touch(idx)
		self:render(true)
	end
end

---The selection order of the rest is kept.
---@param idx? integer defaults to the line under the cursor
function M:unselect(idx)
	if self.single_select then return end
	idx = idx or self._line
	if not self._selected_idx[idx] then return end
	self._selected_idx[idx] = nil
	for i, v in ipairs(self._selected) do
		if v == idx then
			table.remove(self._selected, i)
			break
		end
	end
	self._lines:touch(idx)
	self:render(true)
end

---@param idx? integer defaults to the line under the cursor
function M:toggle_select(idx)
	idx = idx or self._line
	if self._selected_idx[idx] then
		self:unselect(idx)
	else
		self:select(idx)
	end
end

---Select the line under the mouse pointer, if it points into our window.
function M:select_at_mouse()
	local _, line = mouse_box.pager_line(self)
	if line then self.line = line end
end

---Children call super first. The reverse chain: each level refines the predecessor value.
---@generic I
---@param self sai.mode.selector<I>
---@param text? I|false explicit value, or nil for the current state
---@return I|I[]|false|nil payload on success, falsy when there is nothing to confirm
function M:parse_input(text)
	if text ~= nil then return text end
	return self:result()
end

---Falsy restores silently, otherwise the final hook runs and the mode disables unless it declines.
---@generic I
---@param self sai.mode.selector<I>
---@param res I|I[]|false|nil parsed payload
function M:_handle_result(res)
	if not res then return end
	self._verdict = 1
	if self:on_confirm(res) ~= false then self.enabled = false end
end

---@generic I
---@param self sai.mode.selector<I>
---@param text? I|false confirm with given value or abort
function M:confirm(text)
	-- an explicit abort is the only path reporting through on_confirm(false)
	if text == false then
		self._verdict = -1
		if self:on_confirm(false) ~= false then self.enabled = false end
		return
	end
	self:_handle_result(self:parse_input(text))
end

---@protected
---A fresh cycle starts at pending; a plain disable keeps the verdict for the host.
function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then self._verdict = 0 end
	M.super.set_enabled(self, val)

	return false
end

return M
