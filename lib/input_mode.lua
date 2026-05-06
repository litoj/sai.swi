---@diagnostic disable: invisible
---@module 'swi.lib.input_mode'

local U = require 'swi.lib.utils'
local bo = require 'swi.lib.bind_override'

---A text input mode that captures key events for text entry.
---Configure hooks and parameters before enabling.
---@class swi.lib.input_mode: swi.lib.custom_mode
---@field text string state of user input
---@field col integer cursor position (0-based insert position)
---@field line integer cursor line (1-based)
---@field location block_position_t|'status' where should we output to
---@field protected input_mapper swi.lib.bind_override map key combos to input strings
local M = {
	super = require 'swi.lib.custom_mode',
	_path = 'swi.lib.input_mode',
	_trigger = false, -- disable trigger to ensure text is visible even when set to `status`

	-- Configuration (set before enabling)
	_prompt = '', ---@type string|false optional prompt prefix
	_cursor_icon = '▎',

	-- Live config
	---@type appmode_t|false
	_mode = false, ---@protected
	---@type block_position_t|'status'
	_location = 'status', ---@protected

	-- Visible state
	_text = '', ---@protected
	_col = 0, ---@protected
	---@type integer|false indicates end of selection when available
	visual = false, ---@protected

	-- Public, changeable at any time
	on_text_change = false, ---@type fun(text:string)|false hook called on every text change
	---hook called on input confirmation/abort
	---@type fun(result:string|false):(finish:boolean?) end handler - return false to prevent disabling
	on_confirm = function() return true end,

	-- Private state
	---@see swayimg.viewer.set_text
	---@see swayimg.text.set_status
	---@type fun(loc:block_position_t, lines:string[])|fun(status:string)|false
	_raw_update = false, ---@private
}
setmetatable(M, { __index = M.super })

-- Printable key mappings: X11 keysym name → character
---@type {[string]:string}
M.default_input_key_map = {
	space = ' ',
	-- Punctuation (unshifted)
	period = '.',
	comma = ',',
	semicolon = ';',
	apostrophe = "'",
	grave = '`',
	slash = '/',
	backslash = '\\',
	bracketleft = '[',
	bracketright = ']',
	minus = '-',
	equal = '=',
	-- Shifted punctuation (US layout)
	['Shift+plus'] = '+',
	['Shift+underscore'] = '_',
	['Shift+colon'] = ':',
	['Shift+quotedbl'] = '"',
	['Shift+asciitilde'] = '~',
	['Shift+question'] = '?',
	['Shift+bar'] = '|',
	['Shift+braceleft'] = '{',
	['Shift+braceright'] = '}',
	['Shift+greater'] = '>',
	['Shift+less'] = '<',
	-- Shifted numbers (US layout)
	['Shift+exclam'] = '!',
	['Shift+at'] = '@',
	['Shift+numbersign'] = '#',
	['Shift+dollar'] = '$',
	['Shift+percent'] = '%',
	['Shift+asciicircum'] = '^',
	['Shift+ampersand'] = '&',
	['Shift+asterisk'] = '*',
	['Shift+parenleft'] = '(',
	['Shift+parenright'] = ')',
}

-- Add letter and digit mappings
for i = string.byte 'a', string.byte 'z' do
	local lc = string.char(i)
	local uc = string.char(i - 32)
	M.default_input_key_map[lc] = lc -- a-z
	M.default_input_key_map['Shift+' .. lc] = uc -- Shift+a → A
end
for i = 0, 9 do
	M.default_input_key_map[tostring(i)] = tostring(i) -- 0-9
end

---@type {[string]:{cb:fun(self:swi.lib.input_mode),desc:string}}
M.default_action_mappings = {
	Return = { cb = function(self) self:confirm() end, desc = 'Confirm input' },
	Escape = { cb = function(self) self:confirm(false) end, desc = 'Abort input' },
	BackSpace = {
		cb = function(self) self:delete(self._col, self.visual or self._col) end,
		desc = 'Delete prev char',
	},
	Delete = {
		cb = function(self) self:delete(self._col + 1, self.visual or self._col + 1) end,
		desc = 'Delete next char',
	},
}
function M.add_shiftable(key, fn, direction)
	direction = direction or key:lower()

	M.default_action_mappings[key] = {
		cb = function(self)
			if self.visual then self.visual = false end
			fn(self)
		end,
		desc = 'Move ' .. direction,
	}
	M.default_action_mappings['Shift+' .. key] = {
		cb = function(self)
			if not self.visual then self.visual = self._col end
			fn(self)
		end,
		desc = 'Select ' .. direction,
	}
end

M.add_shiftable('Left', function(self) self.col = self._col - 1 end)
M.add_shiftable('Right', function(self) self.col = self._col + 1 end)
M.add_shiftable('Up', function(self) self.line = self.line - 1 end)
M.add_shiftable('Down', function(self) self.line = self.line + 1 end)
M.add_shiftable('End', function(self)
	local lines = self:lines()
	local col = 0
	for _, l in ipairs(lines) do
		col = col + #l + 1
		if self._col < col then
			self.col = col - 1
			return
		end
	end
end)
M.add_shiftable('Home', function(self)
	local line = self.line
	self.col = 0
	self.line = line
end, 'start')

---@return swi.lib.input_mode
function M:new()
	U.new_object(self, M)
	self.add_shiftable = nil
	self.default_action_mappings = nil
	self.default_input_key_map = nil

	local imaps = {}
	for key, char in pairs(M.default_input_key_map) do
		imaps[key] = { cb = char }
	end

	---@diagnostic disable-next-line: missing-fields
	self.input_mapper = bo.new {
		_mappings = imaps,
		_rawmap = function(im, b, fn, cfg)
			if cfg and type(fn) == 'string' then
				local char = fn
				fn = function() self:insert(char) end
				cfg.cb = fn
			end
			bo._rawmap(im, b, fn, cfg)
		end,
	}

	if not self._mappings then self._mappings = {} end
	local maps = self._mappings
	for k, v in pairs(M.default_action_mappings) do
		maps[k] = { cb = function() v.cb(self) end, desc = v.desc }
	end

	---@diagnostic disable-next-line: return-type-mismatch
	return M.super.new(self)
end

---@protected
---Render the input text with cursor to the configured output
function M:_render()
	if not self._enabled then return end
	if self.on_text_change then self.on_text_change(self._text) end

	local display
	if self.visual then
		local from, to = self._col, self.visual
		local f_ic, t_ic = self._cursor_icon, '|'
		if from > to then
			from, to = to, from
			f_ic, t_ic = t_ic, f_ic
		end

		display = ('%s%s%s%s%s'):format(
			self._text:sub(1, from),
			f_ic,
			self._text:sub(from + 1, to),
			t_ic,
			self._text:sub(to + 1)
		)
	else
		display = ('%s%s%s'):format(self._text:sub(1, self._col), self._cursor_icon, self._text:sub(self._col + 1))
	end

	if self._location == 'status' then
		self._raw_update(self._prompt and self._prompt .. display or display)
	else
		self._raw_update(self._location, { self._prompt or nil, display })
	end
end

---Insert a string at the cursor position
---@param text string
function M:insert(text)
	local from, to = self._col, self.visual or self._col
	if from > to then
		from, to = to, from
	end

	self._text = self._text:sub(1, from) .. text .. self._text:sub(to + 1)
	if self.visual then self.visual = false end
	self._col = from + #text
	self:_render()
end

---@param from integer
---@param to? integer defaults to `from`
function M:delete(from, to)
	if from > to then
		from, to = to, from
	end
	if not to then to = from end
	if from == 0 then return end
	if from < 0 or to <= 0 then error 'Only positive indexes allwed in delete()' end
	self._text = self._text:sub(1, from - 1) .. self._text:sub(to + 1)
	if self.visual then self.visual = false end
	if self._col >= from then self._col = self._col >= to and self._col - (from - to + 1) or from end
	self:_render()
end

---@param text? string|false confirm with given text or abort with `false`
function M:confirm(text)
	if self.on_confirm(text ~= false and (text or self._text) or false) ~= false then self:set_enabled(false) end
end

---Primitive fallback trying to guess the new cursor position after changing the text
---@param val string
function M:set_text(val)
	-- Find the largest prefix of the old text before the cursor that matches some prefix of the new text
	local best = 0
	for i = self._col, 1, -1 do
		if val:sub(1, i) == self._text:sub(1, i) then
			best = i
			break
		end
	end

	self._text = val
	self._col = best
	self:_render()
	return false
end

function M:set_col(val)
	self._col = math.max(0, math.min(#self._text, val))
	if self._enabled then self:_render() end
	return false
end

function M:lines()
	local lines = {}
	for l in self._text:gmatch '([^\n]*)\n?' do
		lines[#lines + 1] = l
	end
	return lines
end

---@param val integer
function M:set_line(val)
	local lines = { [0] = 0 }
	local at = 0
	local col
	for l in self._text:gmatch '([^\n]*)\n?' do
		at = at + #l + 1
		lines[#lines + 1] = at
		if not col then
			if self._col < at then col = self._col - lines[#lines - 1] end
		elseif val <= #lines then
			break
		end
	end
	self.col = lines[math.min(#lines - 1, math.max(1, val) - 1)] + col
	return false
end

function M:get_line()
	local at = 0
	local i = 0
	for l in self._text:gmatch '([^\n]*)\n?' do
		at = at + #l + 1
		i = i + 1
		if self._col < at then break end
	end
	return i
end

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
			self.swi.text.status_timeout = swi.text.status_timeout
			self._raw_update ''
		else
			self.swi.text.enabled = nil
			self._raw_update(self._location, swi[self._mode or swi.mode].text[self._location])
		end
	end

	self._mode = mode
	self._location = loc

	if self._enabled then
		if self._location == 'status' then
			self.swi.text.status_timeout = 0
			self._raw_update = swayimg.text.set_status
		else
			self.swi.text.enabled = true
			self._raw_update = swayimg[self._mode or swi.mode].set_text
		end

		self:_render()
	end
end

function M:set_enabled(val)
	if val == self._enabled then return false end
	M.super.set_enabled(self, val)
	self.input_mapper.enabled = val
	self:_on_dst_change(self._mode, self._location)
	if not val then self._raw_update = false end

	return false
end

return M
