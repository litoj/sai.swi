---@diagnostic disable: invisible
---@module 'sai.mode.input'

local U = require 'sai.lib.utils'
local X = require 'sai.bridge.xkb'
local utf8 = require 'sai.bridge.utf8'
local binds = require 'sai.binds'

---A text input mode that captures key events for text entry.
---Configure hooks and parameters before enabling.
---All positions are in characters (utf8-aware); the text itself is always valid utf8.
---@class sai.mode.input: sai.lib.remapper
---@field text string state of user input (always valid utf8)
---@field col integer cursor position (1-based insert position, in characters)
---@field line integer cursor line (1-based)
---@field location block_position_t|'status' where should we output to
---@field visual integer|false position of the selection marker (like `col`)
---@field map fun(bind:string|string[],key_or_fn:string|fun(self:self),desc:string?)
---@field protected confirmed boolean? has input been confirmed or aborted, useful for disabling logic
local M = {
	super = require 'sai.lib.remapper',
	_trigger = false, -- disable trigger to ensure text is visible even when set to `status`
	map_filter = function(b)
		return not b:find '%u[%l%d]*$' and not b:find('Ctrl', 1, true) and not b:find('Alt', 1, true)
	end,

	-- Public, changeable at any time
	---hook called on every text change
	on_text_change = false, ---@type fun(self:sai.mode.input,text:string)|false

	-- Configuration (set before enabling)
	_prompt = false, ---@type string|false optional prompt prefix
	_cursor_icon = '▎',

	-- Live config
	---@type block_position_t|'status'
	_location = 'status', ---@protected

	-- Visible state
	_text = '', ---@protected must use the setter, otherwise column is out of whack
	_col = 1, ---@protected 1-based
	---@type integer|false indicates end of selection when available (1-based)
	_visual = false, ---@protected

	-- TODO: make available as U.input that users can call on-demand with custom prompt
	-- that would be just for the `status` location
	-- TODO: convert to using lines and pager and create a textbox for line scrolling
	-- Private state
	---@type fun(lines:string[])|fun(status:string)|false
	_raw_update = false, ---@private armed writer: block renders go through our sai.text override
}
setmetatable(M, { __index = M.super })

---Default confirmation behaviour, meant for overriding
---@param result string|false
---@return boolean? disable_mode should mode be disabled (default: true)
---@diagnostic disable-next-line: unused-local
function M:on_confirm(result) end

---@param fn string|fun(self:self)
function M:_rawmap(b, cfg, fn)
	-- minimize number of overrides
	if not self._enabled or (not cfg.cb and not self._mode_api._mappings[b]) then return end

	M.super._rawmap(self, b, cfg, fn)
end

---@return sai.mode.input
function M:new()
	U.new_object(self, M)
	M.super.new(self)

	local maps = self._mappings
	for i = 65, 90 do
		local uc = string.char(i)
		maps['Shift+' .. string.char(i + 32)] = {
			cb = function() self._on_unassigned(uc) end,
			trace = self._path,
			_traced = true,
			kind = 'input',
		}
	end
	binds.input(self)

	self._on_unassigned = function(bind)
		local kind, ch = X.process_next_input(bind)
		if kind == 'command' then
			self._api_on_unassigned(bind)
		elseif kind == 'text' then
			self:insert(ch)
		end
	end

	return self
end

---@protected
---Render the input text with cursor to the configured output
function M:render()
	if not self._enabled then return end

	local display
	if self._visual then
		local from, to = self._col, self._visual
		local f_ic, t_ic = self._cursor_icon, '|'
		if from > to then
			from, to = to, from
			f_ic, t_ic = t_ic, f_ic
		end

		display = table.concat {
			utf8.sub(self._text, 1, from - 1),
			f_ic,
			utf8.sub(self._text, from, to - 1),
			t_ic,
			utf8.sub(self._text, to),
		}
	else
		display = ('%s%s%s'):format( --
			utf8.sub(self._text, 1, self._col - 1),
			self._cursor_icon,
			utf8.sub(self._text, self._col)
		)
	end

	if self._location == 'status' then
		self._raw_update(self._prompt and self._prompt .. display or display)
	else
		local lines = { self._prompt }
		for l in display:gmatch '([^\n]*)\n?' do
			lines[#lines + 1] = l
		end
		self._raw_update(lines)
	end
end

---Insert a string at the cursor position
---@param text string
function M:insert(text)
	-- coerce invalid bytes to '?': their presence would make utf8.len() return nil and crash the cursor math
	text = utf8(text)
	local from, to = self._col, self._visual or self._col
	self._visual = false
	if from > to then
		from, to = to, from
	end

	self._text = utf8.sub(self._text, 1, from - 1) .. text .. utf8.sub(self._text, to)
	self._col = from + utf8.len(text)

	if self.on_text_change then self:on_text_change(self._text) end
	self:render()
end

---@param from? integer 1-based position, leave unspecified to use visual selection
---@param to? integer defaults to `from`, 1-based position
function M:delete(from, to)
	if not from and not to then
		if self._visual < self._col then
			from, to = self._visual, self._col - 1
		else
			from, to = self._col, self._visual - 1
		end
	end

	if not to then to = from end
	if from > to then
		from, to = to, from
	end

	if from == 0 then return end
	if from < 0 or to <= 0 then error 'Only positive indexes allwed in delete()' end
	self._text = utf8.sub(self._text, 1, from - 1) .. utf8.sub(self._text, to + 1)
	if self._visual then self._visual = false end

	local oc = self._col
	if oc > from then self._col = oc > to and oc - to + from - 1 or from end

	if self.on_text_change then self:on_text_change(self._text) end
	self:render()
end

---@param text? string|false confirm with given text or abort with `false`
function M:confirm(text)
	rawset(self, 'confirmed', text ~= false)
	if text == false then self.text = '' end
	if self:on_confirm(text ~= false and (text or self._text) or false) ~= false then self:set_enabled(false) end
end

---This is an alias to the preferred `self:confirm(false)`
---@see sai.mode.input.confirm
function M:abort() return self:confirm(false) end

---Get the content as lines with their indexes to the text.
---@return {line:string,from:integer,to:integer}[] list of lines and their (char) positions
function M:get_lines_info()
	local lines = {}
	local i = 1
	for l in self._text:gmatch '([^\n]*)\n?' do
		lines[#lines + 1] = { line = l, from = i, to = i + utf8.len(l) }
		i = i + utf8.len(l) + 1
	end
	return lines
end

---@return {line:string,from:integer,to:integer}
function M:get_current_line_info()
	local lines = self:get_lines_info()
	for _, l in ipairs(lines) do
		if self._col <= l.to then return l end
	end

	sai.log '"._text" has been set directly! Please use the public field ".text"'
	self.col = utf8.len(self._text)
	return lines[#lines]
end

---@protected
---Updates and renders text, moving the cursor to stay relative to text following it
---@param val string
function M:set_text(val)
	-- coerce invalid bytes to '?': their presence would make utf8.len() return nil and crash the cursor math
	val = utf8(val)
	local len, oldlen = utf8.len(val), utf8.len(self._text)
	if self._visual then self._visual = math.min(self._visual, len + 1) end
	if self._col > len or self._col > oldlen then
		self._col = len + 1
	else
		-- text was inserted before the cursor: keep the cursor relative to the text following it
		local suffix = utf8.sub(self._text, self._col)
		if #suffix <= #val and val:sub(-#suffix) == suffix then self._col = len - (oldlen - self._col) end
	end
	self._text = val

	if self._enabled and self.on_text_change then self:on_text_change(self._text) end
	self:render()
	return false
end

---@protected
function M:set_visual(val)
	self._visual = val and math.max(1, math.min(utf8.len(self._text) + 1, val)) or val
	if self._enabled then self:render() end
	return false
end

---@protected
function M:set_col(val)
	self._col = math.max(1, math.min(utf8.len(self._text) + 1, val))
	if self._enabled then self:render() end
	return false
end

---@protected
---@param val integer
function M:set_line(val)
	local lines = self:get_lines_info()
	for _, l in ipairs(lines) do
		if self._col <= l.to then
			lines = lines[math.max(1, math.min(#lines, val))]
			self.col = lines.from + math.min(self._col - l.from, lines.to - 1)
			break
		end
	end
	return false
end

---@protected
function M:get_line()
	local lines = self:get_lines_info()
	for i, l in ipairs(lines) do
		if self._col <= l.to then return i end
	end
end

---@param val block_position_t|'status'
function M:set_location(val)
	if val == self._location then return false end
	self:_on_dst_change(val)
	return false
end

---@private
---@param loc block_position_t|'status'
function M:_on_dst_change(loc)
	if self._raw_update then
		if self._location == 'status' then
			self.sai.text.status = nil
			self.sai.text.status_timeout = nil
		else
			-- the var's restore puts the original block back
			self.sai.text[self._location] = nil
			self.sai.text.enabled = nil
		end
	end

	self._location = loc

	if self._enabled then
		if self._location == 'status' then
			-- take the status over: permanent for us, restored on disable
			-- only when it was permanent before (see the sai.text special)
			self.sai.text.status_timeout = 0
			self.sai.text.status = ''
			self._raw_update = function(x) sai.text.status = x end
		else
			-- blanks the blocks when the layer was off (see the sai.text
			-- special); our writes go through the same override, so the
			-- original block stays tracked for the restore
			self.sai.text.enabled = true
			self._raw_update = function(lines) self.sai.text[self._location] = lines end
		end

		self:render()
	end
end

---@private
function M:get_confirmed() return nil end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then
		M.super.set_enabled(self, val)
		self:_on_dst_change(self._location)
		rawset(self, 'confirmed', nil)
	else
		self._enabled = false -- fake the disable to make _on_dst_change skip the re-arm
		self:_on_dst_change(self._location)
		self._enabled = true
		self._raw_update = false
		M.super.set_enabled(self, val)
	end

	return false
end

return M
