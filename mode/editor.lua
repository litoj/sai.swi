---@module 'sai.mode.editor'

local U = require 'sai.lib.utils'
local Hist = require 'sai.lib.history'
local X = require 'sai.bridge.xkb'
local utf8 = require 'sai.bridge.utf8'
local S = require 'sai.bridge.shell'
local binds = require 'sai.binds'
local mouse_box = require 'sai.bridge.mouse_box'

---Text entry mode; positions are chars, text stays valid utf8, lines render via selector.
---@class sai.mode.editor: sai.mode.selector<string>
---@field text? string state of user input (always valid utf8)
---@field col? integer cursor position (1-based insert position in characters, within the cursor line)
---@field visual? {line:integer,col:integer}|false position of the selection anchor (like `col`, but line-based)
---@field prompt? string|false optional prompt prefix (the pager title)
---@field on_text_changed? fun(self:sai.mode.editor, text:string)|false
---@field on_confirm? fun(self:sai.mode.editor, result:string[]|false):boolean?|false, string? final hook; `false` in reports an explicit abort, the
---  second return is the message to notify after the mode settles
---@field history? sai.lib.history|false confirmed inputs, newest first; false disables the recall
---@field update_history? boolean file confirmed inputs in the history
local M = {
	super = require 'sai.mode.selector',
	_path = 'sai.mode.editor',
	map_filter = function(b)
		return not b:find '%u[%l%d]*$' and not b:find('Ctrl', 1, true) and not b:find('Alt', 1, true)
	end,

	-- the input IS the selection: the marking binds stay off, the accept
	-- keys stay free for a completion menu to take over
	single_select = true,

	-- Configuration (set before enabling)
	_cursor_icon = '▎',

	-- Public, changeable at any time (picked up by the next render)
	---@type string|false
	_prompt = false, -- prompt prefix, writable live through `prompt`

	-- the cursor line renders without the selector's markers; its scroll
	-- margin is 0 (the cursor stays at the window edge while typing)
	_scroll_ahead = 0,
	-- Live config
	---@type text_location
	_location = 'status',

	-- Visible state
	_lines = { '' }, -- text rows; replace through `lines`
	_col = 1, -- 1-based, within the cursor line
	---@type {line:integer,col:integer}|false selection anchor when available (1-based)
	_visual = false,

	-- Hooks, changeable at any time
	---@type fun(self:sai.mode.editor, text:string)|false
	on_text_changed = false,

	-- History, changeable at any time
	update_history = true, --- file confirmed inputs in the history
}
setmetatable(M, { __index = M.super })

---Default confirmation behaviour, meant for overriding.
---@param result string[]|false
---@return boolean? true files the input in the history and closes, false stays open
---@return string? message the editor notifies after the mode settles
---@diagnostic disable-next-line: unused-local
function M:on_confirm(result) end

---@return string[] the stored lines, like the selector returns its items
function M:result() return self._lines end

---@param b string
---@param cfg bindcfg
---@param fn string|fun(self:self)
function M:_rawmap(b, cfg, fn)
	-- minimize number of overrides
	if not self._enabled or (not cfg.cb and not self._mode_api._mappings[b]) then return end

	M.super._rawmap(self, b, cfg, fn)
end

---@return sai.mode.editor
function M:new()
	U.new_object(self, M)
	if self.history ~= false then self.history = Hist.new(self.history) end

	M.super.new(self)

	-- the prompt renders as the pager title
	self.title = self._prompt or ''

	-- a click owns the clicked line and column
	self.map('MouseLeft', function() self:place_at_mouse() end, { kind = 'private' })

	-- the input hijack and the default binds: editors always map
	-- their own, hosts add theirs on top
	local maps = self._mappings
	for i = 65, 90 do
		local uc = string.char(i)
		maps['Shift+' .. string.char(i + 32)] = {
			cb = function() self:on_unassigned(uc) end,
			trace = self._path,
			_traced = true,
			kind = 'input',
		}
	end
	binds.editor(self)

	self.on_unassigned = function(_, bind, fallback)
		local kind, ch = X.process_next_input(bind)
		if kind == 'command' then
			if fallback then return fallback(bind) end
			return
		elseif kind == 'text' then
			self:insert(ch)
		end
	end

	return self
end

-- ---------------------------------------------------------------------------
-- Text motions, deletions, clipboard (binds map keys onto these)
-- ---------------------------------------------------------------------------

-- utf8-aware word scan; non-ASCII counts as a word char
local function word_flags(text)
	local flags = {}
	for _, cp in utf8.codes(text) do
		flags[#flags + 1] = cp >= 0x80 or utf8.char(cp):match '%w' ~= nil
	end
	return flags
end

---@param text string
---@param col integer char position to scan from
---@param backward? boolean scan towards the text start instead
---@return integer from start of the word boundary
---@return integer to end of the word boundary
local function get_word_idx(text, col, backward)
	local isw = word_flags(text)
	local n = #isw
	local i = col
	if backward then
		i = math.min(i, n)
		while i > 0 and not isw[i] do
			i = i - 1
		end
		while i > 0 and isw[i] do
			i = i - 1
		end
		return i + 1, col
	end
	while i <= n and not isw[i] do
		i = i + 1
	end
	while i <= n and isw[i] do
		i = i + 1
	end
	return col, i
end

---Split text into lines, keeping a trailing empty line after a final newline.
---@param val string already sanitized
---@return string[]
local function split_lines(val)
	local lines = {}
	for l in (val .. '\n'):gmatch '([^\n]*)\n' do
		lines[#lines + 1] = l
	end
	return lines
end

---Absolute char position of an in-line cursor in the joined text.
---@param lines string[]
---@param line integer
---@param col integer
---@return integer
local function abs_pos(lines, line, col)
	local abs = col
	for i = 1, line - 1 do
		abs = abs + utf8.len(lines[i]) + 1
	end
	return abs
end

---In-line cursor for an absolute char position, clamped into the text.
---@param lines string[]
---@param abs integer
---@return integer line
---@return integer col
local function line_col(lines, abs)
	local start = 1
	for i, l in ipairs(lines) do
		local to = start + utf8.len(l)
		if abs <= to then return i, abs - start + 1 end
		start = to + 1
	end
	local last = lines[#lines] or ''
	return #lines, utf8.len(last) + 1
end

function M:select_all()
	self.visual = { line = 1, col = 1 }
	self.line = #self._lines
	self.col = utf8.len(self._lines[#self._lines]) + 1
end

---@return integer l1, integer c1, integer l2, integer c2 the ordered span, end-exclusive
function M:selection()
	local l1, c1, l2, c2 = self._line, self._col, self._line, self._col
	local v = self._visual
	if v and (v.line < l1 or (v.line == l1 and v.col < c1)) then
		l1, c1, l2, c2 = v.line, v.col, l1, c1
	elseif v then
		l2, c2 = v.line, v.col
	end
	return l1, c1, l2, c2
end

function M:copy()
	if not self._visual then return end
	-- the selection end is exclusive, like for insert/delete
	local l1, c1, l2, c2 = self:selection()
	local lines = self._lines
	local text
	if l1 == l2 then
		text = utf8.sub(lines[l1], c1, c2 - 1)
	else
		local parts = { utf8.sub(lines[l1], c1) }
		for i = l1 + 1, l2 - 1 do
			parts[#parts + 1] = lines[i]
		end
		parts[#parts + 1] = utf8.sub(lines[l2], 1, c2 - 1)
		text = table.concat(parts, '\n')
	end
	S.clipboard_set(text)
end

function M:cut()
	if not self._visual then return end
	self:copy()
	self:insert ''
end

function M:paste()
	local text = S.clipboard_get()
	if text then self:insert(text) end
end

function M:delete_prev_char() self:delete(not self._visual and abs_pos(self._lines, self._line, self._col) - 1) end
function M:delete_next_char() self:delete(not self._visual and abs_pos(self._lines, self._line, self._col)) end
function M:delete_prev_word()
	if self._visual then return self:delete() end
	local lines = self._lines
	self:delete(get_word_idx(table.concat(lines, '\n'), abs_pos(lines, self._line, self._col) - 1, true))
end
function M:delete_next_word()
	if self._visual then return self:delete() end
	local lines = self._lines
	self:delete(get_word_idx(table.concat(lines, '\n'), abs_pos(lines, self._line, self._col)))
end

---@diagnostic disable: invisible

---Wrap a cursor motion so it either moves (drops the selection) or extends it.
---@param fn fun(self:sai.mode.editor)
---@return fun(self:sai.mode.editor, select?:boolean)
local function motion(fn)
	return function(self, select)
		if select then
			self.visual = self._visual or { line = self._line, col = self._col }
		else
			self.visual = false
		end
		fn(self)
	end
end

M.move_left = motion(function(self)
	if self._col > 1 then
		self.col = self._col - 1
	elseif self._line > 1 then
		self.line = self._line - 1
		self.col = utf8.len(self._lines[self._line]) + 1
	end
end)

---Place the cursor at the clicked character.
function M:place_at_mouse()
	local line, col = mouse_box.char_at(self)
	if not line then return end
	-- the clicked column maps past the cursor and selection markers
	-- the line renders with: each marker eats one cell at its text position
	local icons = {}
	if line == self._line then icons[#icons + 1] = self._col end
	if self._visual and line == self._visual.line then icons[#icons + 1] = self._visual.col end
	table.sort(icons)
	for i, p in ipairs(icons) do
		if p + i - 1 < col then col = col - 1 end
	end
	self.line = line
	self.col = math.max(1, math.min(utf8.len(self._lines[self._line]) + 1, col))
end
M.move_right = motion(function(self)
	if self._col <= utf8.len(self._lines[self._line]) then
		self.col = self._col + 1
	elseif self._line < #self._lines then
		self.line = self._line + 1
		self.col = 1
	end
end)
M.move_up = motion(function(self)
	self.line = self._line - 1
	-- the new line may be shorter: re-clamp the column into it
	self.col = self._col
end)
M.move_down = motion(function(self)
	self.line = self._line + 1
	-- the new line may be shorter: re-clamp the column into it
	self.col = self._col
end)
M.move_prev_word = motion(function(self)
	local lines = self._lines
	local from = get_word_idx(table.concat(lines, '\n'), abs_pos(lines, self._line, self._col) - 1, true)
	local l, c = line_col(lines, from)
	self.line = l
	self.col = c
end)
M.move_next_word = motion(function(self)
	local lines = self._lines
	local isw = word_flags(table.concat(lines, '\n'))
	local i, n = abs_pos(lines, self._line, self._col), #isw
	while i <= n and isw[i] do
		i = i + 1
	end
	while i <= n and not isw[i] do
		i = i + 1
	end
	local l, c = line_col(lines, i)
	self.line = l
	self.col = c
end)
M.move_line_start = motion(function(self) self.col = 1 end)
M.move_line_end = motion(function(self) self.col = utf8.len(self._lines[self._line]) + 1 end)
M.move_text_start = motion(function(self)
	self.line = 1
	self.col = 1
end)
M.move_text_end = motion(function(self)
	self.line = #self._lines
	self.col = utf8.len(self._lines[#self._lines]) + 1
end)

-- ---------------------------------------------------------------------------
-- Text state
-- ---------------------------------------------------------------------------

---Replace the span from (l1,c1) inclusive to (l2,c2) exclusive with text.
---The caller places the cursor: the line/col setters clamp it into the new lines.
---@param l1 integer
---@param c1 integer
---@param l2 integer
---@param c2 integer
---@param text string already sanitized
local function splice(self, l1, c1, l2, c2, text)
	local lines = self._lines
	local middle = split_lines(text)
	middle[1] = utf8.sub(lines[l1], 1, c1 - 1) .. middle[1]
	middle[#middle] = middle[#middle] .. utf8.sub(lines[l2], c2)
	local out = {}
	for i = 1, l1 - 1 do
		out[#out + 1] = lines[i]
	end
	for i = 1, #middle do
		out[#out + 1] = middle[i]
	end
	for i = l2 + 1, #lines do
		out[#out + 1] = lines[i]
	end
	self.lines = out
end

---@param text string
function M:insert(text)
	-- coerce bad bytes to '?'; keep utf8.len() valid
	text = utf8(text)
	-- selection() already orders the span, end-exclusive
	local l1, c1, l2, c2 = self:selection()
	self._visual = false

	local pieces = split_lines(text)
	local cl, cc
	if #pieces == 1 then
		cl, cc = l1, c1 + utf8.len(text)
	else
		cl, cc = l1 + #pieces - 1, utf8.len(pieces[#pieces]) + 1
	end
	splice(self, l1, c1, l2, c2, text)
	self.line = cl
	self.col = cc

	if self.on_text_changed then self:on_text_changed(self.text) end
end

---Range positions are absolute chars, inclusive. A bare call backspaces
---without a selection, kills the selection with one.
---@param from? integer 1-based absolute position, leave unspecified for backspace/selection
---@param to? integer defaults to `from`, 1-based absolute position
function M:delete(from, to)
	if not from and not to then
		if not self._visual then
			local abs = abs_pos(self._lines, self._line, self._col)
			if abs == 1 then return end
			from = abs - 1
		else
			local l1, c1, l2, c2 = self:selection()
			self._visual = false
			splice(self, l1, c1, l2, c2, '')
			self.line = l1
			self.col = c1
			if self.on_text_changed then self:on_text_changed(self.text) end
			return
		end
	end

	if not to then to = from end
	if from > to then
		from, to = to, from
	end

	if from == 0 then return end
	if from < 0 or to <= 0 then error 'Only positive indexes allwed in delete()' end
	local l1, c1 = line_col(self._lines, from)
	local l2, c2 = line_col(self._lines, to + 1)
	if self._visual then self._visual = false end
	splice(self, l1, c1, l2, c2, '')
	self.line = l1
	self.col = c1

	if self.on_text_changed then self:on_text_changed(self.text) end
end

---`true` files the input and closes, `false` stays open, anything else closes;
---a second return value is the message to notify, emitted after the mode settles.
---@param res string[]|false
function M:_handle_result(res)
	if not res then return end
	self._verdict = 1
	-- torn down first: the callback works outside the mode, its message
	-- lands after the re-enable render that would otherwise cover it
	self.enabled = false
	local verdict, msg = self:on_confirm(res)
	if verdict == false then
		self.enabled = true
	else
		if verdict == true then
			if self.history then
				-- the input is consumed: the cycle must not recall its own entry
				if self.update_history then
					self.history:add(table.concat(res, '\n'))
				else
					self.history:reset()
				end
			end
			self.text = ''
		end
	end
	if msg then sai.notify(msg) end
end

---Text from input start to the cursor; the history matches against this.
---@return string
local function cursor_prefix(self)
	local lines, line, col = self._lines, self._line, self._col
	local parts = {}
	for i = 1, line - 1 do
		parts[#parts + 1] = lines[i] .. '\n'
	end
	parts[#parts + 1] = utf8.sub(lines[line], 1, col - 1)
	return table.concat(parts)
end

---Move a recalled entry into the input; the cursor stays where it stood,
---so the next recall matches the same text before it.
---@param val string
local function recall(self, val)
	self.lines = split_lines(val)
	self.col = self._col -- the setter clamps into the new cursor line
	if self._enabled and self.on_text_changed then self:on_text_changed(self.text) end
end

---Recall the next newer matching entry (Down); past the newest the typed text returns.
function M:hist_next()
	if not self.history then return end
	-- Down is history prev (newer); nil means hold the input
	local val = self.history:prev(cursor_prefix(self))
	if val ~= nil then recall(self, val) end
end

---Recall the next older matching entry (Up), starting after the current one.
function M:hist_prev()
	if not self.history then return end
	-- Up is history next (older); nil means hold the input
	local val = self.history:next(cursor_prefix(self))
	if val ~= nil then recall(self, val) end
end

---@param text? string[]|false
function M:confirm(text)
	-- an explicit abort is the only path reporting through on_confirm(false);
	-- aborted input never returns, so the text clears up front
	if text == false then
		self._verdict = -1
		self.text = ''
		if self:on_confirm(false) ~= false then self.enabled = false end
		return
	end
	self:_handle_result(self:parse_input(text))
end

---@protected
---@return string the joined lines
function M:get_text() return table.concat(self._lines, '\n') end

-- ---------------------------------------------------------------------------
-- Rendering through the selector
-- ---------------------------------------------------------------------------

---@param s string the line text
---@param c integer|false cursor position local to the line
---@param v integer|false selection marker position local to the line
---@param ci string
---@return string
local function insert_icons(s, c, v, ci)
	if c and v then
		if c == v then return utf8.sub(s, 1, c - 1) .. ci .. '|' .. utf8.sub(s, c) end
		if c < v then return utf8.sub(s, 1, c - 1) .. ci .. utf8.sub(s, c, v - 1) .. '|' .. utf8.sub(s, v) end
		return utf8.sub(s, 1, v - 1) .. '|' .. utf8.sub(s, v, c - 1) .. ci .. utf8.sub(s, c)
	elseif c then
		return utf8.sub(s, 1, c - 1) .. ci .. utf8.sub(s, c)
	elseif v then
		return utf8.sub(s, 1, v - 1) .. '|' .. utf8.sub(s, v)
	end
	return s
end

-- the pager's paint hook: the cursor and the selection marker read the
-- text state live
---@param item string
---@param idx integer
---@return string
function M:line_fmt(item, idx)
	local c = idx == self._line and self._col or false
	local v = self._visual and idx == self._visual.line and self._visual.col or false
	return insert_icons(item, c, v, self._cursor_icon)
end

---@protected
---Updates and renders text, moving the cursor to stay relative to text following it
function M:set_text(val)
	-- coerce bad bytes to '?'; keep utf8.len() valid
	val = utf8(val)
	local old = table.concat(self._lines, '\n')
	local len, oldlen = utf8.len(val), utf8.len(old)
	local abs = abs_pos(self._lines, self._line, self._col)
	local lines = split_lines(val)
	local v = self._visual
	if v then
		-- clamp the anchor into the new lines
		v.line = math.max(1, math.min(#lines, v.line))
		v.col = math.max(1, math.min(utf8.len(lines[v.line]) + 1, v.col))
	end
	if abs > len or abs > oldlen then
		abs = len + 1
	else
		-- text was inserted before the cursor: keep the cursor relative to the text following it
		local suffix = utf8.sub(old, abs)
		if #suffix <= #val and val:sub(-#suffix) == suffix then abs = len - (oldlen - abs) end
	end
	self.lines = lines
	local l, c = line_col(lines, abs)
	self.line = l
	self.col = c

	if self._enabled and self.on_text_changed then self:on_text_changed(val) end
	return false
end

---@protected
---@type fun(self: sai.mode.editor, val: {line:integer,col:integer}|false):false
function M:set_visual(val)
	local prev = self._visual and self._visual.line
	if val then
		local line = math.max(1, math.min(#self._lines, val.line))
		self._visual = { line = line, col = math.max(1, math.min(utf8.len(self._lines[line]) + 1, val.col)) }
		if prev and prev ~= line then self._lines:touch(prev) end
		self._lines:touch(line)
	else
		self._visual = false
		if prev then self._lines:touch(prev) end
	end
	if self._enabled then self:render(true) end
	return false
end

---@protected
function M:set_col(val)
	self._col = math.max(1, math.min(utf8.len(self._lines[self._line]) + 1, val))
	self._lines:touch(self._line)
	if self._enabled then self:render(true) end
	return false
end

---@protected
---@type fun(self: sai.mode.editor, val: string|false):false
function M:set_prompt(val)
	if val == self._prompt then return false end
	self._prompt = val
	self.title = val or '' -- the prompt paints as the pager title
	if self._enabled then self:render(true) end
	return false
end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then
		M.super.set_enabled(self, val) -- the selector chain shows the pager
		self:render()
		return self._location ~= 'status' -- the prompt takes the status over silently
	end

	-- nothing reports: a plain disable leaves the verdict as it stood
	M.super.set_enabled(self, val)
	return true
end

return M
