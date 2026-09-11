---Tests for the pager: title hiding, empty-line padding, template lines. Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.selector' }
local with_env = env.with_env
local pager = require 'sai.lib.pager'

local items = H.items

local T = {}

-- window 800x600, linepx 42 -> 14 rows; the header row leaves 13 content
-- lines, a hidden header (title_fmt returning '') grants the 14th
T.hidden_title_gains_a_line = with_env(function(h)
	-- single page: no [Page x/y] suffix, so an empty title truly hides
	local titled = pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 20, title = 'List' }
	titled.enabled = true
	titled.lines = items(10)

	local bare = pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 20, title = '' }
	bare.enabled = true
	bare.lines = items(10)

	h.eq('the titled page leaves a row for the header', titled.page_size + 1, bare.page_size)
	h.eq('a window without a title gains the header row', 14, bare.page_size)

	local t = env.swayimg.viewer.text.topleft
	h.eq('the bare window shows the first line at the top', 'item1', t[1])
	h.eq('the whole list fits the gained line count', 'item10', t[10])
	h.eq('no rows render beyond the list', nil, t[11])
end)

-- height_factor is a per-window knob: a bigger glyph adds more line height,
-- so the page shrinks with it (default 0.75 sizes the line to 42px -> 14 rows)
T.height_factor_scales_the_rows = with_env(function(h)
	local light =
		pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 20, height_factor = 0.5, title = '' }
	local heavy =
		pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 20, height_factor = 1.5, title = '' }
	light.enabled = true
	light.lines = items(5)
	heavy.enabled = true
	heavy.lines = items(5)
	h.eq('a smaller factor fits more rows', 16, light.page_size)
	h.eq('a larger factor fits fewer rows', 10, heavy.page_size)
end)

-- a title that always resolves empty hides the row even with a title set
T.empty_title_renders_no_row = with_env(function(h)
	local p = pager.new {
		_path = 'sai.mode.test',
		_location = 'topleft',
		_max_height = 4,
		title = 'Set',
		title_fmt = function() return '' end,
	}
	p.enabled = true
	p.lines = items(3)
	local t = env.swayimg.viewer.text.topleft
	h.eq('the first line starts at row one', 'item1', t[1])
	h.eq('the third line lands on row three', 'item3', t[3])
	h.eq('no title row anywhere', 3, #t)
end)

-- an empty title still draws the [Page x/y] suffix once the list spans
-- multiple pages: the header row gets reserved again
T.multi_page_empty_title_reserves_the_header = with_env(function(h)
	local p = pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 20, title = '' }
	p.enabled = true
	p.lines = items(20)
	h.eq('page block shrinks the page for the header', 13, p.page_size)
	local t = env.swayimg.viewer.text.topleft
	h.eq('the page suffix renders in the header row', '[Page 1/2]', t[1])
	h.eq('the first content line follows the header', 'item1', t[2])
end)

T.empty_lines_pad_with_spaces = with_env(function(h)
	local p = pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 4, title = 'T' }
	p.enabled = true
	p.lines = { 'a', '', 'b', '' }
	local t = env.swayimg.viewer.text.topleft
	h.eq('title renders first', 'T', t[1])
	h.eq('the first content line renders', 'a', t[2])
	h.eq('empty line renders as a space', ' ', t[3])
	h.eq('the next content line renders', 'b', t[4])
	h.eq('second empty line renders as a space', ' ', t[5])
end)

-- raw items may be extended_text_template entries: a function line resolves
-- through the text tree, a plain string passes through
T.template_function_lines = with_env(function(h)
	local p = pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 4, title = 'T' }
	p.enabled = true
	p.lines = {
		function(img) return 'fn:' .. tostring(img.path) end,
		'plain',
	}
	local t = env.swayimg.viewer.text.topleft
	h.contains('a function line renders its return value', tostring(t[2] or ''), 'fn:')
	h.eq('the plain string line passes through', 'plain', t[3])
end)

-- the header visibility sizes the page: the lines set after a title flip
-- recalibrates around it, a bare title write changes nothing on its own
T.live_title_grows_and_shrinks = with_env(function(h)
	local p = pager.new {
		_path = 'sai.mode.test',
		_location = 'topleft',
		_max_height = 20,
		title = '',
		title_fmt = function(_, title) return title:gsub('\t$', '') end,
	}
	p.enabled = true
	p.lines = items(20)
	h.eq('no title: the page uses every row', 14, p.page_size)
	p.title = 'Hdr'
	p.lines = items(20)
	h.eq('a title appears: the page loses a row', 13, p.page_size)
	p.title = ''
	p.lines = items(20)
	h.eq('title cleared: the page regains the row', 14, p.page_size)
end)

-- the title is a plain field: writing it repaints nothing, the next
-- lines update (or an explicit render) picks it up
T.title_is_plain_until_content_or_render = with_env(function(h)
	local p = pager.new { _path = 'sai.mode.test', _location = 'topleft', _max_height = 4, title = 'T' }
	p.enabled = true
	p.lines = items(3)
	local function head() return env.swayimg.viewer.text.topleft[1] end
	h.eq('constructor title renders with the lines', 'T', head())

	p.title = 'New'
	h.eq('title alone repaints nothing', 'T', head())

	p.lines = items(3)
	h.eq('a lines write renders the new title', 'New', head())
end)

-- the default title names the pager after its path's last segment,
-- sentence case; an explicit one wins
T.title_from_path = with_env(function(h)
	local p = pager.new { _path = 'sai.mode.help_pager', _location = 'topleft', _max_height = 4 }
	h.eq('the path derives the default title', 'Help pager:\t', p.title)

	local kept = pager.new { _path = 'sai.mode.other', title = 'Kept:\t' }
	h.eq('an explicit title overrides the derived one', 'Kept:\t', kept.title)

	local bare = pager.new {}
	h.eq('no path, no derived title', '', bare.title)

	local sel = env.mods['sai.mode.selector'].new { _path = 'sai.mode.help_pager' }
	h.eq('the selector derives the same default title', 'Help pager:\t', sel.title)

	local nested = pager.new { _path = 'sai.mode.sort.sort_by' }
	h.eq('only the last path segment derives the title', 'Sort by:\t', nested.title)
end)

H.maybe_standalone(T)

return T
