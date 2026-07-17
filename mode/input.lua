---@diagnostic disable: invisible
---@module 'sai.mode.input'

local U = require 'sai.lib.utils'
local binds = require 'sai.binds'

---A text input mode that captures key events for text entry.
---Configure hooks and parameters before enabling.
---@class sai.mode.input: sai.mode.custom
---@field text string state of user input
---@field col integer cursor position (1-based insert position)
---@field line integer cursor line (1-based)
---@field location block_position_t|'status' where should we output to
---@field visual integer|false position of the selection marker (like `col`)
---@field map fun(bind:string|string[],key_or_fn:string|fun(self:self),desc:string?)
---@field protected confirmed boolean? has input been confirmed or aborted, useful for disabling logic
local M = {
	super = require 'sai.mode.custom',
	_trigger = false, -- disable trigger to ensure text is visible even when set to `status`

	-- Public, changeable at any time
	---hook called on every text change
	on_text_change = false, ---@type fun(self:sai.mode.input,text:string)|false

	-- Configuration (set before enabling)
	_prompt = false, ---@type string|false optional prompt prefix
	_cursor_icon = '▎',

	-- Live config
	---@type appmode_t|false
	_mode = false, ---@protected
	---@type block_position_t|'status'
	_location = 'status', ---@protected

	-- Visible state
	_text = '', ---@protected must use the setter, otherwise column is out of whack
	_col = 1, ---@protected 1-based
	---@type integer|false indicates end of selection when available (1-based)
	_visual = false, ---@protected

	-- TODO: make available as U.input that users can call on-demand with custom prompt
	-- TODO: convert to using lines and pager and create a textbox for line scrolling
	-- Private state
	---@see swayimg.viewer.set_text
	---@see swayimg.text.set_status
	---@type fun(loc:block_position_t, lines:string[])|fun(status:string)|false
	_raw_update = false, ---@private
}
setmetatable(M, { __index = M.super })

---Default confirmation behaviour, meant for overriding
---@param result string|false
---@return boolean? disable_mode should mode be disabled (default: true)
function M:on_confirm(result) end

---@param fn string|fun(self:self)
function M:_rawmap(b, cfg, fn)
	if type(fn) == 'string' then
		---@diagnostic disable-next-line: duplicate-set-field
		cfg.cb = function() self:insert(fn) end
		if not cfg.desc then cfg.kind = 'private' end
		M.super._rawmap(self, b, cfg, cfg.cb)
		return
	end

	M.super._rawmap(self, b, cfg, fn)
end

-- Add letter and digit mappings
for i = string.byte 'a', string.byte 'z' do
	local lc = string.char(i)
	local uc = string.char(i - 32)
	U.rev_key_map[lc] = lc -- a-z
	U.rev_key_map['Shift+' .. lc] = uc -- Shift+a → A
end
for i = 0, 9 do
	U.rev_key_map[tostring(i)] = tostring(i) -- 0-9
end

---@return sai.mode.input
function M:new()
	U.new_object(self, M)
	M.super.new(self)

	local maps = self._mappings
	for key, char in pairs(U.rev_key_map) do
		if #char == 1 then maps[key] = { cb = char, trace = self._path, _traced = true } end
	end
	binds.input(self)

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

		display = ('%s%s%s%s%s'):format(
			self._text:sub(1, from - 1),
			f_ic,
			self._text:sub(from, to - 1),
			t_ic,
			self._text:sub(to)
		)
	else
		display = ('%s%s%s'):format( --
			self._text:sub(1, self._col - 1),
			self._cursor_icon,
			self._text:sub(self._col)
		)
	end

	if self._location == 'status' then
		self._raw_update(self._prompt and self._prompt .. display or display)
	else
		local lines = { self._prompt }
		for l in display:gmatch '([^\n]*)\n?' do
			lines[#lines + 1] = l
		end
		self._raw_update(self._location, lines)
	end
end

---Insert a string at the cursor position
---@param text string
function M:insert(text)
	local from, to = self._col, self._visual or self._col
	self._visual = false
	if from > to then
		from, to = to, from
	end

	self._text = self._text:sub(1, from - 1) .. text .. self._text:sub(to)
	self._col = from + #text

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
	self._text = self._text:sub(1, from - 1) .. self._text:sub(to + 1)
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
---@return {line:string,from:integer,to:integer}[] list of lines and their positions
function M:get_lines_info()
	local lines = {}
	local i = 1
	for l in self._text:gmatch '([^\n]*)\n?' do
		lines[#lines + 1] = { line = l, from = i, to = i + #l }
		i = i + #l + 1
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
	self.col = #self._text
	return lines[#lines]
end

---@protected
---Updates and renders text, moving the cursor to stay relative to text following it
---@param val string
function M:set_text(val)
	if self._col > #val or self._col > #self._text then
		self._col = #val + 1
	elseif select(2, val:find(self._text:sub(self._col), 1, true)) == #val then
		self._col = #val - (#self._text - self._col)
	end
	self._text = val

	if self._enabled and self.on_text_change then self:on_text_change(self._text) end
	self:render()
	return false
end

---@protected
function M:set_visual(val)
	self._visual = val and math.max(1, math.min(#self._text + 1, val)) or val
	if self._enabled then self:render() end
	return false
end

---@protected
function M:set_col(val)
	self._col = math.max(1, math.min(#self._text + 1, val))
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

---@protected
---@param mode appmode_t
function M:set_mode(mode)
	local om = self._mode
	M.super.set_mode(self, mode)
	self._mode = om -- set the mode back so that we know what to change
	self:_on_dst_change(mode, self._location)
	return false
end

---@param val block_position_t|'status'
function M:set_location(val)
	if val == self._location then return false end
	self:_on_dst_change(self._mode, val)
	return false
end

---@private
---@param mode appmode_t
---@param loc block_position_t|'status'
function M:_on_dst_change(mode, loc)
	if self._raw_update then
		if self._location == 'status' then
			self.sai.text.status_timeout = sai.text.status_timeout
			self._raw_update ''
		else
			self.sai.text.enabled = nil
			local smt = sai[self._mode or sai.mode].text
			smt[self._location] = smt[self._location]
		end
	end

	self._mode = mode
	self._location = loc

	if self._enabled then
		if self._location == 'status' then
			self.sai.text.status_timeout = 0
			self._raw_update = swayimg.text.set_status
		else
			self.sai.text.enabled = true
			self._raw_update = swayimg[self._mode or sai.mode].set_text
		end

		self:render()
	end
end

---@private
function M:get_confirmed() return nil end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return false end
	M.super.set_enabled(self, val)
	self:_on_dst_change(self._mode, self._location)
	if val then
		rawset(self, 'confirmed', nil)
	else
		self._raw_update = false
	end

	return false
end

return M
