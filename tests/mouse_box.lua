---Tests for sai.bridge.mouse_box: block geometry and pointer hit tests.
---Over a recording api stack. Development tool: not used during normal
---swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.selector' }
local sai, with_env = env.sai, env.with_env
local mouse_box = require 'sai.bridge.mouse_box'
local selector = require 'sai.mode.selector'
local remapper = require 'sai.lib.remapper'
-- recording stub: window 800x600, linepx 42, padding 10
local at = H.mouse_stub(env.swayimg)
local function pair(...) return ('%s\t%s'):format(tostring((select(1, ...))), tostring((select(2, ...)))) end
local function trio(...)
	return ('%s\t%s\t%s'):format(tostring((select(1, ...))), tostring((select(2, ...))), tostring((select(3, ...))))
end

local T = {}

T.block_at_bounds = with_env(function(h)
	sai.viewer.text.topright = {} -- else the default scheme covers the corner
	sai.viewer.text.topleft = { 'header', 'one', 'two', 'three' }
	-- 'header' is the widest line: the block ends right after its cells
	local edge = 10 + #'header' * 24 * mouse_box.width_factor

	at(31, 31) -- over the header row
	h.eq('over the header: the row is nil', 'TL\tnil\ttopleft', trio(mouse_box.block_at { 'TL' }))

	at(31, 10 + 42 + 21) -- first content row
	h.eq('the first content row hits row one', 'TL\t1\ttopleft', trio(mouse_box.block_at { 'TL' }))

	at(math.floor(edge), 10 + 42 + 21) -- the last px of the longest line
	h.eq('the block edge still matches', 'TL\t1\ttopleft', trio(mouse_box.block_at { 'TL' }))

	at(math.floor(edge) + 1, 10 + 42 + 21) -- one px right of the text
	h.eq('right of the text: no block', 'nil\tnil\tnil', trio(mouse_box.block_at { 'TL' }))

	at(31, 10 + 4 * 42 + 21) -- below the last rendered row
	h.eq('below the text: no block', 'nil\tnil\tnil', trio(mouse_box.block_at { 'TL' }))

	at(700, 100) -- the emptied topright corner
	h.eq('no text in the section: no block', 'nil\tnil\tnil', trio(mouse_box.block_at { 'TR' }))
end)

-- bottom blocks anchor at the window's bottom edge: the last line sits
-- on it, the rows count down from the block's top, the header above them
T.block_at_bottom = with_env(function(h)
	sai.viewer.text.bottomleft = { 'head', 'one', 'two', 'three' }

	at(100, 600 - 10 - 21)
	h.eq('the bottom edge holds the last line', 'BL\t3\tbottomleft', trio(mouse_box.block_at { 'BL' }))
	at(100, 600 - 10 - 42 - 21)
	h.eq('the row above counts down', 'BL\t2\tbottomleft', trio(mouse_box.block_at { 'BL' }))
	at(100, 600 - 10 - 2 * 42 - 21)
	h.eq('the top content row hits row one', 'BL\t1\tbottomleft', trio(mouse_box.block_at { 'BL' }))
	at(100, 600 - 10 - 3 * 42 - 21)
	h.eq('over the header: the row is nil', 'BL\tnil\tbottomleft', trio(mouse_box.block_at { 'BL' }))
	at(100, 600 - 10 - 4 * 42 - 21)
	h.eq('above the block: no match', 'nil\tnil\tnil', trio(mouse_box.block_at { 'BL' }))
end)

-- the pager window: its own scroll/header/visible rows over the same
-- geometry, off the rendered area nothing answers (no clamping)
T.pager_line = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'topleft', _max_height = 10, title = 'List' }
	s.enabled = true
	s.lines = { 'row one', 'row two', 'row three' } -- the selected one gains '> '

	at(100, 10 + 42 + 21) -- first content row below the header
	h.eq('the first row under the header is line one', 'topleft\t1', pair(mouse_box.pager_line(s)))

	at(100, 10 + 42 + 3 * 42 + 21) -- one row below the window
	h.eq('below the window: nothing', 'nil\tnil', pair(mouse_box.pager_line(s)))

	at(5, 10 + 42 + 21) -- left of the block start
	h.eq('left of the block: nothing', 'nil\tnil', pair(mouse_box.pager_line(s)))

	at(400, 10 + 42 + 21) -- right of the widest line
	h.eq('right of the text: nothing', 'nil\tnil', pair(mouse_box.pager_line(s)))

	s.enabled = false -- a live selector owns the pointer: leave the tree clean
end)

-- the status pager rides the centered bottom block: the string's
-- longest line sets the width, rows count up from the bottom edge
T.pager_line_status = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'status' }
	s.enabled = true
	s.lines = { 'centered bottom row one', 'centered bottom row two' }
	h.ok('the status block is up', #(env.swayimg.text.status or '') > 0)

	at(400, 600 - 10 - 21) -- the bottom row, window center
	h.eq('the bottom edge holds the last line', 'status\t2', pair(mouse_box.pager_line(s)))
	at(400, 600 - 10 - 42 - 21) -- the row above
	h.eq('the row above holds the first line', 'status\t1', pair(mouse_box.pager_line(s)))
	at(400, 600 - 10 - 2 * 42 - 21) -- above the block
	h.eq('above the status: nothing', 'nil\tnil', pair(mouse_box.pager_line(s)))

	s.enabled = false -- a live selector owns the pointer: leave the tree clean
end)

-- the section match: a point against the rendered blocks, the first
-- containment in the given order wins
T.block_at = with_env(function(h)
	sai.viewer.text.topright = {} -- else the default scheme covers the corner
	-- 9 rows: the block reaches past the window middle at 300
	sai.viewer.text.topleft = { 'head', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight' }

	at(100, 100)
	h.eq('over the block: TL', 'TL', mouse_box.block_at { 'TL', 'TR', 'BL', 'BR' })
	at(100, 10 + 8 * 42 + 21)
	h.eq('past the middle: the tall block still owns the pointer', 'TL', mouse_box.block_at { 'TL', 'TR', 'BL', 'BR' })
	at(100, 400) -- below the block (it ends at 10 + 9 * 42 = 388)
	h.eq('below the block: nothing', nil, mouse_box.block_at { 'TL', 'TR', 'BL', 'BR' })
	mouse = nil
	h.eq('no position: nothing', nil, mouse_box.block_at { 'TL', 'TR', 'BL', 'BR' })

	-- both candidates contain the pointer: the first in the list wins
	sai.viewer.text.bottomleft = { 'bl head', 'bl row' }
	at(100, 600 - 10 - 21) -- the bottom half, off the tall block: BL
	h.eq('the bottom half over BL: BL', 'BL', mouse_box.block_at { 'TL', 'BL' })
	at(100, 10 + 8 * 42 + 21)
	h.eq('the tall TL overflow: TL', 'TL', mouse_box.block_at { 'TL', 'BL' })

	-- a wide bottom block crosses the vertical middle
	sai.viewer.text.bottomright = { 'a considerably wide bottom row' }
	at(300, 600 - 10 - 21) -- left of the window middle, over the wide text
	h.eq('over the wide text past the middle: BR', 'BR', mouse_box.block_at { 'BR' })
end)

-- the status section: the centered bottom block from the status string
T.block_at_status = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.selector', _location = 'status' }
	s.enabled = true
	s.lines = { 'centered bottom row one', 'centered bottom row two' }

	at(400, 600 - 10 - 21)
	h.eq('the status box answers', 'ST', mouse_box.block_at { 'ST' })
	at(400, 600 - 10 - 2 * 42 - 21)
	h.eq('above the status: nothing', nil, mouse_box.block_at { 'ST' })

	s.enabled = false
end)

-- the exact character position: the px column, clamped into the line by
-- its utf8 length (multibyte text counts codepoints, not bytes)
T.char_at = with_env(function(h)
	local pager = require 'sai.lib.pager'
	local s = pager.new { _path = 'sai.mode.test', _location = 'topleft', title = 'T' }
	s.enabled = true
	s.lines = { 'aбc' } -- 3 codepoints, 5 bytes

	at(10, 10 + 42 + 21) -- the first cell
	h.eq('the first character is column one', '1\t1', pair(mouse_box.char_at(s)))
	at(10 + 24, 10 + 42 + 21) -- the second cell
	h.eq('the second character is column two', '1\t2', pair(mouse_box.char_at(s)))
	at(10 + 3 * 24, 10 + 42 + 21) -- the block edge, past the 3 chars
	h.eq('past the end: the insert position', '1\t4', pair(mouse_box.char_at(s)))

	at(10, 10) -- over the header row
	h.eq('over the header: nothing', 'nil\tnil', pair(mouse_box.char_at(s)))

	s.enabled = false
end)

-- the dispatcher: a qualified bind fires only over the text that
-- reached the pointer, the plain bind serves the rest
T.qualified_fallthrough = with_env(function(h)
	local mode = remapper.new { _path = 'sai.mode.custom' }
	local got, plain = {}, 0
	mode.map('TL+MouseLeft', function(line, loc) got = { line, loc } end, 'top-left action')
	mode.map('MouseLeft', function() plain = plain + 1 end, 'plain action')
	mode.enabled = true

	-- seeded after the enable: the corner arming blanks stale content
	sai.viewer.text.topleft = { 'head', 'content row' }

	at(100, 10 + 42 + 21) -- over the content row
	env.raw_binds['viewer:MouseLeft']()
	h.eq('qualified fired with the row', '1\ntopleft', table.concat(got, '\n'))
	h.eq('the plain handler stayed out', 0, plain)

	at(600, 10 + 42 + 21) -- same row, right of the text
	env.raw_binds['viewer:MouseLeft']()
	h.eq('off the text: the plain one ran', 1, plain)

	mode.enabled = false
end)

-- the calibration: a font or size change re-measures the geometry, a
-- failed lookup keeps the last good values
T.calibrate = with_env(function(h)
	local calls
	mouse_box._stub_metrics = function(_, size)
		calls = calls and calls + 1 or 1
		return size / 2, 4
	end
	sai.text.font = 'stubbed'
	h.eq('a font change measures', 1, calls)
	h.eq('the cell factor follows the new measure', 0.5, mouse_box.width_factor)
	h.eq('the padding factor follows the new measure', 4 / 24, mouse_box.hpad_factor)

	sai.text.size = 12
	h.eq('a size change measures again', 2, calls)
	h.eq('the cell factor follows the new size', 0.5, mouse_box.width_factor)

	---@diagnostic disable-next-line: duplicate-set-field
	mouse_box._stub_metrics = function() end
	sai.text.font = 'no measure'
	h.eq('a failed measure keeps the values', 0.5, mouse_box.width_factor)

	sai.text.size = 24 -- the other tests' coordinates assume the defaults
	mouse_box.width_factor, mouse_box.hpad_factor = 1, 0
end)

-- the real font lookup itself: with fontconfig and freetype loadable, an
-- installed monospace font must measure up - the hit boxes are only as
-- good as the numbers this lookup returns
T.real_font_metrics = with_env(function(h)
	mouse_box._stub_metrics = nil
	mouse_box.calibrate('monospace', 24)
	local wf, hf = mouse_box.width_factor, mouse_box.hpad_factor
	---@diagnostic disable-next-line: duplicate-set-field
	mouse_box._stub_metrics = function() end
	mouse_box.width_factor, mouse_box.hpad_factor = 1, 0
	if wf <= 0 or wf == 1 then return h.skip('font lookup unavailable', wf) end
	h.ok('a character cell measured', wf > 0 and wf < 1)
	h.ok('the inner padding measured', hf >= 0 and hf < 1)
end)

H.maybe_standalone(T)

return T
