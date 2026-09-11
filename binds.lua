---@diagnostic disable: invisible, missing-fields
---@module 'sai.binds'

local U = require 'sai.lib.utils'
local B = require 'sai.lib.bindmods'
local section = require 'sai.api.section'

local M = {}

function M.default()
	local g = sai.gallery
	local v = sai.viewer
	local s = sai.slideshow
	local t = sai.text
	local l = sai.imagelist
	local modemap = { [''] = { v, s }, a = { v, s, g }, g = { g }, v = { v }, s = { s } }

	local deftrace = U.pretty_trace('default', debug.traceback())
	local function map(mode, binds, cb, desc)
		local cfg = { cb = cb, desc = desc, kind = 'default', trace = deftrace, _traced = true }
		for _, m in ipairs(modemap[mode]) do
			for _, b in ipairs(U.tabled(binds)) do
				if not m._mappings[b] then m:_setmap(b, cfg) end
			end
		end
	end
	-- Custom keybinds for our own help modes
	map('a', { 'F1', 'question' }, require('sai.mode.key_help').cycle, 'Cycle key help')
	map(
		'a',
		'Shift+F1',
		function() require('sai.mode.var_help').enabled = not require('sai.mode.var_help').enabled end,
		'Toggle var help'
	)
	map(
		'a',
		'F2',
		function() require('sai.mode.text_adjust').enabled = not require('sai.mode.text_adjust').enabled end,
		'Toggle text adjust'
	)
	map(
		'a',
		'Shift+F6',
		function() sai.notify('Started debug ipc on: ' .. require('sai.bridge.debug').start {}) end,
		'Start debug ipc'
	)
	local snip = require 'sai.snippets'
	local cmd = snip.lua_mode()
	map('a', ':', function() cmd.enabled = not cmd.enabled end, 'Lua mode')
	local shell = snip.shell_mode()
	map('a', 'Shift+s', function() shell.enabled = not shell.enabled end, 'Shell mode')

	-- Global keybinds
	map('a', 'Return', function() sai.mode = sai.mode == 'gallery' and 'viewer' or 'gallery' end, 'Toggle viewer')
	map('a', 'Escape', sai.exit, 'Exit application')
	map('a', 's', function() sai.mode = sai.mode == 'slideshow' and 'viewer' or 'slideshow' end, 'Toggle slideshow')
	map('a', 'Insert', function() l.marked.set_current 'toggle' end, 'Toggle mark on current entry')
	map('a', 'f', function() sai.fullscreen = not sai.fullscreen end, 'Toggle fullscreen')
	map('a', 'a', function() sai.antialiasing = not sai.antialiasing end, 'Toggle antialiasing')

	-- Gallery
	-- scale
	map('g', { 'equal', 'Shift+plus' }, function() g.thumb_size = g.thumb_size * 1.1 end, 'Increase thumbnail size')
	map('g', 'minus', function() g.thumb_size = g.thumb_size / 1.1 end, 'Decrease thumbnail size')
	map('g', 'Ctrl+ScrollVertical', function(mv) g.thumb_size = g.thumb_size * (1 - mv * 0.03) end, 'Adjust thumb size')
	-- image selection
	local ggo = g.go
	map('g', 'Home', ggo.first, 'Go first')
	map('g', 'End', ggo.last, 'Go last')
	map('g', { 'Left', 'ScrollLeft' }, ggo.left, 'Go left')
	map('g', { 'Right', 'ScrollRight' }, ggo.right, 'Go right')
	map('g', { 'Up', 'ScrollUp' }, ggo.up, 'Go up')
	map('g', { 'Down', 'ScrollDown' }, ggo.down, 'Go down')
	map('g', 'Next', ggo.pgdown, 'Page down')
	map('g', 'Prior', ggo.pgup, 'Page up')
	-- text layer
	map('g', 't', function() t.enabled = not t.enabled end, 'Toggle text')
	-- mouse bindings as keys
	map('g', 'MouseLeft', function()
		local pos = sai.get_mouse_pos()
		g.go(pos.x, pos.y)
		sai.mode = 'viewer'
	end, 'Switch to viewer')

	-- Viewer
	for k, v in pairs { v = v, s = s } do
		-- Image transforms
		map(k, 'bracketleft', function() v.rotate(270) end, 'Rotate left')
		map(k, 'bracketright', function() v.rotate(90) end, 'Rotate right')
		map(k, 'm', v.flip_vertical, 'Flip vertical')
		map(k, 'Shift+m', v.flip_horizontal, 'Flip horizontal')
		-- Text oevrlay toggle
		map(k, 't', function() t.enabled = not t.enabled end, 'Toggle text')
		-- Image naigation
		map(k, 'Home', v.go.first, 'Go first')
		map(k, 'End', v.go.last, 'Go last')
		map(k, 'Next', v.go.next, 'Go next')
		map(k, 'Prior', v.go.prev, 'Go prev')
		-- Frame naigation
		map(k, 'Shift+Next', function() v.frame = v.frame + 1 end, 'Next frame')
		map(k, 'Shift+Prior', function() v.frame = v.frame - 1 end, 'Previous frame')
		-- Scale (zoom)
		map(k, { 'equal', 'Shift+plus' }, function() v.scale = v.get_abs_scale() * 1.1 end, 'Zoom in')
		map(k, 'minus', function() v.scale = v.get_abs_scale() / 1.1 end, 'Zoom out')
		-- the wheel zooms raw: proportional to the vertical magnitude
		map(k, 'Ctrl+ScrollVertical', function(mv) v.scale = v.get_abs_scale() * (1 - mv * 0.05) end, 'Zoom by scroll')
		map(k, 'BackSpace', v.reset, 'Reset scale and position')
		-- Image position / panning
		map(k, 'Left', v.pan.left, 'Pan left')
		map(k, 'Right', v.pan.right, 'Pan right')
		map(k, 'Up', v.pan.up, 'Pan up')
		map(k, 'Down', v.pan.down, 'Pan down')
		map(k, 'Scroll', function(mh, mv) v.pan.by(mh * 10, mv * 10) end, 'Pan by scroll')
	end
end

---@private
---@generic O: keybind_processor
---@param modeapi sai.lib.keybind_processor|`O`
---@param defaults? bindcfg|{}
---@return fun(b:string|string[], action:fun(O, ...), desc:string?)
function M.gen_mapadd(modeapi, defaults)
	defaults = defaults or {}
	---@diagnostic disable-next-line: inject-field
	defaults._traced = true

	return function(binds, cb, desc)
		local cfg = U.soft_copy(defaults)
		cfg.cb = cb
		cfg.desc = desc
		-- the declaration site: our own frame is first, every caller
		-- names it `map`, so trim through it
		cfg.trace = U.pretty_trace("in function 'map", debug.traceback())
		if binds[1] then
			for _, b in ipairs(binds) do
				b = B.canonical(b)
				if not modeapi._mappings[b] then modeapi._mappings[b] = cfg end
			end
		else
			local b = B.canonical(binds)
			if not modeapi._mappings[b] then modeapi._mappings[b] = cfg end
		end
	end
end

---@param self sai.mode.help
function M.help(self)
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })

	map('Tab', function() self.tab = self.tab + 1 end, 'Next help tab')
	map('Shift+ISO_Left_Tab', function() self.tab = self.tab - 1 end, 'Previous help tab')
	map({ 'Escape', 'q' }, function() self.enabled = false end, 'Exit help overlay')
	map('/', function() self:open_filter() end, 'Filter the listing')
end

---Keyboard scrolling binds of a pager that owns its input.
---@param p sai.lib.pager a full overlay mode's display; the wheel is its own block bind
function M.pager_scrolls(p)
	local map = M.gen_mapadd(p, { kind = 'private' })
	map({ 'Up', 'k' }, function(p) p.scroll = p.scroll - 1 end)
	map({ 'Down', 'j' }, function(p) p.scroll = p.scroll + 1 end)
	map('Prior', function(p) p.scroll = p.scroll - p.page_size end)
	map('Next', function(p) p.scroll = p.scroll + p.page_size end)
end

---Navigation of a help window: window scrolls idle, line cursor walks
---while the status filter narrows the listing; confirming runs the line.
---The wheel always scrolls the window, like every other pager.
---@param p sai.mode.help.pager the help window over the listing
function M.help_pager(p)
	p.map(section.key(p._location, 'ScrollUp'), function() p.scroll = p.scroll - 1 end, { kind = 'private' })
	p.map(section.key(p._location, 'ScrollDown'), function() p.scroll = p.scroll + 1 end, { kind = 'private' })
	local map = M.gen_mapadd(p, { kind = 'private' })
	local function step(delta)
		if p._filtering then
			p:move(delta)
		else
			p.scroll = p.scroll + delta
		end
	end
	map({ 'Up', 'k' }, function() step(-1) end)
	map({ 'Down', 'j' }, function() step(1) end)
	map('Prior', function() step(-p.page_size) end)
	map('Next', function() step(p.page_size) end)
	map('Return', function() p:confirm() end)
end

---@param self sai.mode.selector
function M.selector(self)
	-- the wheel and the clicks own the window's block: the binds
	-- declare its code, so they follow the block
	self.map(section.key(self._location, 'ScrollUp'), function() self:move(-1) end, { kind = 'private' })
	self.map(section.key(self._location, 'ScrollDown'), function() self:move(1) end, { kind = 'private' })

	if self.component then return end
	self.map(section.key(self._location, 'MouseLeft'), function() self:select_at_mouse() end, { kind = 'private' })
	self.map('2+' .. section.key(self._location, 'MouseLeft'), function(row, _)
		if row then self:select_at_mouse() end
		self:confirm()
	end, { kind = 'private' })

	-- Important actions that should be displayed in help list
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map('Return', function() self:confirm() end, 'Confirm')
	map('Escape', function() self:confirm(false) end, 'Abort')
	map('Ctrl+Escape', function() self.enabled = false end, 'Hide mode')

	-- Make mappings invisible in help lists
	map = M.gen_mapadd(self, { kind = 'private', _wrapped = true })

	local s = self
	-- plain list navigation: obvious keys - kept out of the help lists
	map('Up', function() s:move(-1) end)
	map('Down', function() s:move(1) end)
	map('Prior', function() s:move(-s.page_size) end)
	map('Next', function() s:move(s.page_size) end)
	map('Home', function() s.line = 1 end)
	map('End', function() s.line = #s.lines end)
	if not s.single_select then map('Tab', function() s:toggle_select() end, 'Toggle select') end
end

---@param self sai.mode.editor
function M.editor(self)
	self.map('Shift+Return', function() self:insert '\n' end, 'Newline')

	-- Make mappings invisible in help lists
	local map = M.gen_mapadd(self, { kind = 'private', _wrapped = true })

	-- Clipboard management
	map('Ctrl+a', function() self:select_all() end)
	map('Ctrl+x', function() self:cut() end)
	map('Ctrl+c', function() self:copy() end)
	map('Ctrl+v', function() self:paste() end)

	-- Deleting text
	map('BackSpace', function() self:delete_prev_char() end)
	map('Delete', function() self:delete_next_char() end)
	map('Ctrl+BackSpace', function() self:delete_prev_word() end)
	map('Ctrl+Delete', function() self:delete_next_word() end)

	-- Allow moving around taking text selection into account.
	-- Overwrite through self.map: the helper above keeps the first
	-- bind, so the inherited selector nav would silently keep End/Home.
	local function add_move(key, method)
		self.map(key, function() method(self) end, { kind = 'private', _wrapped = true })
		self.map('Shift+' .. key, function() method(self, true) end, { kind = 'private', _wrapped = true })
	end

	add_move('Ctrl+Left', self.move_prev_word)
	add_move('Ctrl+Right', self.move_next_word)
	add_move('Left', self.move_left)
	add_move('Right', self.move_right)
	add_move('End', self.move_line_end)
	add_move('Ctrl+End', self.move_text_end)
	add_move('Home', self.move_line_start)
	add_move('Ctrl+Home', self.move_text_start)

	-- Up/Down cycle the history on a single line, move the cursor line on
	-- multiline; Shift keeps extending the selection
	self.map('Up', function()
		if self.text:find('\n', 1, true) then
			self:move_up()
		else
			self:hist_prev()
		end
	end, 'History previous (move up in multiline)')
	self.map('Down', function()
		if self.text:find('\n', 1, true) then
			self:move_down()
		else
			self:hist_next()
		end
	end, 'History next (move down in multiline)')
	map('Shift+Up', function() self:move_up(true) end)
	map('Shift+Down', function() self:move_down(true) end)
end

---@param self sai.mode.completion
function M.completion(self)
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map('Tab', function() self:confirm() end, 'Accept completion')
	map('Ctrl+j', function() self:move(1) end, 'Next completion')
	map('Ctrl+k', function() self:move(-1) end, 'Previous completion')

	-- clicking a menu entry is obvious: kept out of the help lists
	self.map(
		section.key(self._location, 'MouseLeft'),
		function() self:select_at_mouse() end,
		{ kind = 'private', _wrapped = true }
	)
end

---@param self sai.mode.image_filter
function M.image_filter(self)
	-- Important actions that should be displayed in help list
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map('Ctrl+n', function() self.selected_pos = self.selected_pos + 1 end, 'next filtered image')
	map('Ctrl+p', function() self.selected_pos = self.selected_pos - 1 end, 'prev filtered image')

	-- the results list: a click takes the cursor to the clicked match,
	-- the same image the wheel lands on
	if self.results_list then
		self.results_list.map('BL+MouseLeft', function(row, _)
			if not row then return end
			local list = self.results_list ---@cast list sai.mode.selector<string>
			list:select_at_mouse()
			self:set_selected_pos(list.line)
		end, { kind = 'private', _wrapped = true })
	end
end

---@param self sai.mode.sort
function M.sort(self)
	-- Important actions that should be displayed in help list
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	-- the sort overrides the editor's plain confirm: an in-flight edit
	-- must not slip out as a confirm
	self.map('Return', function()
		-- a `name:code` input commits like Tab: Enter must not strand it
		local _, code = self:code_input()
		if code and #code > 0 then return self:_accept(1) end
		if self.text:match '%S' then
			sai.notify('Clear the input to confirm', nil, 'bottomright')
			return
		end
		self:confirm()
	end, { kind = 'default', _wrapped = true, desc = 'Confirm / commit code' })
	map('Ctrl+p', function()
		-- program the cursor's picked criterion: its name and code land in the input
		local name = self.sort_by.lines[self.sort_by.line]
		if not name then return end
		self.text = name .. ':' .. (self._code_src[name] or '')
	end, 'Program the picked criterion')

	local cmp = self.completion
	cmp.map('Tab', function() self:_accept(1) end, 'Add sort criterion, ASC')
	cmp.map('Shift+ISO_Left_Tab', function() self:_accept(-1) end, 'Add sort criterion, DESC')
	cmp.map('TL+MouseLeft', function(row, _)
		if not row then return end
		cmp:select_at_mouse()
		self:_accept(1)
	end, 'Sort by the clicked field, ascending')
	cmp.map('TL+MouseRight', function(row, _)
		if not row then return end
		cmp:select_at_mouse()
		self:_accept(-1)
	end, 'Sort by the clicked field, descending')

	-- the picked pane: the cursor walks it, Ctrl+Shift+Up/Down reorders,
	-- Ctrl+i flips the direction, Alt+Delete drops, the pointer flips or
	-- drops the clicked criterion
	local by = self.sort_by
	by.map('Ctrl+Up', function() by:move(-1) end, 'Previous picked criterion')
	by.map('Ctrl+Down', function() by:move(1) end, 'Next picked criterion')
	by.map('Ctrl+Shift+Up', function() self:move_criterion(by.lines[by.line], -1) end, 'Move the picked criterion up')
	by.map(
		'Ctrl+Shift+Down',
		function() self:move_criterion(by.lines[by.line], 1) end,
		'Move the picked criterion down'
	)
	by.map(
		'Ctrl+i',
		function() self:flip_criterion(by.lines[by.line]) end,
		'Toggle the direction of the picked criterion'
	)
	by.map('Alt+Delete', function() self:remove_criterion(by.lines[by.line]) end, 'Drop the picked criterion')
	by.map('BL+MouseLeft', function(row, _)
		if not row then return end
		by:select_at_mouse()
		self:flip_criterion(by.lines[by.line])
	end, 'Toggle the direction of the clicked criterion')
	by.map('BL+MouseRight', function(row, _)
		if not row then return end
		by:select_at_mouse()
		self:remove_criterion(by.lines[by.line])
	end, 'Drop the clicked criterion')
end

---Pointer binds of the live text-box adjustment: every visible block owns
---the pointer over it, so each section carries its own wheel and swap keys.
---@param self sai.mode.text_adjust
function M.text_adjust(self)
	local map = M.gen_mapadd(self, { kind = 'default', _wrapped = true })
	map({ 'Escape', 'q' }, function() self.enabled = false end, 'Exit text adjust')

	local modmap = { TL = 'topleft', TR = 'topright', BL = 'bottomleft', ST = 'status', BR = 'bottomright' }
	for mod, loc in pairs(modmap) do
		mod = mod .. '+'
		local inc_dir, dec_dir
		if mod:sub(1, 1) == 'T' then
			inc_dir, dec_dir = 'ScrollDown', 'ScrollUp'
		else
			dec_dir, inc_dir = 'ScrollDown', 'ScrollUp'
		end

		map(mod .. dec_dir, function() self:adjust_height(loc, -1) end, 'Shrink pager')
		map(mod .. inc_dir, function() self:adjust_height(loc, 1) end, 'Grow pager')
		map(mod .. 'Shift+' .. dec_dir, function() self:adjust_scrolloff(loc, -1) end, 'Dec scrolloff')
		map(mod .. 'Shift+' .. inc_dir, function() self:adjust_scrolloff(loc, 1) end, 'Inc scrolloff')

		if mod:sub(1, 1) == 'T' then
			map(mod .. 's', function() self:swap(loc, loc:gsub('top', 'bottom')) end, 'Swap ↓')
		elseif mod:sub(1, 1) == 'B' then -- don't match status
			map(mod .. 'w', function() self:swap(loc, loc:gsub('bottom', 'top')) end, 'Swap ↑')
		end
	end
	map('TR+a', function() self:swap('topright', 'topleft') end, 'Swap ←')
	map('TL+d', function() self:swap('topleft', 'topright') end, 'Swap →')
	map('BR+a', function() self:swap('bottomright', 'status') end, 'Swap ←')
	map('ST+a', function() self:swap('status', 'bottomleft') end, 'Swap ←')
	map('ST+d', function() self:swap('status', 'bottomright') end, 'Swap →')
	map('BL+d', function() self:swap('bottomleft', 'status') end, 'Swap →')
end

return M
