---@diagnostic disable: invisible, undefined-field
---@module 'swi.binds'

local U = require 'swi.lib.utils'

local M = {}

local g = swi.gallery
local v = swi.viewer
local s = swi.slideshow
local t = swi.text
local l = swi.imagelist

---@alias bindmode
---| 'v' # viewer mode
---| 's' # slideshow mode
---| 'g' # gallery mode
---| '' # slideshow and viewer modes
---| 'a' # all modes

---@type {[string]:{[integer]:swi.lib.keybind_processor|keybind_processor}}
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

	-- Custom keybind for our own help mode
	map(
		'a',
		{ 'F1', U.key_map['?'] },
		function() require('swi.mode.help').enabled = not require('swi.mode.help').enabled end,
		'Toggle help'
	)

	-- Global keybinds
	map('a', 'Return', function() swi.mode = swi.mode == 'gallery' and 'viewer' or 'gallery' end, 'Toggle viewer')
	map('a', 'Escape', swi.exit, 'Exit application')
	map('a', 's', function() swi.mode = swi.mode == 'slideshow' and 'viewer' or 'slideshow' end, 'Toggle slideshow')
	map('a', 'Insert', function() l.marked.set_current 'toggle' end, 'Toggle mark on current entry')
	map('a', 'f', function() swi.fullscreen = not swi.fullscreen end, 'Toggle fullscreen')
	map('a', 'a', function() swi.antialiasing = not swi.antialiasing end, 'Toggle antialiasing')

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
	gmap('MouseLeft', function() swi.mode = 'viewer' end, 'Switch to viewer')

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
		local m = swi.get_mouse_pos()
		v.scale_centered(s, m.x, m.y)
	end, 'Zoom in on cursor')
	vmap('Ctrl+ScrollDown', function()
		local s = v.get_abs_scale() / 1.1
		local m = swi.get_mouse_pos()
		v.scale_centered(s, m.x, m.y)
	end, 'Zoom out at cursor')
end

---@param self swi.mode.help
function M.help(self)
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })

	map({ 'Right', 'Tab' }, function() self.tab = self.tab + 1 end, 'Next help tab')
	map({ 'Left', 'Shift+Tab' }, function() self.tab = self.tab - 1 end, 'Previous help tab')
	map({ 'Up', 'ScrollUp' }, function() self.pager.line = self.pager.line - 1 end, 'Scroll up')
	map({ 'Down', 'ScrollDown' }, function() self.pager.line = self.pager.line + 1 end, 'Scroll down')
	map('Prior', function() self.pager.line = self.pager.line - self.pager.page_size end, 'Page up')
	map('Next', function() self.pager.line = self.pager.line + self.pager.page_size end, 'Page down')
	map({ 'Escape', 'q' }, function() self.enabled = false end, 'Exit help overlay')
end

---@param self swi.mode.input
function M.input(self)
	-- Important actions that should be displayed in help list
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map('Return', function() self:confirm() end, 'Confirm input')
	map('Escape', function() self:confirm(false) end, 'Abort input')
	map('Ctrl+Escape', function() self.enabled = false end, 'Hide mode')

	-- Make mappings invisible in help lists
	map = M.gen_mapadd(self, { kind = 'private', _wrapped = true })

	-- Clipboard management
	map('Ctrl+a', function()
		self._visual = 1
		self.col = #self.text + 1
	end, 'Select all')
	map('Ctrl+x', function()
		local from, to = self._col, self._visual
		if not to then return end
		if from > to then
			from, to = to, from
		end
		U.clipboard_set(self._text:sub(from, to))
		self:insert ''
	end, 'Cut to clipboard')
	map('Ctrl+c', function()
		local from, to = self._col, self._visual
		if not to then return end
		if from > to then
			from, to = to, from
		end
		U.clipboard_set(self._text:sub(from, to))
		self.visual = false
	end, 'Copy selection')
	map('Ctrl+v', function()
		local text = U.clipboard_get()
		if text then self:insert(text) end
	end, 'Paste from clipboard')

	-- Deleting text
	map('BackSpace', function() self:delete(not self._visual and self._col - 1) end, 'Delete prev char')
	map('Delete', function() self:delete(not self._visual and self._col) end, 'Delete next char')
	local function get_word_idx(text, col, backward)
		if backward then
			return text:sub(1, col):find '%w*%W*$', col
		else
			return col, select(2, text:sub(col):find '^%W*%w*') + col
		end
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
	add_move(
		'Ctrl+Right',
		function() self.col = select(2, self._text:sub(self._col):find '^%w*%W*') + self._col end,
		'next word'
	)
	add_move('Left', function() self.col = self._col - 1 end)
	add_move('Right', function() self.col = self._col + 1 end)
	add_move('Up', function() self.line = self.line - 1 end)
	add_move('Down', function() self.line = self.line + 1 end)
	add_move('End', function() self.col = self:get_current_line_info().to end, 'line end')
	add_move('Ctrl+End', function() self.col = #self.text + 1 end, 'text end')
	add_move('Home', function() self.col = self:get_current_line_info().from end, 'line start')
	add_move('Ctrl+Home', function() self.col = 1 end, 'text start')
end

---@param self swi.mode.filter
function M.filter(self)
	self.map('Shift+Return', '\n')

	-- Important actions that should be displayed in help list
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map('Ctrl+j', function() self.selected_pos = self.selected_pos + 1 end, 'next filtered image')
	map('Ctrl+k', function() self.selected_pos = self.selected_pos - 1 end, 'prev filtered image')
	map('Tab', function()
		local cl = self.completion.lines
		if not cl[1] or not self.completion.enabled then return end
		local li = self:get_current_line_info()
		self._visual = li.from
		self._col = li.to
		self:insert(cl[1])
	end, 'Complete tag')
end

---@param self swi.mode.cmd
function M.cmd(self)
	self.map('Shift+Return', '\n')

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

---@private
--- Support function for generating updater of default keybinds.
---@param modeapi keybind_processor|swi.lib.keybind_processor
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

return M
