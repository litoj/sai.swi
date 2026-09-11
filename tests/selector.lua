---Tests for the selector mode: formats, selected lines, window. Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.selector' }
local with_env = env.with_env
local selector = require 'sai.mode.selector'

-- the app-bound status layer
local raw_text = env.swayimg.text

-- the api proxy caches the first get_mouse_pos it resolves: one shared
-- closure per file, the tests move the pointer through the holder
local at = H.mouse_stub(env.swayimg)

local items = H.items

-- the hook through the same call shape the paints use
local function fmt_row(s, i) return s:line_fmt(s.lines[i], i) end

local T = {}

T.formats_and_selection = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 20 }
	s.enabled = true
	s.lines = items(5)

	h.eq('the cursor starts on the first item', '> item1', fmt_row(s, 1))

	s.line = 3
	h.eq('cursor mark on the current line', '> item3', fmt_row(s, 3))
	h.eq('the previous line back to plain', 'item1', fmt_row(s, 1))

	s:select(5)
	s:select(2)
	h.eq('selected mark on the selected line', '* item5', fmt_row(s, 5))
	h.eq('selected list keeps the selection order', '5\n2', table.concat(s.selected, '\n'))

	s.line = 5
	h.eq('cursor wins over the selected mark', '> item5', fmt_row(s, 5))

	s:unselect(5)
	h.eq('unselect keeps the rest in order', '2', table.concat(s.selected, '\n'))
	s.line = 4
	h.eq('deselected line back to plain', 'item5', fmt_row(s, 5))
end)

T.selection_survives_within_bounds = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 20 }
	s.enabled = true
	s.lines = items(5)
	s:select(4)
	s:select(2)

	s.lines = items(3) -- shrinks below selection 4
	h.eq('selections beyond the end drop', '2', table.concat(s.selected, '\n'))
	s.lines = items(5)
	s:select(1)
	h.eq('selections cannot duplicate', '2\n1', table.concat(s.selected, '\n'))
end)

T.set_selected = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 20 }
	s.enabled = true
	s.lines = items(5)

	s:set_selected { 5, 1, 5 }
	h.eq('set_selected keeps order, drops duplicates', '5\n1', table.concat(s.selected, '\n'))
	s:set_selected {}
	h.eq('set_selected {} clears the selection', 0, #s.selected)
end)

T.single_select = with_env(function(h)
	local s =
		selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 20, single_select = true }
	s.enabled = true
	s.lines = items(5)

	s.line = 3
	s:toggle_select()
	s:select(5)
	s:unselect(3)
	h.eq('marking stays a no-op', 0, #s.selected)
	h.eq('result is the current line', 'item3', s:result())
	s.line = 2
	h.eq('result follows the line', 'item2', s:result())
end)

T.window_follows_the_selection = with_env(function(h)
	-- edge-following: scroll_ahead = 0
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 4, _scroll_ahead = 0 }
	s.enabled = true
	s.lines = items(10)
	h.eq('window opens at the top', 1, s.scroll)

	s.line = 4 -- the last visible line: still no scroll
	h.eq('no scroll at the bottom edge', 1, s.scroll)
	s.line = 5
	h.eq('scrolls by one past the edge', 2, s.scroll)
	s.line = 9
	h.eq('deep selection clamps the window', 6, s.scroll) -- max: leave one line empty
	s.line = 1
	h.eq('window jumps back to the top', 1, s.scroll)

	-- centered: scroll_ahead = 0.5 (a fraction of the page); a page of 7
	-- centers the selection with a margin of 3
	local c = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 7, _scroll_ahead = 0.5 }
	c.enabled = true
	c.lines = items(20)
	h.eq('centered: top of the list first', 1, c.scroll)
	c.line = 5 -- past the middle: the selection centers
	h.eq('selection centers in the window', 2, c.scroll)
	h.contains('centered line renders', fmt_row(c, 5), 'item5')
	c.line = 20
	h.eq('bottom clamp keeps the window full', 15, c.scroll)

	-- one line of look-ahead: scroll_ahead = 1 is a line count (not a
	-- fraction of the page): the selection keeps one line of context above
	-- and below - the symmetric margins
	local n = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 7, _scroll_ahead = 1 }
	n.enabled = true
	n.lines = items(20)
	h.eq('window opens at the top', 1, n.scroll)
	n.line = 5
	h.eq('the selection may sit deep in the window', 1, n.scroll)
	n.line = 7
	h.eq('one line below the bottom edge scrolls', 2, n.scroll)
	n.line = 2
	h.eq('one line above the top edge scrolls back', 1, n.scroll)
end)

-- The mouse over the window: mouse_box answers with the location and
-- the line under the pointer, nothing off the rendered block.
T.mouse_line = with_env(function(h)
	local mouse_box = require 'sai.bridge.mouse_box'
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 10, title = '' } -- the items, not the derived header, set the width
	s.enabled = true
	s.lines = items(30)

	-- double window 800x600, linepx 42, header y=10..52
	at()
	h.eq('no mouse position: no answer', nil, (select(2, mouse_box.pager_line(s))))

	at(100, 10 + 42 + 21)
	local loc, line = mouse_box.pager_line(s)
	h.eq('topleft block location resolves', 'topleft', loc)
	h.eq('first line under the header is line one', 1, line)

	at(100, 10 + 42 + 21 + 3 * 42)
	loc, line = mouse_box.pager_line(s)
	h.eq('fourth content line is line four', 4, line)

	at(100, 10 + 21)
	loc, line = mouse_box.pager_line(s)
	h.eq('over the header: no line', nil, line)

	at(480, 10 + 42 + 21) -- right of the block: the page header is the widest line
	loc, line = mouse_box.pager_line(s)
	h.eq('right of the text answers nothing', nil, line)

	-- the bottomleft block anchors at the bottom edge: the last window line
	-- touches it, the header floats on top of the block
	local b = selector.new { _path = 'sai.mode.selector', _location = 'bottomleft', _max_height = 10 }
	b.enabled = true
	b.lines = items(30)
	at(100, 600 - 10 - 21)
	loc, line = mouse_box.pager_line(b)
	h.eq('bottomleft block location resolves', 'bottomleft', loc)
	h.eq('last line answers at the bottom edge', b.scroll + b.page_size - 1, line)

	at(100, 600 - 10 - 42 - 21) -- the row above it
	loc, line = mouse_box.pager_line(b)
	h.eq('the row above holds the previous line', b.scroll + b.page_size - 2, line)

	at(100, 600 - 10 - 11 * 42 + 21) -- the header row
	loc, line = mouse_box.pager_line(b)
	h.eq('over the header: no line', nil, line)
end)

-- the double-click confirms the line the pointer sees: the block row
-- the bind payload reports is window-relative, the list may sit scrolled

T.doubleclick_scrolled = with_env(function(h)
	local got
	local s = selector.new {
		_path = 'sai.mode.selector',
		_location = 'bottomleft',
		_max_height = 2,
		single_select = true,
		on_confirm = function(_, result) got = result end,
	}
	s.enabled = true
	s.lines = items(30)
	s.scroll = 5 -- the window holds lines 5..6

	at(100, 600 - 10 - 42 - 21) -- the top visible row
	env.flush_defers() -- a stale single-wait defer would eat the burst counters
	env.raw_binds['viewer:MouseLeft']()
	env.raw_binds['viewer:MouseLeft']()
	env.flush_defers() -- the superseded single-wait defer must not leak into the next test
	h.eq('the double confirms the displayed line, not the block row', 'item5', got)
	at()

	s.enabled = false
end)

-- The consumer of a block walks the table in hash order: only a dense
-- array from 1, title first, reads back in order
T.dense_render_map = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 4, title = 'Items' }
	s.enabled = true
	s.lines = items(10)

	local t = env.swayimg.viewer.text.topleft
	h.eq('the title is the first row', 'Items[Page 1/3]', t[1])
	h.eq('no zero key in the map', nil, t[0])
	h.eq('window rows follow in order', '> item1', t[2])
	h.eq('the page fills to the window end', 'item4', t[5])
	h.eq('no rows render beyond the window', nil, t[6])
	h.eq('dense array: the length matches the rows', 5, #t)

	s.line = 9 -- deep selection: the window jumps forward
	t = env.swayimg.viewer.text.topleft
	h.eq('the page block moves with the window', 'Items[Page 3/3]', t[1])
	h.eq('the window follows the selection', 'item7', t[2])
	h.eq('dense array matches after the jump', 5, #t)
	h.eq('no rows render beyond the window after the jump', nil, t[6])

	s.lines = {}
	t = env.swayimg.viewer.text.topleft
	h.eq('empty list: the title alone', 'Items', t[1])
	h.eq('empty list: a single row', 1, #t)
end)

T.selector_mode_flow = with_env(function(h)
	local got
	local mode = env.mods['sai.mode.selector'].new {
		_path = 'sai.mode.selector',
		_location = 'topleft',
		_max_height = 20,
		on_confirm = function(_, result) got = result end,
	}
	mode.lines = { 'a', 'b', 'c' }
	mode.enabled = true

	mode.line = 2
	mode:confirm()
	h.eq('single pick: the cursor item', 'b', got)
	h.ok('confirm disables the mode', not mode._enabled)

	mode.enabled = true
	mode:select(3)
	mode:select(1)
	mode.line = 2
	mode:confirm()
	h.eq('selected items come back in selection order', 'c\na', table.concat(got, '\n'))

	mode.enabled = true
	mode:confirm(false)
	h.eq('abort reports false', false, got)

	-- Tab toggles the selection on the cursor item (like space); the custom
	-- mode's binds land on the current app mode (viewer)
	local tabbed = env.mods['sai.mode.selector'].new { _path = 'sai.mode.selector', on_confirm = function() end }
	tabbed.lines = { 'a', 'b', 'c' }
	tabbed.enabled = true
	tabbed.line = 2
	env.raw_binds['viewer:Tab']()
	h.eq('Tab selects the cursor item', 2, tabbed.selected[1])
	env.raw_binds['viewer:Tab']()
	h.eq('Tab toggles the selection off', 0, #tabbed.selected)
	tabbed.enabled = false
end)

T.status_location = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'status' }
	s.enabled = true
	s.title = 'Pick'
	s.lines = { 'one', 'two' }

	-- the write joins the rows with newlines; the text layer pads the
	-- lines to the longest one, like every status block
	h.eq('status shows the title and the whole list', 'Pick: > one\ntwo        ', raw_text.status)
	s.line = 2
	h.eq('selection moves the marker', 'Pick: one\n> two    ', raw_text.status)
end)

-- The status is one string, not one line: the format is `Title: content`
-- with the content being every line of the list joined by newlines - the
-- whole list is the window, there is nothing to scroll
T.status_multiline = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'status' }
	s.enabled = true
	s.title = 'Pick'
	s.lines = { 'one', 'two', 'three' }

	h.eq('the whole list joins into the status', 'Pick: > one\ntwo        \nthree      ', raw_text.status)
	s.title = ''
	s.lines = { 'one', 'two', 'three' }
	h.eq('no title: the lines alone', '> one\ntwo  \nthree', raw_text.status)
	s.line = 3
	h.eq('the marker moves with the selection', 'one    \ntwo    \n> three', raw_text.status)
end)

-- an empty line in the middle is a real row in the status join too
T.status_keeps_empty_lines = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'status' }
	s.enabled = true
	s.title = 'Pick'
	s.lines = { 'one', '', 'two' }

	h.eq('the empty line renders as a blank row', 'Pick: > one\n' .. (' '):rep(11) .. '\ntwo        ', raw_text.status)
end)

T.function_formats = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 20 }
	s.enabled = true
	s.lines = { 'a', 'bb', 'ccc' }

	-- one pane, three swapped formats: the reassignments are the test
	---@diagnostic disable-next-line: duplicate-set-field
	s.line_fmt = function(_, item, idx) return ('%s:%s'):format(item, s._selected_idx[idx] ~= nil) end
	h.eq('function format sees item and selection state', 'a:false', fmt_row(s, 1))
	s:select(1)
	h.eq('selection reaches the format through self', 'a:true', fmt_row(s, 1))

	---@diagnostic disable-next-line: duplicate-set-field
	s.line_fmt = function(_, item, idx)
		local line = ('%d:%s'):format(idx, item)
		if s._selected_idx[idx] then line = line:upper() .. '*' end
		return line
	end
	s:select(2)
	s.line = 3
	h.eq('selection state transforms the plain line', '2:BB*', fmt_row(s, 2))
	h.eq('unselected index paint stays', '3:ccc', fmt_row(s, 3))

	---@diagnostic disable-next-line: duplicate-set-field
	s.line_fmt = function(_, item, idx)
		if idx == s._line then return item .. ':cursor' end
		return item
	end
	h.eq('the current line takes its own branch', 'ccc:cursor', fmt_row(s, 3))
end)

-- changing scroll_ahead live re-seats the window: the line rides along
-- with it, like it does when the window moves under paging
T.scroll_ahead_live_change = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 4, _scroll_ahead = 0 }
	s.enabled = true
	s.lines = items(10)
	s.line = 9
	h.eq('window follows the edge', 6, s.scroll)

	s.scroll_ahead = 1
	h.eq('the line rode along with the window', 10, s.line)
	h.eq('look-ahead margin seated the window', 8, s.scroll)
	h.ok('the line stays visible', s.scroll <= s.line and s.line <= s.scroll + s.page_size - 1)

	s.scroll_ahead = 0
	h.eq('narrowing keeps the window (band hysteresis)', 8, s.scroll)
	h.eq('selected line holds', 10, s.line)
end)

-- an explicit value confirms through on_confirm and closes; an abort
-- reports false; re-enabling resets the verdict for the next cycle
T.confirm_explicit_and_verdict = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 20 }
	local got = 'unset'
	s.on_confirm = function(_, res) got = res end
	s.enabled = true
	s.lines = items(5)

	s:confirm 'chosen'
	h.eq('explicit value reaches on_confirm', 'chosen', got)
	h.ok('confirm closes the mode', not s.enabled)
	h.eq('success verdict recorded', 1, s._verdict)

	s.enabled = true
	h.eq('re-enable resets the verdict', 0, s._verdict)
	s:confirm(false)
	h.eq('abort reports false', false, got)
	h.ok('abort closes the mode', not s.enabled)
	h.eq('abort verdict recorded', -1, s._verdict)

	s.enabled = true
	h.eq('re-enable resets the abort verdict', 0, s._verdict)
	s.enabled = false
end)

T.scroll_edges = with_env(function(h) -- a list that fits one page never scrolls, at either end
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 4, _scroll_ahead = 0.5 }
	s.enabled = true
	s.lines = items(3)
	s.line = 3
	h.eq('a fitting list does not scroll at the end', 1, s.scroll)

	-- the very start and end of a long list keep the window in bounds
	s.lines = items(20)
	s.line = 1
	h.eq('selection at the top pins the window to the top', 1, s.scroll)
	s.line = 20
	h.eq('selection at the end clamps to the last flush window', 18, s.scroll) -- 20 - 4 + 2
	s.line = 19
	local top = s.scroll
	h.ok('selection one up stays inside the window', top <= 19 and 19 <= top + s.page_size - 1)

	-- an empty list leaves the window untouched
	s.lines = {}
	s.line = 1
	h.eq('an empty list never scrolls', 1, s.scroll)
end)

H.maybe_standalone(T)

return T
