---Tests for sai.mode.sort: building the comparator over the available and
---the criteria lists, the status-bar filter narrowing the fields.
---The order field itself is covered in tests/imagelist.lua.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.sort' }
local with_env = env.with_env
local il = env.sai.imagelist

-- committed binaries carrying only a Make tag (plus one tagless file);
-- copied to /tmp with fixed-epoch mtimes (the double stats the real files,
-- but the repo stays clean)
local function fixtures()
	return H.fixture_copy {
		{ name = 'sort_canon1.jpg', epoch = 1577836800 }, -- 2020, Canon
		{ name = 'sort_canon2.jpg', epoch = 1640995200 }, -- 2022, Canon
		{ name = 'sort_nikon.jpg', epoch = 1609459200 }, -- 2021, Nikon
		{ name = 'sort_plain.png', epoch = 1672531200 }, -- 2023, no exif
	}
end

-- the added file carries a size, so the reorder is visible (mtime unpinned)
local function added_fixture() return H.fixture_copy({ { name = 'sort_added.png' } })[1] end

-- public-api setup; current is the first entry (the app displays it)
local function install_imagelist(entries)
	il.clear()
	il.add(entries)
end

local function list_order()
	local out = {}
	for _, e in ipairs(env.swayimg.imagelist.get()) do
		out[#out + 1] = e.path:match '[^/]+$'
	end
	return table.concat(out, '\n')
end

-- the rendered bottomleft criteria pane (the title row, the padding and the
-- cursor marker skipped, like its own write-out)
local function picked_pane()
	local block = env.sai.viewer.text.bottomleft
	local out = {}
	for i = 2, #(block or {}) do
		if block[i] ~= '' then out[#out + 1] = (block[i]:gsub('^> ', '')) end
	end
	return table.concat(out, '\n')
end

-- the completion pool of unpicked fields, in display order
local function pool_text(m)
	local out = {}
	for _, it in ipairs(m.completion.lines) do
		out[#out + 1] = it.text or it
	end
	return table.concat(out, '\n')
end

local function select_key(h, m, name)
	local lines = m.completion.lines
	for i, it in ipairs(lines) do
		if (it.text or it) == name then
			m.completion.line = i
			return i
		end
	end
	h.fail('no such sort criterion: ' .. tostring(name) .. ' in: ' .. pool_text(m))
end

local T = {}

T.comparator = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	h.eq('no picked criteria: no sort', false, m:sort_fn())
	local loaded = il.get(true)
	local by_basename = {}
	for _, e in ipairs(loaded) do
		by_basename[e.path:match '[^/]+$'] = e
	end
	local c1, c2, n, p =
		by_basename['sort_canon1.jpg'],
		by_basename['sort_canon2.jpg'],
		by_basename['sort_nikon.jpg'],
		by_basename['sort_plain.png']
	local function sorted_names(es, fn)
		table.sort(es, fn)
		local out = {}
		for _, e in ipairs(es) do
			out[#out + 1] = e.path:match '[^/]+$'
		end
		return table.concat(out, '\n')
	end

	-- numeric compare over the loaded entries
	m:add_criterion('size', 1)
	h.eq(
		'ascending numeric',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		sorted_names({ c2, p, c1, n }, m:sort_fn())
	)

	-- descending: the numbers reverse
	m:flip_criterion 'size'
	h.eq(
		'descending numeric',
		'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png',
		sorted_names({ c2, p, c1, n }, m:sort_fn())
	)
	m:remove_criterion 'size'

	-- string values compare lexicographically
	m:add_criterion('path', 1)
	h.eq(
		'string compare',
		'sort_canon1.jpg\nsort_canon2.jpg\nsort_nikon.jpg\nsort_plain.png',
		sorted_names({ n, c2, p, c1 }, m:sort_fn())
	)
	m:remove_criterion 'path'

	-- later criteria break the ties
	m:add_criterion('Exif.Image.Make', 1)
	m:add_criterion('size', -1)
	h.eq(
		'tie broken by the second criterion',
		'sort_canon2.jpg\nsort_canon1.jpg\nsort_nikon.jpg',
		sorted_names({ n, c2, c1 }, m:sort_fn())
	)
	m:confirm(false)
end)

-- exif values come parsed: the exposure times compare as numbers, the
-- tagless image sorts last
T.comparator_parsed_exif = with_env(function(h)
	local copied =
		H.fixture_copy { { name = 'filter_canon1.jpg' }, { name = 'filter_canon2.jpg' }, { name = 'filter_plain.png' } }
	install_imagelist(copied)
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	m:add_criterion('Exif.Photo.ExposureTime', 1)
	local loaded = il.get(true)
	table.sort(loaded, m:sort_fn())
	local out = {}
	for _, e in ipairs(loaded) do
		out[#out + 1] = e.path:match '[^/]+$'
	end
	h.eq(
		'parsed exif values compare numerically, tagless last',
		'filter_canon1.jpg\nfilter_canon2.jpg\nfilter_plain.png',
		table.concat(out, '\n')
	)
	m:confirm(false)
end)

-- criteria move between the lists and live-sort
T.two_lists = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	h.eq('the pool holds every field and exif tag', 'Exif.Image.Make\nindex\nmark\nmtime\npath\nsize', pool_text(m))

	m:add_criterion('size', 1)
	h.eq('the criterion left the pool', 'Exif.Image.Make\nindex\nmark\nmtime\npath', pool_text(m))
	h.eq(
		'asc size live-sorts the list',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)
	h.eq('the criteria pane shows the criterion with its direction', 'size ↑', picked_pane())

	-- the first criterion decides, so the order stays size-based (no ties to break)
	m:add_criterion('mtime', -1)
	h.eq('the criteria pane keeps the picking order', 'size ↑\nmtime ↓', picked_pane())
	h.eq(
		'the order stays with the first criterion',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)

	m:flip_criterion 'size'
	h.eq('the criteria pane shows the flip', 'size ↓\nmtime ↓', picked_pane())
	h.eq('the flip re-sorts', 'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png', list_order())

	m:remove_criterion 'mtime'
	h.eq('the criterion returns to the pool', 'Exif.Image.Make\nindex\nmark\nmtime\npath', pool_text(m))
	h.eq(
		'the remaining criterion still sorts',
		'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png',
		list_order()
	)
	h.eq('the criteria pane shrank', 'size ↓', picked_pane())

	m:remove_criterion 'size'
	h.eq('no criteria left: no sort', 'none', env.sai.imagelist.order)
	h.eq('the order stays as it was', 'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png', list_order())
	h.eq('the pool is whole again', 'Exif.Image.Make\nindex\nmark\nmtime\npath\nsize', pool_text(m))

	m:confirm(false)
end)

-- A top-left click adds the clicked field (left ascending, right
-- descending); a bottom-left click flips the direction (left) or drops
-- the criterion (right).
-- The double window is 800x600 with linepx 42, padding 10.
T.mouse_on_the_lists = with_env(function(h)
	install_imagelist(fixtures())
	local mouse
	env.swayimg.get_mouse_pos = function() return mouse end

	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	-- 'size' is the 6th available field: the 6th row under the header
	mouse = { x = 100, y = 10 + 42 + 5 * 42 + 21 }
	env.raw_binds['viewer:MouseLeft']()
	h.eq('the clicked field was added, ascending', 'size ↑', picked_pane())
	h.eq('the click live-sorts', 'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg', list_order())

	-- a right click on the next field adds it descending
	mouse = { x = 100, y = 10 + 42 + 4 * 42 + 21 } -- the 5th row: 'path'
	env.raw_binds['viewer:MouseRight']()
	h.eq('the right-clicked field was added, descending', 'size ↑\npath ↓', picked_pane())

	-- the bottom-most row holds the last criterion; a left click flips it
	mouse = { x = 100, y = 600 - 10 - 21 }
	env.raw_binds['viewer:MouseLeft']()
	h.eq('a left click flipped the direction', 'size ↑\npath ↑', picked_pane())

	-- a right click on the row above drops the first criterion
	mouse = { x = 100, y = 600 - 10 - 42 - 21 }
	env.raw_binds['viewer:MouseRight']()
	h.eq('a right click dropped the criterion', 'path ↑', picked_pane())
	h.eq('the drop live-sorts back', 'sort_canon1.jpg\nsort_canon2.jpg\nsort_nikon.jpg\nsort_plain.png', list_order())

	-- a left click on the last criterion flips it back down
	mouse = { x = 100, y = 600 - 10 - 21 }
	env.raw_binds['viewer:MouseLeft']()
	h.eq('the flip applies down', 'path ↓', picked_pane())

	m:confirm(false)
end)

-- Keyboard controls over the two panes: the pool cursor walks with
-- Ctrl+j/k and Tab/Shift+Tab accept it; the picked cursor walks with
-- Ctrl+Up/Down, Ctrl+i flips, Alt+Delete drops.
T.keyboard_on_the_panes = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	env.raw_binds['viewer:Ctrl+j']()
	h.eq('Ctrl+j walks the pool cursor down', 2, m.completion.line)
	env.raw_binds['viewer:Tab']()
	h.eq('Tab accepts the candidate under the cursor, ascending', 'index ↑', picked_pane())
	h.eq('the input clears after the accept', '', m.text)
	h.eq('the accepted field drops from the pool', 'Exif.Image.Make\nmark\nmtime\npath\nsize', pool_text(m))

	select_key(h, m, 'mtime')
	env.raw_binds['viewer:Shift+ISO_Left_Tab']()
	h.eq('Shift+Tab accepts descending', 'index ↑\nmtime ↓', picked_pane())
	h.eq('the picked cursor starts at the top', 1, m.sort_by.line)

	env.raw_binds['viewer:Ctrl+Down']()
	h.eq('Ctrl+Down walks the picked cursor', 2, m.sort_by.line)
	env.raw_binds['viewer:Ctrl+i']()
	h.eq('Ctrl+i flips the picked criterion', 'index ↑\nmtime ↑', picked_pane())
	env.raw_binds['viewer:Ctrl+Up']()
	h.eq('Ctrl+Up walks the picked cursor back', 1, m.sort_by.line)

	env.raw_binds['viewer:Alt+Delete']()
	h.eq('Alt+Delete drops the picked criterion', 'mtime ↑', picked_pane())
	h.eq('the criterion returns to the pool', 'Exif.Image.Make\nindex\nmark\npath\nsize', pool_text(m))
	env.raw_binds['viewer:Alt+Delete']()
	h.eq('the last drop empties the picked pane', '', picked_pane())
	h.eq('the pool is whole again', 'Exif.Image.Make\nindex\nmark\nmtime\npath\nsize', pool_text(m))
	h.eq('no picked criteria: no sort', 'none', env.sai.imagelist.order)

	m:confirm(false)
end)

-- The input narrows both panes live, with the same rating as the
-- image_filter tag completion: the pool of unpicked fields and the picked
-- criteria list.
T.filter = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	h.eq('the status bar holds the prompt and the input', 'Input: ▎', env.swayimg.text.status)
	h.eq('idle: the pool holds every field', 'Exif.Image.Make\nindex\nmark\nmtime\npath\nsize', pool_text(m))

	m.text = 'path'
	h.eq('typing narrows the pool', 'path', pool_text(m))
	m.text = 'pat'
	h.eq('an all-lowercase input folds the case', 'path', pool_text(m))
	m.text = 'PAT'
	h.eq('an uppercase input matches case-sensitively', '', pool_text(m))
	m.text = 'pa'
	h.eq('a prefix matches too', 'path', pool_text(m))
	m.text = 'zzz'
	h.eq('no match: the pool empties', '', pool_text(m))

	m.text = 'Ma'
	h.eq('a tag prefix matches its short name', 'Exif.Image.Make', pool_text(m))
	m.text = 'make'
	h.eq('a mid match runs against the leaf name', 'Exif.Image.Make', pool_text(m))
	m.text = 'ake'
	h.eq('a leaf fragment matches anywhere', 'Exif.Image.Make', pool_text(m))
	m.text = 'Exif.Image'
	h.eq('a dotted input runs against the full path', 'Exif.Image.Make', pool_text(m))
	m.text = ''
	h.eq('cleared input: every field back', 'Exif.Image.Make\nindex\nmark\nmtime\npath\nsize', pool_text(m))

	-- the input also narrows the picked list
	m:add_criterion('Exif.Image.Make', 1)
	m:add_criterion('index', -1)
	m.text = 'ake'
	h.eq('the picked list narrows by the input', 'Exif.Image.Make ↑', picked_pane())
	m.text = 'index'
	h.eq('a second picked criterion matches too', 'index ↓', picked_pane())
	m.text = ''
	h.eq('clearing restores every picked criterion', 'Exif.Image.Make ↑\nindex ↓', picked_pane())

	-- an accept from the rated pool carries the full tag name
	m.text = 'pa'
	select_key(h, m, 'path')
	env.raw_binds['viewer:Tab']()
	h.eq('the accepted field keeps its full name', 'Exif.Image.Make ↑\nindex ↓\npath ↑', picked_pane())
	h.eq('the input clears on accept', '', m.text)
	h.eq('the field left the pool', 'mark\nmtime\nsize', pool_text(m))

	m:confirm(false)
end)

-- A `name:code` input is accepted as a value transform: the code, evaluated
-- with `return `, computes the value to compare for one entry; `self` holds the
-- name field or exif tag's value, the images themselves for a `self` line.
T.code_sort = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	-- the identity transform equals a plain pick: size asc
	m.text = 'size:self'
	env.raw_binds['viewer:Tab']()
	h.eq('the code line accepts a custom criterion', 'size ↑ self', picked_pane())
	h.eq('the input clears on accept', '', m.text)
	h.eq(
		'the transform compares the named field values',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)

	-- the direction decides the comparison: flipping reverses the order
	env.raw_binds['viewer:Ctrl+i']()
	h.eq(
		'the flip reverses the comparison',
		'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png',
		list_order()
	)

	-- a transform changes the value to compare: the numeric part of the path
	m:remove_criterion 'size'
	m.text = "path:self:match'%d+'"
	env.raw_binds['viewer:Tab']()
	h.eq(
		'the transform orders by its result, missing results last',
		'sort_canon1.jpg\nsort_canon2.jpg\nsort_nikon.jpg\nsort_plain.png',
		list_order()
	)

	-- tag values feed the transform; later criteria break the transformed ties
	m:remove_criterion 'path'
	m.text = 'Exif.Image.Make:(self or "zz"):upper()'
	env.raw_binds['viewer:Tab']()
	m.text = ''
	m:add_criterion 'path' -- the tiebreak: the equal Canons fall to the paths
	h.eq(
		'the transform folds the tag values, later criteria break the ties',
		'sort_canon1.jpg\nsort_canon2.jpg\nsort_nikon.jpg\nsort_plain.png',
		list_order()
	)

	-- a `self` line runs the transform over the images themselves
	m:remove_criterion 'Exif.Image.Make'
	m:remove_criterion 'path'
	m.text = 'self:self.size'
	env.raw_binds['viewer:Tab']()
	h.eq('the self line shows the code with its name', 'self ↑ self.size', picked_pane())
	h.eq(
		'the self line sorts by the image field the transform reads',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)

	-- a bad code line reports and adds nothing
	m.text = 'x:self:not a valid('
	env.raw_binds['viewer:Tab']()
	m.text = ''
	h.eq('a syntax error adds no criterion', 'self ↑ self.size', picked_pane())

	-- a custom criterion drops like any other
	m:remove_criterion 'self'
	h.eq('dropping the custom criterion empties the pane', '', picked_pane())
	h.eq('no criteria left: no sort', 'none', env.sai.imagelist.order)

	m:confirm(false)
end)

-- `:code` attaches the transform to the picked criterion under the sort_by cursor
-- (`self` when the pane is empty); Ctrl+p prefills the current criterion into
-- the input for editing; Return commits a code input, confirms an empty one.
T.code_edit = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	-- a plain picked criterion takes the code of the cursor line
	m:add_criterion 'size'
	m.text = ':-self'
	env.raw_binds['viewer:Tab']()
	h.eq('the input clears on accept', '', m.text)
	h.eq('the code attaches to the current line, not a new one', 'size ↑ -self', picked_pane())
	h.eq(
		'the attached transform re-sorts the criterion',
		'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png',
		list_order()
	)

	-- Ctrl+p recalls the criterion's name and code into the input
	env.raw_binds['viewer:Ctrl+p']()
	h.eq('the prefill holds the criterion and its code', 'size:-self', m.text)

	-- the edited code replaces the old one, no duplicate line
	m.text = 'size:self'
	env.raw_binds['viewer:Tab']()
	h.eq('the edit lands on the same line', 'size ↑ self', picked_pane())
	h.eq(
		'the replaced code re-sorts the criterion',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)

	-- an empty pane: the code adds the self criterion
	m:remove_criterion 'size'
	m.text = ':self.size'
	env.raw_binds['viewer:Tab']()
	h.eq('the empty pane takes the self criterion', 'self ↑ self.size', picked_pane())

	-- Return commits a `name:code` input like Tab does
	m:remove_criterion 'self'
	m.text = 'size:self'
	env.raw_binds['viewer:Return']()
	h.eq('Return commits the code input', '', m.text)
	h.eq('the code landed as the criterion', 'size ↑ self', picked_pane())
	h.eq(
		'the committed code re-sorts',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)

	-- a broken code line stays in the input for another pass
	m.text = 'size:not a valid('
	local recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode reports the syntax error itself', recs[1].trace, 'api/imagelist')
	h.eq('the failed code stays in the input', 'size:not a valid(', m.text)
	h.eq('the failed syntax adds no criterion', 'size ↑ self', picked_pane())

	-- code that throws on the real values reports the same way; the size
	-- criterion drops first: its distinct values decide every comparison before
	-- the code criterion would ever run
	m:remove_criterion 'size'
	m.text = 'Exif.Image.Make:self:upper()'
	recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.eq('the mode emits one report', 1, #recs)
	for i, rec in ipairs(recs) do
		h.not_contains(('report %d names the mode, not the order setter'):format(i), rec.trace, 'api/imagelist')
	end
	h.eq('the failed code stays in the input', 'Exif.Image.Make:self:upper()', m.text)
	h.eq('the refused code adds no criterion', 0, #m._criteria)
	h.eq(
		'the order stands after the failed commit',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)

	-- a guarded code takes the worst-case values and commits
	m.text = 'Exif.Image.Make:(self or ""):upper()'
	env.raw_binds['viewer:Return']()
	h.eq('the guarded code commits', 'Exif.Image.Make ↑ (self or ""):upper()', picked_pane())

	-- Return confirms only over an empty input
	m.text = 'x'
	recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.eq('Return over text notifies once', 1, #recs)
	h.contains('the clear refusal rides the Return dispatch', recs[1].trace, 'viewer:Return')
	h.eq('text in the input: no confirm', true, m.enabled)
	h.eq('the refusal lands in the bottomright corner', 'bottomright', recs[1].location)
	h.contains('the status input stands over the refusal', env.swayimg.text.status, 'x')
	m.text = ''
	env.raw_binds['viewer:Return']()
	h.eq('the empty input confirms', false, m.enabled)

	-- a confirm keeps the picks: a re-entry continues them
	m.enabled = true
	h.eq('the confirmed pick stands on re-entry', 'Exif.Image.Make ↑ (self or ""):upper()', picked_pane())
	m:add_criterion 'size'
	h.eq('a re-entry adds alongside the kept pick', 'Exif.Image.Make ↑ (self or ""):upper()\nsize ↑', picked_pane())

	-- an abort drops the picks with the restored order
	m:confirm(false)
	m.enabled = true
	h.eq('the abort wiped the picks', '', picked_pane())

	m:confirm(false)
	env.sai.imagelist.order = 'none' -- file-global state: leave none behind
end)

-- The typed code input previews the order live, like the filter mode
-- evaluates its lines; the pane keeps only the committed criteria.
T.live_preview = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	-- typing the transform applies the order before any commit
	m.text = 'size:self'
	m:on_text_changed()
	h.eq('the typed code stays in the input', 'size:self', m.text)
	h.eq('the pane holds no criterion yet', '', picked_pane())
	h.eq('the preview sorts', 'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg', list_order())

	-- editing the transform re-previews
	m.text = 'size:-self'
	m:on_text_changed()
	h.eq(
		'the edited preview flips the order',
		'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png',
		list_order()
	)

	-- a broken edit reports; the last preview's order stands
	m.text = 'size:self <'
	local recs = H.capture_notify(env.sai, function() m:on_text_changed() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode reports the syntax error itself', recs[1].trace, 'api/imagelist')
	h.eq(
		'the invalid code leaves the applied order',
		'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png',
		list_order()
	)
	h.eq('the report lands in the bottomright corner', 'bottomright', recs[1].location)
	-- the input renders on the status: the corner report must leave it standing
	h.contains('the status input untouched by the error', env.swayimg.text.status, 'size:self <')

	-- a code that throws on the real values reports before the order setter runs
	m.text = 'Exif.Image.Make:self:upper()'
	recs = H.capture_notify(env.sai, function() m:on_text_changed() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode catches the throw, not the order setter', recs[1].trace, 'api/imagelist')
	h.eq('the failed code stays in the input', 'Exif.Image.Make:self:upper()', m.text)
	h.eq(
		'the refused preview keeps the last-good order',
		'sort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg\nsort_plain.png',
		list_order()
	)

	-- committing lands the criterion and retires the preview
	m.text = 'size:self'
	m:on_text_changed()
	env.raw_binds['viewer:Return']()
	h.eq('the commit clears the input', '', m.text)
	h.eq('the committed criterion lands', 'size ↑ self', picked_pane())
	h.eq('the commit retires the preview', false, m._preview)
	h.eq('the committed order stands', 'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg', list_order())

	-- clearing the input keeps the committed order
	m.text = ''
	m:on_text_changed()
	h.eq(
		'the committed order stands without the input',
		'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)

	m:confirm(false)
	env.sai.imagelist.order = 'none' -- file-global state: leave none behind
end)

-- The picked pane is single-select: marking is a no-op, its result is the
-- criterion under the cursor.
T.single_select = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	m:add_criterion('index', 1)
	h.ok('the picked pane stays single-select', m.sort_by.single_select)
	m.sort_by:toggle_select()
	m.sort_by:select()
	m.sort_by:unselect()
	h.eq('marking stays a no-op', 0, #m.sort_by.selected)
	h.eq('the selection is the key under the cursor', 'index', m.sort_by:result())

	m:confirm(false)
end)

T.confirm_and_abort = with_env(function(h)
	env.sai.imagelist.order = 'none' -- the sort is file-global state: reset it
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	-- abort restores the sort active on entry (none here)
	m:add_criterion('mtime', -1)
	h.ok('a picked criterion sets a live sort', type(env.sai.imagelist.order) == 'function')
	m:confirm(false)
	h.eq('abort restores the entry sort', 'none', env.sai.imagelist.order)

	-- confirming keeps the built comparator as the new entry sort
	local kept = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	kept.enabled = true
	kept:add_criterion('mtime', -1)
	kept:confirm()
	h.ok('confirm keeps the sort', type(env.sai.imagelist.order) == 'function')
	h.eq(
		'the kept sort holds the order',
		'sort_plain.png\nsort_canon2.jpg\nsort_nikon.jpg\nsort_canon1.jpg',
		list_order()
	)

	-- entering over a kept sort: the mode adopts it as its entry sort
	m.enabled = true
	h.ok('the entry adopts the active sort', type(env.sai.imagelist.order) == 'function')
	m:confirm(false)
	h.ok('abort restores the adopted sort', type(env.sai.imagelist.order) == 'function')
	env.sai.imagelist.order = 'none' -- file-global state: leave none behind
end)

-- The transform proves itself on nil (a missing tag) and the current value
-- before any order setter runs; reports name the mode, never the setter.
T.base_self_comparison = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	-- plain criteria hold while the metadata is loaded
	h.ok('a plain criterion adds', m:add_criterion('index', 1))
	h.ok('the imagelist holds the sort order', type(env.sai.imagelist.order) == 'function')

	-- the typed transform takes the worst-case values: a missing tag value
	-- arrives as a nil, and an unguarded method call throws
	m.text = 'Exif.Image.Make:self:upper()'
	local recs = H.capture_notify(env.sai, function() m:on_text_changed() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode reports the throw, not the order setter', recs[1].trace, 'api/imagelist')
	h.eq('the report lands in the bottomright corner', 'bottomright', recs[1].location)
	h.contains('the status input untouched', env.swayimg.text.status, 'Exif.Image.Make:self:upper()')
	h.eq('the failed code stays in the input', 'Exif.Image.Make:self:upper()', m.text)

	-- the missing tag arrives as nil, not a falsy stand-in: `false` would
	-- concatenate where nil throws, and the code would slip through
	m.text = "Exif.Image.DateTime:'x' .. self"
	recs = H.capture_notify(env.sai, function() m:on_text_changed() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode reports the missing-tag throw', recs[1].trace, 'api/imagelist')
	h.eq('the refused code stays in the input', "Exif.Image.DateTime:'x' .. self", m.text)

	-- a plain criterion still sorts: the committed order stands
	m.text = ''
	m:on_text_changed()
	h.ok('a plain criterion still applies', m:add_criterion('size', 1))

	-- the transform result must be a comparable scalar: a boolean has no order
	m.text = 'size:true'
	recs = H.capture_notify(env.sai, function() m:on_text_changed() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode refuses the non-scalar result', recs[1].trace, 'api/imagelist')
	h.eq('the refused code stays in the input', 'size:true', m.text)

	-- the same refusal guards the commit: an expression never lands
	recs = H.capture_notify(env.sai, function() env.raw_binds['viewer:Return']() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode refuses the non-scalar result on commit', recs[1].trace, 'api/imagelist')
	h.eq('the refused code stays in the input', 'size:true', m.text)
	h.eq('the expression lands no criterion', 'index\nsize', table.concat(m._criteria, '\n'))

	-- a table result has no order either
	m.text = 'size:{}'
	recs = H.capture_notify(env.sai, function() m:on_text_changed() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the mode refuses the table result', recs[1].trace, 'api/imagelist')
	h.eq('the refused code stays in the input', 'size:{}', m.text)

	-- a transform that throws must report, not crash: the probe runs it guarded
	m.text = 'size:error("bang")'
	recs = H.capture_notify(env.sai, function() m:on_text_changed() end)
	h.eq('the mode emits one report', 1, #recs)
	h.not_contains('the throw stays a report, not a crash', recs[1].trace, 'api/imagelist')
	h.eq('the refusing code stays in the input', 'size:error("bang")', m.text)

	m:confirm(false)
	env.sai.imagelist.order = 'none' -- file-global state: leave none behind
end)

-- The user path through a confirmed code edit: the committed code survives
-- the confirm and the re-entry, ready to recall and edit; an abort drops it
T.code_survives_confirm = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	m.text = 'size:self'
	env.raw_binds['viewer:Return']() -- commits the code input
	env.raw_binds['viewer:Return']() -- the empty input confirms
	h.eq('the confirm closed the mode', false, m.enabled)

	-- the re-entry continues the confirmed session
	m.enabled = true
	h.eq('the kept criterion stands', 'size ↑ self', picked_pane())
	h.eq('the committed order stands', 'sort_plain.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg', list_order())

	-- the code recalls for another edit
	env.raw_binds['viewer:Ctrl+p']()
	h.eq('the code recalls after the re-entry', 'size:self', m.text)

	-- an abort drops the picks and restores the order they came with
	m:confirm(false)
	h.ok('the entry sort restored', type(env.sai.imagelist.order) == 'function')
	m.enabled = true
	h.eq('the picks wiped by the abort', '', picked_pane())

	m:confirm(false)
	env.sai.imagelist.order = 'none' -- file-global state: leave none behind
end)

-- The picked pane renders the code a criterion carries, however it was
-- input: the commit clears the input, but the code must stay in view.
T.pane_shows_the_code = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	m.text = 'size:self'
	env.raw_binds['viewer:Tab']()
	h.eq('a name:code input shows the code on the line', 'size ↑ self', picked_pane())
	h.eq('the accepted input stayed cleared', '', m.text)

	m:remove_criterion 'size'
	m.text = 'self:self.size'
	env.raw_binds['viewer:Return']()
	h.eq('a self code lands visible', 'self ↑ self.size', picked_pane())

	m:remove_criterion 'self'
	m:add_criterion 'size' -- the unnamed code targets the cursor's picked line
	m.text = ':-self'
	env.raw_binds['viewer:Return']()
	h.eq('an unnamed code shows on its target line', 'size ↑ -self', picked_pane())

	-- editing the code refreshes the painted line in place
	env.raw_binds['viewer:Ctrl+p']()
	m.text = 'size:self'
	env.raw_binds['viewer:Return']()
	h.eq('an edited code refreshes its line', 'size ↑ self', picked_pane())

	env.raw_binds['viewer:Return']() -- confirm
	h.eq('the confirm closed the mode', false, m.enabled)
	m.enabled = true
	h.eq('the code reads back from the kept pane', 'size ↑ self', picked_pane())

	m:confirm(false)
	env.sai.imagelist.order = 'none' -- file-global state: leave none behind
end)

-- No SwiEnter startup re-sort covered here, on purpose:
-- - the recording bootstrap already fires the app's own SwiEnter
-- - the api wipes SwiEnter hooks after (init-once), so a later trigger
--   cannot reach the imagelist subscription
-- The deferred re-sort below exercises the same apply_order path.

-- unknown criteria are no-ops: removing or flipping one changes nothing;
-- adding the same criterion twice updates it in place instead of stacking
T.unknown_criteria_are_no_ops = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true
	m:add_criterion('size', 1)

	m:remove_criterion 'nope'
	h.eq('unknown remove keeps the criteria', 1, #m._criteria)
	m:flip_criterion 'nope'
	h.eq('unknown flip keeps the direction', 1, m._dir.size)

	m:add_criterion('size', 1)
	h.eq('a re-add updates in place, no duplicate line', 1, #m._criteria)
	h.eq('the re-add keeps the place and direction', 'size ↑', picked_pane())
	m:confirm(false)
	env.sai.imagelist.order = 'none'
end)

-- _accept takes an explicit item, bypassing the completion cursor
T.accept_explicit_item = with_env(function(h)
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true

	m:_accept(1, { text = 'mtime' })
	h.eq('explicit item added', 'mtime', m._criteria[#m._criteria])
	h.eq('ascending by default', 1, m._dir.mtime)
	m:_accept(-1, { text = 'size' })
	h.eq('explicit direction honored', -1, m._dir.size)
	m:confirm(false)
	env.sai.imagelist.order = 'none'
end)

T.add_resorts_on_add = with_env(function(h) -- the added file carries a size, so the reorder is visible
	install_imagelist(fixtures())
	local m = env.mods['sai.mode.sort'].new { _path = 'sai.mode.sort' }
	m.enabled = true
	m:add_criterion('size', 1)
	m:confirm()

	env.sai.imagelist.add(added_fixture())
	h.eq(
		'the added file slots into the order',
		'sort_plain.png\nsort_added.png\nsort_canon1.jpg\nsort_nikon.jpg\nsort_canon2.jpg',
		list_order()
	)
	env.sai.imagelist.order = 'none' -- file-global state: leave none behind
end)

H.maybe_standalone(T)

return T
