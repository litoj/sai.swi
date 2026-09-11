---Tests for editor: cursor, utf8 invariant, rendering. Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local eq = H.eq

local utf8 = require 'sai.bridge.utf8'
local Hist = require 'sai.lib.history'

local env = H.recording_stack { 'sai.mode.editor' }
local editor_mod = env.mods['sai.mode.editor']
local raw_binds, with_env = env.raw_binds, env.with_env

local raw_text = env.swayimg.text

local function new_status_editor(cfg)
	local m = editor_mod.new(cfg or {})
	m.enabled = true
	return m
end

-- status render of a default-location editor (title plus whole text joined)
local function status_of(cfg)
	local m = new_status_editor(cfg)
	return m, function() return raw_text.status end
end

---The tested invariant: state, rendered output, cursor and selection must stay utf8-consistent.
---@return string? violation
local function violations(self, display)
	if not utf8.isvalid(self.text) then return 'text state is not valid utf8' end
	if display and not utf8.isvalid(display) then return 'rendered display is not valid utf8' end
	local line = self.lines[self.line]
	if not line then return 'cursor line outside the lines' end
	if self.col < 1 or self.col > utf8.len(line) + 1 then return 'cursor out of char bounds' end
	local v = self.visual
	if v then
		local vline = self.lines[v.line]
		if not vline then return 'selection anchor outside the lines' end
		if v.col < 1 or v.col > utf8.len(vline) + 1 then return 'selection marker out of char bounds' end
	end
end

---Fails with the violation itself, not the bare fact.
local function ok_state(h, name, self, get)
	local v = violations(self, get and get() or nil)
	if v then
		h.fail(name, v)
	else
		h.pass(name)
	end
end

-- clipboard stub with guaranteed restore: writes land in the box
local function with_clipboard(fn)
	local S = require 'sai.bridge.shell'
	local old_set = S.clipboard_set
	local box = {}
	S.clipboard_set = function(t) box[1] = t end
	local ran, err = pcall(fn, box)
	S.clipboard_set = old_set
	if not ran then error(err, 0) end
end

local T = {}

T.insert_and_cursor = with_env(function(h)
	local self, get = status_of {}
	self:insert 'héllo'
	eq('utf8 insert', 'héllo', self.text)
	eq('cursor after multibyte insert', 6, self.col)
	ok_state(h, 'state valid after insert', self, get)

	self.col = 2 -- between h and é
	eq('cursor renders between characters', 'h▎éllo', get())
	self:insert 'X'
	eq('insert at char position', 'hXéllo', self.text)
	eq('cursor after mid-text insert', 3, self.col)
	ok_state(h, 'state valid after mid-text insert', self, get)
	self.enabled = false
end)

T.place_at_mouse = with_env(function()
	local mouse
	env.swayimg.get_mouse_pos = function() return mouse end
	local m = new_status_editor { _location = 'topleft', _prompt = 'Go' }
	m:set_text 'first\nsecond' -- cursor (1, 1)

	-- the first hit on a line lands it cursor-free
	mouse = { x = 10 + 24, y = 10 + 2 * 42 + 21 } -- px cell 2 of line 2
	m:place_at_mouse()
	eq('clicked line', 2, m._line)
	eq('clicked char', 2, m._col)

	-- the cursor marker on the line shifts the cells after it
	m.col = 2 -- the icon stands before the second character
	mouse = { x = 10 + 3 * 24, y = 10 + 2 * 42 + 21 } -- rendered cell 4
	m:place_at_mouse()
	eq('a click lands past the marker', 3, m._col)

	m.enabled = false
end)

T.delete_and_selection = with_env(function(h)
	local self, get = status_of {}
	self:insert 'hXéllo wörld'

	self.col, self.visual = 3, { line = 1, col = 9 } -- selection 'éllo w'
	self:delete()
	eq('char-based selection delete', 'hXörld', self.text)
	eq('cursor after selection delete', 3, self.col)
	ok_state(h, 'state valid after selection delete', self, get)

	self.visual = { line = 1, col = 2 } -- selection before the cursor: icons swap sides
	eq('selection renders around multibyte chars', 'h|X▎örld', get())
	self:delete(2, 3)
	eq('char-based range delete', 'hrld', self.text)
	ok_state(h, 'state valid after range delete', self, get)
	self.enabled = false
end)

T.line_info = with_env(function()
	local self = new_status_editor {}
	self:insert 'aé\nbö'
	eq('line count', 2, #self.lines)
	eq('first line', 'aé', self.lines[1])
	eq('second line', 'bö', self.lines[2])
	eq('cursor line follows the insert', 2, self.line)
	self.enabled = false
end)

T.set_text_cursor_tracking = with_env(function(h)
	local self, get = status_of {}
	self:insert 'héllo'

	self.col = 5 -- between 'hell' and 'o'
	self.text = 'xxhéllo' -- text inserted before the cursor
	eq('cursor stays relative to following text', 7, self.col)
	ok_state(h, 'state valid after prefix insert', self, get)

	self.text = 'a' -- shorter than the cursor
	eq('cursor clamps to text end', 2, self.col)
	ok_state(h, 'state valid after shrink', self, get)
	self.enabled = false
end)

T.invalid_input_sanitized = with_env(function(h)
	local self, get = status_of {}
	self:insert '\255ok\254'
	h.ok('invalid insert gets sanitized', utf8.isvalid(self.text))
	h.contains('valid content kept after sanitize', self.text, 'ok')
	ok_state(h, 'state valid after invalid insert', self, get)

	self.text = '\xf0\x28\x8c\x28a\xffb'
	h.ok('invalid set_text gets sanitized', utf8.isvalid(self.text))
	ok_state(h, 'state valid after invalid set_text', self, get)
	self.enabled = false
end)

T.rendering_through_the_selector = with_env(function()
	-- the status shows the title and the whole text joined
	local self, get = status_of { _prompt = 'Ask' }
	self:insert 'one\ntwo' -- the cursor lands at the end: the second line
	-- the status writes join the lines with newlines: the text layer pads
	-- them to the longest one, like every status block
	eq('status shows the prompt and the whole text', 'Ask: one\ntwo▎  ', get())

	-- the line hook paints the cursor line: the class default does it, the
	-- swap here must touch the rows, it happens past content
	local stock_fmt = self.line_fmt
	self.line_fmt = function(_, item, idx)
		local s = stock_fmt(self, item, idx)
		if idx == self._line then s = '[' .. s .. ']' end
		return s
	end
	for i = 1, #self._lines do
		self._lines:touch(i)
	end
	self:render(true)
	eq('custom line hook wraps the cursor line', 'Ask: one\n[two▎]', get())
	self.line_fmt = stock_fmt

	self.line = 1
	self.col = 2
	eq('cursor line follows the cursor', 'Ask: o▎ne\ntwo        ', get())
	self.enabled = false
end)

-- an empty line in the middle is a real row: it renders blank, not dropped
T.status_keeps_empty_lines = with_env(function(h)
	local self, get = status_of { _prompt = 'Ask' }
	self:insert 'a\n\nb'
	h.eq('the middle empty line renders as a blank row', 'Ask: a\n      \nb▎  ', get())
	self.enabled = false
end)

T.prompt_is_live = with_env(function(_)
	local self, get = status_of { _prompt = 'Ask' }
	self:insert 'hi'
	eq('prompt renders with the text', 'Ask: hi▎', get())

	self.prompt = 'Tell'
	eq('prompt updates live', 'Tell: hi▎', get())

	self.prompt = 'Tell'
	eq('same prompt is a no-op', 'Tell: hi▎', get())

	self.enabled = false
	self.prompt = 'Later'
	self.enabled = true
	eq('prompt set while hidden applies on enable', 'Later: hi▎', get())
	self.enabled = false
end)

T.selection_icons_across_lines = with_env(function()
	local self = new_status_editor { _location = 'topleft' }
	self:insert 'ab\ncd'
	self.visual = { line = 2, col = 1 } -- selection start on the second line
	self.line = 1
	self.col = 2 -- cursor on the first line

	-- absolute rendered lines (not the window)
	eq('cursor icon on its line', 'a▎b', self:line_fmt(self.lines[1], 1))
	eq('selection marker on its own line', '|cd', self:line_fmt(self.lines[2], 2))

	self.visual = { line = 1, col = 2 }
	self:render()
	eq('both icons on one line, cursor first', 'a▎|b', self:line_fmt(self.lines[1], 1))
	self.enabled = false
end)

T.window_follows_the_cursor = with_env(function(h)
	local self = new_status_editor { _location = 'topleft', _max_height = 3 }
	local text = {}
	for i = 1, 10 do
		text[#text + 1] = 'line' .. i
	end
	self:insert(table.concat(text, '\n'))

	-- the cursor line is the selector's line: move it through the line
	-- setter and the window follows; the window top is the pager's own field
	local function wtop() return self._scroll end
	eq('small page for the test', 3, self.page_size)
	-- the cursor sits on the trailing empty line: the window hugs the bottom
	eq('cursor at the end scrolls the window to the bottom edge', 8, wtop())

	self.line = 1
	self.col = 1
	eq('cursor back at the very top', 1, wtop())

	self.line = 8
	self.col = 1
	eq('window follows the cursor line to the bottom edge', 6, wtop())
	-- line 8 sits inside the 6-8 window and renders with the cursor
	h.contains('cursor line rendered in the window', self:line_fmt(self.lines[8], 8), 'line8')

	self.line = 2
	self.col = 1 -- above the window
	eq('window jumps when the cursor leaves it', 2, wtop())
	self.enabled = false
end)

T.derives_from_the_selector_mode = with_env(function(h)
	local self = new_status_editor {}
	h.ok('the editor IS the pager window', rawget(self, 'set_scroll') ~= nil)
	self:insert 'hello'
	h.eq('the cursor line carries the icon, no marker', 'hello▎', self:line_fmt(self.lines[1], 1))
	h.eq('the result is the lines', 'hello', table.concat(self:result(), '\n'))
	self:confirm(false)
	h.ok('abort through the inherited chain disables', not self._enabled)
end)

-- the selector's menu keys never steal the typing: j/k/space are
-- unclaimed by anyone, Tab stays free for a completion menu to take
T.nav_keys_stay_input = with_env(function(h)
	local self = new_status_editor {}
	for _, key in ipairs { 'j', 'k', 'space', 'Tab' } do
		h.eq('nothing claims ' .. key, nil, self._mappings[key])
	end
	self.enabled = false
end)

-- Command keys the editor cannot type decline to the base fallback
T.command_key_delegates_to_fallback = with_env(function(h)
	local self = new_status_editor {}
	local notified = 0
	local old_notify = env.sai.notify
	env.sai.notify = function(...)
		notified = notified + 1
		return old_notify(...)
	end
	local ran, err = pcall(function()
		raw_binds['viewer:unassigned'] 'Ctrl+q'
		h.eq('the base fallback ran', 1, notified)
	end)
	env.sai.notify = old_notify
	if not ran then error(err, 0) end
	self.enabled = false
end)

T.text_changed_hook = with_env(function()
	local seen = {}
	local self = new_status_editor { on_text_changed = function(_, text) seen[#seen + 1] = text end }
	self:insert 'a'
	self.text = 'ab'
	self:delete(1, 1)
	eq('hook fired per change', 'a|ab|b', table.concat(seen, '|'))
	self.enabled = false
end)

T.confirm_flow = with_env(function(h)
	local got
	local self = new_status_editor { on_confirm = function(_, res) got = res end }
	self:insert 'payload'

	self:confirm()
	eq('result defaults to the lines', 'payload', table.concat(got, '\n'))
	h.ok('confirm disables the mode', not self.enabled)

	self.enabled = true
	self:confirm { 'override' }
	eq('explicit confirm value wins', 'override', table.concat(got, '\n'))

	self.enabled = true
	self:insert 'x'
	self:confirm(false)
	eq('abort reports false', false, got)
	eq('abort clears the text', '', self.text)
	h.ok('abort disables the mode', not self.enabled)

	-- result() is the overridable state processing (set at construction:
	-- the instance is a backer, later raw assignment is not supported)
	local up
	local m = new_status_editor {
		result = function(s) return s.text:upper() end,
		on_confirm = function(_, res) up = res end,
	}
	m:insert 'up'
	m:confirm()
	eq('overridable result processing', 'UP', up)
end)

T.parse_chain_reaches_confirm = with_env(function(h)
	-- the reverse chain: a child parse_input sees the parent value first
	local super_parse = editor_mod.parse_input
	local child = new_status_editor {
		parse_input = function(self, arg)
			local parent = super_parse(self, arg)
			if not parent then return false end
			return table.concat(parent, '\n') .. '!'
		end,
		on_confirm = function(_, res) h.eq('child payload reaches on_confirm', 'payload!', res) end,
	}
	child:insert 'payload'
	child:confirm()
	h.ok('confirm disables the mode', not child.enabled)
end)

T.parse_failure_restores_silently = with_env(function(h)
	-- a falsy parse restores without touching on_confirm or the mode
	local calls = 0
	local self = new_status_editor {
		parse_input = function() return false end,
		on_confirm = function() calls = calls + 1 end,
	}
	self:insert 'x'
	self:confirm()
	h.eq('on_confirm never runs', 0, calls)
	h.ok('the mode stays open', self.enabled)
	h.eq('the text stays', 'x', self.text)
	self.enabled = false
end)

T.external_disable_stays_silent = with_env(function(h)
	local got
	local self = new_status_editor { on_confirm = function(_, res) got = res end }
	self:insert 'x'
	self.enabled = false
	h.eq('a plain disable reports nothing', nil, got)
end)

-- bare delete() backspaces without a selection, kills the selection with one
T.bare_delete_defaults = with_env(function(h)
	local self, get = status_of {}
	self:insert 'abc'
	self.col = 2 -- between a and b
	self:delete()
	eq('backspace drops the char before', 'bc', self.text)
	eq('cursor steps back', 1, self.col)
	ok_state(h, 'state valid after backspace', self, get)

	self:delete()
	eq('backspace at the start is a no-op', 'bc', self.text)
	eq('cursor stays', 1, self.col)

	self.text = ''
	self:delete()
	eq('backspace on empty is a no-op', '', self.text)
	eq('cursor stays', 1, self.col)
	ok_state(h, 'state valid on empty', self, get)
	self.enabled = false
end)

-- copy takes exactly the selection (insert/delete treat `to` as exclusive);
-- cut removes the same range; word deletes respect the selection too
T.copy_cut_match_the_selection = with_env(function(h)
	with_clipboard(function(cap)
		local self, get = status_of {}
		self:insert 'abcdef'
		self.col, self.visual = 5, { line = 1, col = 2 } -- selection 'bcd'
		self:copy()
		eq('copy takes the selection', 'bcd', cap[1])
		eq('copy keeps the text', 'abcdef', self.text)

		self:cut()
		eq('cut removes the selection', 'aef', self.text)
		eq('cursor lands at the cut', 2, self.col)
		ok_state(h, 'state valid after cut', self, get)

		self.text = 'one two'
		self.col, self.visual = 4, { line = 1, col = 2 } -- selection 'ne', mid-word
		self:delete_prev_word()
		eq('word delete kills the selection first', 'o two', self.text)

		self.text = 'one two'
		self.col, self.visual = 5, { line = 1, col = 7 } -- selection 'wo', mid-word
		self:delete_next_word()
		eq('forward word delete kills the selection first', 'one o', self.text)
		self.enabled = false
	end)
end)

-- spans across lines: copy joins with newlines, cut lands at the span start
T.multiline_span_copy_cut = with_env(function(h)
	with_clipboard(function(cap)
		local self, get = status_of {}
		self:insert 'ab\ncd\nef'
		self.visual = { line = 1, col = 2 } -- anchor in the first line
		self.line = 3
		self.col = 2 -- cursor in the third: span b\ncd\ne
		self:copy()
		eq('copy joins the span lines', 'b\ncd\ne', cap[1])
		self:cut()
		eq('cut drops the span', 'af', self.text)
		eq('cursor lands at the span start line', 1, self.line)
		eq('cursor lands at the span start column', 2, self.col)
		ok_state(h, 'state valid after span cut', self, get)
		self.enabled = false
	end)
end)

-- shrinking the text clamps the anchor and the cursor into it
T.shrink_clamps_anchor = with_env(function(h)
	local self, get = status_of {}
	self:insert 'ab\ncd\nefgh'
	self.visual = { line = 3, col = 5 }
	self.line = 3
	self.col = 5
	self.text = 'ab'
	eq('anchor line clamps into the text', 1, self.visual.line)
	eq('anchor column clamps into the line', 3, self.visual.col)
	eq('cursor line clamps into the text', 1, self.line)
	eq('cursor column clamps into the line', 3, self.col)
	ok_state(h, 'state valid after shrink', self, get)
	self.enabled = false
end)

-- word deletes without a selection eat the word at the cursor
T.word_deletes = with_env(function(h)
	local self, get = status_of {}
	self:insert 'one two'
	self.col = 8
	self:delete_prev_word()
	eq('backward eats the word', 'one ', self.text)
	eq('cursor at the eaten end', 5, self.col)
	ok_state(h, 'state valid after word delete', self, get)

	self.text = 'one two'
	self.col = 1
	self:delete_next_word()
	eq('forward eats the word and the gap', 'two', self.text)
	eq('cursor holds', 1, self.col)
	self.enabled = false
end)

-- vertical moves keep the column, clamped into short lines
T.vertical_moves_clamp = with_env(function(_)
	local self = new_status_editor {}
	self:insert 'abcdef\nxy\nz'
	self.line = 1
	self.col = 6 -- end of the first line
	self:move_down()
	eq('short line clamps to its end', 3, self.col)
	self:move_down()
	eq('last line clamps to its end', 2, self.col)
	self:move_down()
	eq('bottom holds', 2, self.col)
	self:move_up()
	eq('column kept when it fits', 2, self.col)
	self:move_up()
	eq('the carried offset rules, no goal column', 2, self.col)
	self:move_up()
	eq('top line holds', 2, self.col)
	self.enabled = false
end)

-- empty text and edge columns: every motion and deletion is a safe no-op
T.empty_and_edge_positions = with_env(function(h)
	local self, get = status_of {}
	self:move_left()
	self:move_right()
	self:move_up()
	self:move_down()
	self:move_line_start()
	self:move_line_end()
	self:move_text_start()
	self:move_text_end()
	self:move_prev_word()
	self:move_next_word()
	self:delete_prev_char()
	self:delete_next_char()
	eq('empty text untouched', '', self.text)
	eq('cursor at one', 1, self.col)
	ok_state(h, 'state valid on empty', self, get)

	self:insert 'one two'
	self.col = 1
	self:move_prev_word()
	eq('word back at the start holds', 1, self.col)
	self.col = 8
	self:move_next_word()
	eq('word forward at the end holds', 8, self.col)
	self:move_line_start()
	eq('line start', 1, self.col)
	self:move_line_end()
	eq('line end is exclusive', 8, self.col)
	self:move_text_start()
	eq('text start', 1, self.col)
	self:move_text_end()
	eq('text end', 8, self.col)
	self.enabled = false
end)

---Random operation soup: whatever happens, the text field must stay valid utf8.
T.utf8_invariant_fuzz = with_env(function(h)
	local self, get = status_of {}
	local pool = {
		'',
		'a',
		'X',
		'héllo',
		'釵鐵尺',
		'wörld',
		'\n',
		'multi\nline',
		'☃',
		'😀😀',
		'a\né\n釵',
		-- invalid inputs: must get sanitized on the way in
		'\255',
		'\254x',
		'a\xffb',
		'é\xffé',
		'\xf0\x28\x8c\x28',
	}

	math.randomseed(0xC0FFEE)
	for i = 1, 1000 do
		local op = math.random(7)
		if op == 1 then
			self:insert(pool[math.random(#pool)])
		elseif op == 2 then
			self.col = math.random(0, 20)
		elseif op == 3 then
			if math.random(0, 3) == 0 then
				self.visual = false
			else
				self.visual = { line = math.random(-2, 6), col = math.random(0, 20) }
			end
		elseif op == 4 then
			if self.visual then self:delete() end
		elseif op == 5 then
			local from = math.random(0, 15)
			self:delete(from, from == 0 and 0 or math.random(1, 15))
		elseif op == 6 then
			self.text = pool[math.random(#pool)]
		else
			self.line = math.random(-2, 5)
			self.col = self.col -- writers maintain the pair, like the moves do
		end

		local v = violations(self, get())
		if v then
			h.fail('fuzz iteration ' .. i .. ' broke the invariant: ' .. v, self.text)
			self.enabled = false
			return
		end
	end
	h.pass '1000 fuzz iterations keep the text field valid utf8'
	self.enabled = false
end)

-- the block follows a live location write: the old placement releases,
-- the prompt and the text move to the new one
T.location_move_live = with_env(function(h)
	local self = new_status_editor { _location = 'topleft', _prompt = 'Ask' }
	self:insert 'hello'
	local t = env.swayimg.viewer.text
	h.eq('renders at the entry location', 'Ask', t.topleft[1])
	h.eq('the text under the prompt', 'hello▎', t.topleft[2])
	self.location = 'topright'
	h.ok('the old placement released (the app default shows again)', t.topleft[1] ~= 'Ask')
	h.eq('the prompt follows', 'Ask', t.topright[1])
	h.eq('the text follows', 'hello▎', t.topright[2])
	self.enabled = false
end)

-- paste inserts the clipboard content at the cursor; nothing without one
T.paste_inserts_the_clipboard = with_env(function()
	local S = require 'sai.bridge.shell'
	local old_get = S.clipboard_get
	---@type string?
	local text = 'XY'
	S.clipboard_get = function() return text end
	local ran, err = pcall(function()
		local self = status_of {}
		self:insert 'ab'
		self.col = 2
		self:paste()
		eq('pasted at the cursor', 'aXYb', self.text)
		eq('cursor after the paste', 4, self.col)
		eq('get_text reads the lines joined', 'aXYb', self:get_text())

		text = nil
		self:paste()
		eq('no clipboard: no change', 'aXYb', self.text)
		self.enabled = false
	end)
	S.clipboard_get = old_get
	if not ran then error(err, 0) end
end)

-- select_all spans the whole input: copy takes it all
T.select_all_copies_everything = with_env(function()
	with_clipboard(function(cap)
		local self = status_of {}
		self:insert 'ab\ncd'
		self:select_all()
		self:copy()
		eq('the whole text copied', 'ab\ncd', cap[1])
		self.enabled = false
	end)
end)

-- map_filter keeps typing keys on the editor, command keys decline to
-- the fallback: capitals and modifiers are not input
T.map_filter_routes_command_keys = with_env(function(h)
	local self = new_status_editor {}
	local filter = editor_mod.map_filter
	h.ok('a letter types', filter 'a')
	h.ok('ctrl declines', not filter 'Ctrl+x')
	h.ok('alt declines', not filter 'Alt+x')
	h.ok('a named key declines', not filter 'Return')
	h.ok('a function key declines', not filter 'F13')
	self.enabled = false
end)

-- ---------------------------------------------------------------------------
-- History integration: the cycle itself is covered by tests/history.lua
-- ---------------------------------------------------------------------------

T.history_cycle_through_binds = with_env(function()
	local m = new_status_editor { history = { 'echo one', 'echo two' } }
	H.press(raw_binds, 'Up')
	eq('Up recalls the newest entry', 'echo one', m.text)
	H.press(raw_binds, 'Up')
	eq('Up again recalls the older entry', 'echo two', m.text)
	H.press(raw_binds, 'Down')
	eq('Down walks back to the newer entry', 'echo one', m.text)
	H.press(raw_binds, 'Down')
	eq('Down past newest restores the typed text', '', m.text)
	H.press(raw_binds, 'Down')
	eq('Down at the prompt holds', '', m.text)
	m.enabled = false
end)

T.history_recall_keeps_cursor = with_env(function()
	local m = new_status_editor { history = { 'echo one', 'echo two' } }
	m.text = 'ec'
	eq('cursor before the recall', 3, m.col)
	H.press(raw_binds, 'Up')
	eq('Up recalls the newest entry', 'echo one', m.text)
	eq('cursor holds through the recall', 3, m.col)
	H.press(raw_binds, 'Up')
	eq('same prefix goes deeper', 'echo two', m.text)
	eq('cursor still holds', 3, m.col)
	m.enabled = false
end)

T.history_match_uses_text_before_cursor = with_env(function()
	local m = new_status_editor { history = { 'echo one', 'print echo' } }
	m.text = 'echo'
	m.col = 3 -- only 'ec' is before the cursor
	H.press(raw_binds, 'Up')
	eq('Up matches the prefix, not the whole text', 'echo one', m.text)
	m.enabled = false
end)

-- Up/Down move the cursor line on multiline input, the history stays out
T.history_multiline_gate = with_env(function()
	local m = new_status_editor { history = { 'one' } }
	m:insert 'a\nb'
	eq('cursor on the last line', 2, m.line)
	H.press(raw_binds, 'Up')
	eq('Up moves the cursor a line up', 1, m.line)
	eq('the multiline text is untouched', 'a\nb', m.text)
	H.press(raw_binds, 'Down')
	eq('Down moves the cursor a line down', 2, m.line)
	m.enabled = false
end)

T.history_recalled_multiline_keeps_cursor = with_env(function()
	local m = new_status_editor { history = { 'a\nb' } }
	H.press(raw_binds, 'Up')
	eq('Up recalls the multiline entry', 'a\nb', m.text)
	eq('cursor stays on its line', 1, m.line)
	eq('cursor stays at its column', 1, m.col)
	H.press(raw_binds, 'Up')
	eq('Up over multiline moves the line, not the history', 1, m.line)
	eq('the recalled entry stays', 'a\nb', m.text)
	m.enabled = false
end)

-- the verdict gates the filing: only `true` records
T.history_confirm_files = with_env(function(h)
	local m = new_status_editor {
		history = { 'one', 'two', 'three' },
		on_confirm = function() return true end,
	}
	m.text = 'three'
	m:confirm()
	h.eq('true verdict files the input', 'three', m.history[1])
	h.eq('re-confirm moves the entry to the top', 3, #m.history)
	h.eq('confirm clears the input', '', m.text)
	h.ok('confirm disables the mode', not m.enabled)

	m.enabled = true
	m.history = Hist.new {}
	---@diagnostic disable-next-line: duplicate-set-field
	m.on_confirm = function() return false end
	m.text = 'keep me'
	m:confirm()
	h.eq('false verdict records nothing', 0, #m.history)
	h.ok('false verdict stays open', m.enabled)

	---@diagnostic disable-next-line: duplicate-set-field
	m.on_confirm = function() return true end
	m.text = 'local a = 1'
	m:confirm(false)
	h.eq('aborted input not recorded', 0, #m.history)
	h.eq('abort clears the input', '', m.text)

	m.text = ''
	m:confirm()
	h.eq('empty input not recorded', 0, #m.history)
	m.enabled = false
end)

-- history=false: no recall, nothing files, confirm still works
T.history_disabled = with_env(function(h)
	local m = new_status_editor { history = false, on_confirm = function() return true end }
	m.text = 'ec'
	H.press(raw_binds, 'Up')
	h.eq('Up with history off holds the text', 'ec', m.text)
	H.press(raw_binds, 'Down')
	h.eq('Down with history off holds the text', 'ec', m.text)
	m:confirm()
	h.ok('confirm still closes', not m.enabled)
	h.eq('nothing filed', false, m.history)
end)

H.maybe_standalone(T)

return T
