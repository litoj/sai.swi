---@diagnostic disable: invisible, undefined-field
---@module 'sai.binds'

local U = require 'sai.lib.utils'
local utf8 = require 'sai.bridge.utf8'

local M = {}

local g = sai.gallery
local v = sai.viewer
local s = sai.slideshow
local t = sai.text
local l = sai.imagelist

---@alias bindmode
---| 'v' # viewer mode
---| 's' # slideshow mode
---| 'g' # gallery mode
---| '' # slideshow and viewer modes
---| 'a' # all modes

---@type {[string]:{[integer]:sai.lib.keybind_processor|keybind_processor}}
M.modemap = { [''] = { v, s }, a = { v, s, g }, g = { g }, v = { v }, s = { s } }

---@param mode bindmode
---@param binds string|string[]
---@param cb string|fun()
---@param desc string?
function M.map(mode, binds, cb, desc)
	for _, m in ipairs(M.modemap[mode]) do
		m.map(binds, cb, desc)
	end
end

function M.default()
	local deftrace = U.pretty_trace('default', debug.traceback())
	local function map(mode, binds, cb, desc)
		local cfg = { cb = cb, desc = desc, default = true, trace = deftrace, _traced = true }
		for _, m in ipairs(M.modemap[mode]) do
			for _, b in ipairs(U.tabled(binds)) do
				if not m._mappings[b] then m:_setmap(b, cfg) end
			end
		end
	end
	for _, m in ipairs { v, s, g } do ---@cast m sai.api.viewer
		-- clear the native bindings of all mapped keypad keys
		-- so that we rely on the fallback function rather than hardcoded identical defaults
		for _, b in ipairs {
			'KP_Enter',
			'KP_Space',
			'KP_Tab',
			'KP_Insert',
			'KP_Delete',
			'KP_Home',
			'KP_End',
			'KP_Prior',
			'KP_Next',
			'KP_Left',
			'KP_Up',
			'KP_Right',
			'KP_Down',
			'KP_Add',
			'KP_Subtract',
			'KP_Multiply',
			'KP_Divide',
			'KP_Decimal',
			'KP_Equal',
		} do
			if not m._mappings[b] then m:_rawunmap(b) end
		end
	end

	-- Custom keybinds for our own help modes
	map(
		'a',
		{ 'F1', 'question' },
		function() require('sai.mode.key_help').enabled = not require('sai.mode.key_help').enabled end,
		'Toggle key help'
	)
	map(
		'a',
		'Shift+F1',
		function() require('sai.mode.var_help').enabled = not require('sai.mode.var_help').enabled end,
		'Toggle var help'
	)
	map(
		'a',
		'Shift+F6',
		function() sai.notify('Started debug ipc on: ' .. require('sai.bridge.debug').start {}) end,
		'Start debug ipc'
	)

	-- Global keybinds
	map('a', 'Return', function() sai.mode = sai.mode == 'gallery' and 'viewer' or 'gallery' end, 'Toggle viewer')
	map('a', 'Escape', sai.exit, 'Exit application')
	map('a', 's', function() sai.mode = sai.mode == 'slideshow' and 'viewer' or 'slideshow' end, 'Toggle slideshow')
	map('a', 'Insert', function() l.marked.set_current 'toggle' end, 'Toggle mark on current entry')
	map('a', 'f', function() sai.fullscreen = not sai.fullscreen end, 'Toggle fullscreen')
	map('a', 'a', function() sai.antialiasing = not sai.antialiasing end, 'Toggle antialiasing')

	-- Gallery
	local gmap = function(binds, cb, desc)
		local cfg = { cb = cb, desc = desc, default = true, trace = deftrace, _traced = true }
		for _, b in ipairs(U.tabled(binds)) do
			if not g._mappings[b] then g:_setmap(b, cfg) end
		end
	end
	-- scale
	gmap(
		{ 'equal', 'Shift+plus', 'Ctrl+ScrollUp' },
		function() g.thumb_size = math.floor(g.thumb_size * 1.1 + 0.5) end,
		'Increase thumbnail size'
	)
	gmap(
		{ 'minus', 'Ctrl+ScrollDown' },
		function() g.thumb_size = math.floor(g.thumb_size / 1.1 + 0.5) end,
		'Decrease thumbnail size'
	)
	-- image selection
	local ggo = g.go
	gmap('Home', ggo.first, 'Go first')
	gmap('End', ggo.last, 'Go last')
	gmap({ 'Left', 'ScrollLeft' }, ggo.left, 'Go left')
	gmap({ 'Right', 'ScrollRight' }, ggo.right, 'Go right')
	gmap({ 'Up', 'ScrollUp' }, ggo.up, 'Go up')
	gmap({ 'Down', 'ScrollDown' }, ggo.down, 'Go down')
	gmap('Next', ggo.pgdown, 'Page down')
	gmap('Prior', ggo.pgup, 'Page up')
	-- text layer
	gmap('t', function() t.enabled = not t.enabled end, 'Toggle text')
	-- mouse bindings as keys
	gmap('MouseLeft', function()
		local pos = sai.get_mouse_pos()
		g.go(pos.x, pos.y)
		sai.mode = 'viewer'
	end, 'Switch to viewer')

	-- Viewer
	local vmap = function(binds, cb, desc)
		local cfg = { cb = cb, desc = desc, default = true, trace = deftrace, _traced = true }
		for _, b in ipairs(U.tabled(binds)) do
			if not v._mappings[b] then v:_setmap(b, cfg) end
		end
	end
	-- Image transforms
	vmap('bracketleft', function() v.rotate(270) end, 'Rotate left')
	vmap('bracketright', function() v.rotate(90) end, 'Rotate right')
	vmap('m', v.flip_vertical, 'Flip vertical')
	vmap('Shift+m', v.flip_horizontal, 'Flip horizontal')
	-- Text overlay toggle
	vmap('t', function() t.enabled = not t.enabled end, 'Toggle text')
	-- Image navigation
	vmap('Home', v.go.first, 'Go first')
	vmap('End', v.go.last, 'Go last')
	vmap('Next', v.go.next, 'Go next')
	vmap('Prior', v.go.prev, 'Go prev')
	-- Frame navigation
	vmap('Shift+Next', v.next_frame, 'Next frame')
	vmap('Shift+Prior', v.prev_frame, 'Previous frame')
	-- Scale (zoom)
	vmap({ 'equal', 'Shift+plus', 'Ctrl+ScrollUp' }, function() v.scale = v.get_abs_scale() * 1.1 end, 'Zoom in')
	vmap({ 'minus', 'Ctrl+ScrollDown' }, function() v.scale = v.get_abs_scale() / 1.1 end, 'Zoom out')
	vmap('BackSpace', v.reset, 'Reset scale and position')
	-- Image position / panning
	vmap('Left', v.pan.left, 'Pan left')
	vmap('Right', v.pan.right, 'Pan right')
	vmap('Up', v.pan.up, 'Pan up')
	vmap('Down', v.pan.down, 'Pan down')
	vmap('ScrollUp', function() v.pan.up(20) end, 'Pan up 20px')
	vmap('ScrollDown', function() v.pan.down(20) end, 'Pan down 20px')
	vmap('ScrollLeft', function() v.pan.left(20) end, 'Pan left 20px')
	vmap('ScrollRight', function() v.pan.right(20) end, 'Pan right 20px')
	-- Mouse zoom (centered at pointer)
	vmap('Ctrl+ScrollUp', function()
		local s = v.get_abs_scale() * 1.1
		local m = sai.get_mouse_pos()
		v.scale_centered(s, m.x, m.y)
	end, 'Zoom in on cursor')
	vmap('Ctrl+ScrollDown', function()
		local s = v.get_abs_scale() / 1.1
		local m = sai.get_mouse_pos()
		v.scale_centered(s, m.x, m.y)
	end, 'Zoom out at cursor')
end

---@private
--- Support function for generating updater of default keybinds.
---@param modeapi keybind_processor|sai.lib.keybind_processor
---@param defaults? bindcfg|{}
---@return fun(b:string|string[], action:fun(), desc:string)
function M.gen_mapadd(modeapi, defaults)
	local deftrace = U.pretty_trace('custom_map', debug.traceback())
	defaults = defaults or {}
	defaults.trace = deftrace
	---@diagnostic disable-next-line: inject-field
	defaults._traced = true

	return function(binds, cb, desc)
		local cfg = U.soft_copy(defaults)
		cfg.cb = cb
		cfg.desc = desc
		if binds[1] then
			for _, b in ipairs(binds) do
				if not modeapi._mappings[b] then modeapi._mappings[b] = cfg end
			end
		else
			if not modeapi._mappings[binds] then modeapi._mappings[binds] = cfg end
		end
	end
end

---@param self sai.mode.help
function M.help(self)
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })

	map('Tab', function() self.tab = self.tab + 1 end, 'Next help tab')
	map('Shift+ISO_Left_Tab', function() self.tab = self.tab - 1 end, 'Previous help tab')
	map({ 'Up', 'ScrollUp' }, function() self.pager.line = self.pager.line - 1 end, 'Scroll up')
	map({ 'Down', 'ScrollDown' }, function() self.pager.line = self.pager.line + 1 end, 'Scroll down')
	map('Prior', function() self.pager.line = self.pager.line - self.pager.page_size end, 'Page up')
	map('Next', function() self.pager.line = self.pager.line + self.pager.page_size end, 'Page down')
	map({ 'Escape', 'q' }, function() self.enabled = false end, 'Exit help overlay')
end

---@param self sai.mode.input
function M.input(self)
	-- Important actions that should be displayed in help list
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map('Return', function() self:confirm() end, 'Confirm input')
	map('Escape', function() self:confirm(false) end, 'Abort input')
	map('Ctrl+Escape', function() self.enabled = false end, 'Hide mode')

	-- Make mappings invisible in help lists
	map = M.gen_mapadd(self, { kind = 'private', _wrapped = true })

	local S = require 'sai.bridge.shell'
	-- Clipboard management
	map('Ctrl+a', function()
		self._visual = 1
		self.col = utf8.len(self.text) + 1
	end, 'Select all')
	local set = function()
		local from, to = self._col, self._visual
		if not to then return end
		if from > to then
			from, to = to, from
		end
		S.clipboard_set(utf8.sub(self._text, from, to))
	end
	map('Ctrl+x', function()
		set()
		self:insert ''
	end, 'Cut to clipboard')
	map('Ctrl+c', function()
		set()
		self.visual = false
	end, 'Copy to clipboard')
	map('Ctrl+v', function()
		local text = S.clipboard_get()
		if text then self:insert(text) end
	end, 'Paste from clipboard')

	-- Deleting text
	map('BackSpace', function() self:delete(not self._visual and self._col - 1) end, 'Delete prev char')
	map('Delete', function() self:delete(not self._visual and self._col) end, 'Delete next char')

	-- utf8-aware word scanning: ASCII %w plus any non-ASCII codepoint counts as a word char
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
	map('Ctrl+BackSpace', function() self:delete(get_word_idx(self._text, self._col - 1, true)) end, 'Delete prev word')
	map('Ctrl+Delete', function() self:delete(get_word_idx(self._text, self._col)) end, 'Delete next word')

	-- Allow moving around taking text selection into account
	local function add_move(key, fn, direction)
		direction = direction or key:lower()
		map(key, function()
			if self._visual then self._visual = false end
			fn()
		end, 'Move ' .. direction)
		map('Shift+' .. key, function()
			if not self._visual then self._visual = self._col end
			fn()
		end, 'Select ' .. direction)
	end

	add_move('Ctrl+Left', function() self.col = get_word_idx(self._text, self._col - 1, true) end, 'prev word')
	add_move('Ctrl+Right', function()
		local isw = word_flags(self._text)
		local i, n = self._col, #isw
		while i <= n and isw[i] do
			i = i + 1
		end
		while i <= n and not isw[i] do
			i = i + 1
		end
		self.col = i
	end, 'next word')
	add_move('Left', function() self.col = self._col - 1 end)
	add_move('Right', function() self.col = self._col + 1 end)
	add_move('Up', function() self.line = self.line - 1 end)
	add_move('Down', function() self.line = self.line + 1 end)
	add_move('End', function() self.col = self:get_current_line_info().to end, 'line end')
	add_move('Ctrl+End', function() self.col = utf8.len(self.text) + 1 end, 'text end')
	add_move('Home', function() self.col = self:get_current_line_info().from end, 'line start')
	add_move('Ctrl+Home', function() self.col = 1 end, 'text start')
end

---@param self sai.mode.filter
function M.filter(self)
	self.map('Shift+Return', '\n', 'Newline')

	-- Important actions that should be displayed in help list
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map('Ctrl+j', function() self.selected_pos = self.selected_pos + 1 end, 'next filtered image')
	map('Ctrl+k', function() self.selected_pos = self.selected_pos - 1 end, 'prev filtered image')
	map('Tab', function() self:complete() end, 'Complete tag')
end

---@param self sai.mode.cmd
function M.cmd(self)
	self.map('Shift+Return', '\n', 'Newline')

	self.map('Up', function()
		if self.text:find('\n', 1, true) then
			self.line = self.line - 1
		else
			self:hist_prev()
		end
	end)
	self.map('Down', function()
		if self.text:find('\n', 1, true) then
			self.line = self.line + 1
		else
			self:hist_next()
		end
	end)
end

return M
