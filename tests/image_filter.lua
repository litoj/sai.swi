---Tests for sai.mode.image_filter: images in, ordered available files out,
---through the mode's public flow (enable + set text).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.image_filter' }
local with_env = env.with_env
local il = env.sai.imagelist

-- the api proxy caches the first get_mouse_pos it resolves: one shared
-- closure per file, the tests move the pointer through the holder
local mouse
env.swayimg.get_mouse_pos = function() return mouse end

-- committed binaries with baked exif; fixed-epoch mtimes (the double stats
-- the real files, like the app)
local function fx(name) return H.dir .. '/fixtures/' .. name end
local function fixtures()
	local paths = {
		fx 'filter_canon1.jpg', -- Canon, EOS 5D, 1/250
		fx 'filter_canon2.jpg', -- Canon, EOS 5D, 1/2
		fx 'filter_nikon.jpg', -- Nikon, 1/60
		fx 'filter_plain.png', -- no exif
	}
	H.touch(paths[1], 1577836800) -- 2020
	H.touch(paths[3], 1609459200) -- 2021
	H.touch(paths[2], 1640995200) -- 2022
	H.touch(paths[4], 1672531200) -- 2023
	return paths
end

-- public-api setup; current is the first entry (the app displays it)
local function adopt(entries, marked)
	il.clear()
	il.add(entries)
	if marked then
		marked = entries[marked] or marked
		env.swayimg.viewer.open_path(marked)
		il.marked.set_current(true)
		env.swayimg.viewer.open_path(entries[1])
	end
end

local function new_mode(_, entries, marked)
	entries = entries or fixtures()
	adopt(entries, marked)

	local m = env.mods['sai.mode.image_filter'].new {
		_path = 'sai.mode.image_filter',
		live_imagelist = false, -- the assertions read the mode's own output
		tag_completion = false,
	}
	m.enabled = true
	return m, entries
end

local function run(m, text)
	m.text = text
	return table.concat(m._ordered_filtered_paths, '\n')
end

local paths = function(e) return table.concat(e, '\n') end

local T = {}

T.string_equality = with_env(function(h)
	local m, e = new_mode(h)
	h.eq('exact match on a tag value', paths { e[1], e[2] }, run(m, 'Make == Canon'))
	h.eq('single-word tags resolve to their Exif namespace', paths { e[1], e[2] }, run(m, 'Model == EOS 5D'))
	h.eq('no match for a foreign value', '', run(m, 'Make == Pentax'))
	m.enabled = false
end)

T.string_inequality = with_env(function(h)
	local m, e = new_mode(h)
	h.eq('!= excludes the matching value, keeps the tagless', paths { e[1], e[2], e[4] }, run(m, 'Make != Nikon'))
	m.enabled = false
end)

T.numeric_comparison = with_env(function(h)
	local m, e = new_mode(h)
	-- rational exif values parse into numbers on both sides
	h.eq('rational values compare numerically', paths { e[1] }, run(m, 'ExposureTime < 1/100'))
	h.eq('>= on a plain list field', paths { e[2], e[3] }, run(m, 'size >= 700'))
	h.eq('> on mtime', paths { e[2], e[3], e[4] }, run(m, 'mtime > 1600000000'))
	-- the tagless image has no exposure: every numeric comparison drops it
	h.eq('missing tag never matches a numeric filter', paths { e[2], e[3] }, run(m, 'ExposureTime > 1/100'))
	m.enabled = false
end)

T.negation_operator = with_env(function(h)
	local m, e = new_mode(h, nil, 2)
	h.eq('! keeps only falsy field values', paths { e[1], e[3], e[4] }, run(m, 'mark!'))
	m.enabled = false
end)

T.default_path_filter = with_env(function(h)
	local m, e = new_mode(h)
	h.eq('a bare line is a substring match on the path', paths { e[1], e[2] }, run(m, 'canon'))
	h.eq('matching is case sensitive', '', run(m, 'CANON'))
	h.eq('the whole path is searched', paths { e[1], e[2], e[3], e[4] }, run(m, 'fixtures'))
	m.enabled = false
end)

-- a bare line completes the tag being typed: while it matches tag
-- candidates the line must not also filter the paths by substring
T.completing_tag_defers_path_filter = with_env(function(h)
	local m, e = new_mode(h)
	m.tag_completion = true
	h.eq('a completing tag does not narrow by path', paths { e[1], e[2], e[3], e[4] }, run(m, 'Make'))
	h.eq('a non-tag string still filters by path', paths { e[1], e[2] }, run(m, 'canon'))
	h.eq('other lines keep filtering while one completes', paths { e[1], e[2] }, run(m, 'Make == Canon\nMa'))
	m.enabled = false
end)

-- the deferral needs the path match to be useless: with a completing tag the
-- path filter still applies when it would match something
T.completing_tag_still_filters_a_matching_path = with_env(function(h)
	local e = fixtures()
	e[#e + 1] = fx 'filter_mark.png' -- a real file whose name carries the tag
	local m = new_mode(h, e)
	m.tag_completion = true
	h.eq('a path match applies despite a completing tag', fx 'filter_mark.png', run(m, 'mark'))
	m.enabled = false
end)

T.conditions_and_across_lines = with_env(function(h)
	local m, e = new_mode(h)
	h.eq('multiple lines AND together, order preserved', paths { e[2] }, run(m, 'Make == Canon\nsize >= 700'))
	h.eq('empty lines are skipped', paths { e[1], e[2] }, run(m, '\nMake == Canon\n\n'))
	m.enabled = false
end)

T.output_follows_input_order = with_env(function(h)
	local entries = fixtures()
	-- reverse the input order: the output must follow it, not the index field
	local rev = { entries[4], entries[3], entries[2], entries[1] }
	local m = new_mode(h, rev)
	h.eq('filtered output follows the imagelist order', paths { rev[1], rev[2] }, run(m, 'Make != Canon'))
	m.enabled = false
end)

-- an invalid line is skipped (the error is still reported), the remaining
-- valid lines keep filtering; with no effective line at all everything matches
T.malformed_lines_are_skipped = with_env(function(h)
	local m, e = new_mode(h)
	h.eq('the valid filter narrows the list', paths { e[1], e[2] }, run(m, 'Make == Canon'))

	-- a valueless operator is rejected: the valid line still applies
	h.eq(
		'invalid line is skipped, the valid one keeps filtering',
		paths { e[1], e[2] },
		run(m, 'Make == Canon\nMake =')
	)
	-- so is a tagless operator
	h.eq('tagless operator is skipped too', paths { e[1], e[2] }, run(m, 'Make == Canon\n= value'))
	-- with only invalid lines nothing is filtered: the full set matches
	h.eq('only invalid lines match everything', paths { e[1], e[2], e[3], e[4] }, run(m, 'Make ='))
	m.enabled = false
end)

-- broken code reports instead of vanishing: the valid lines keep
-- filtering while the syntax error notifies
T.broken_code_reports = with_env(function(h)
	local m, e = new_mode(h)
	local recs = H.capture_notify(
		env.sai,
		function() h.eq('the valid line still filters', paths { e[1], e[2] }, run(m, 'Make == Canon\nsize:return >')) end
	)
	h.eq('the mode emits one report', 1, #recs)
	h.contains('the mode reports the parse error itself', recs[1].trace, 'mode/image_filter.lua')
	m.enabled = false
end)

T.aborting_clears_the_output = with_env(function(h)
	local m, e = new_mode(h)
	h.eq('the filter narrows before the abort', paths { e[1], e[2] }, run(m, 'Make == Canon'))

	m:confirm(false)
	h.eq('abort clears the match display', 0, #m.results_list.lines)
	h.eq('abort parks the cursor', 0, m.selected_pos)
end)

-- the abort resets the matched list and the candidates: the re-open
-- comes up with the none state, not with the parked last render
T.aborting_clears_the_completion = with_env(function(h)
	local m = new_mode(h)
	m.tag_completion = true
	m.enabled = false -- re-enter with the completion riding along
	m.enabled = true
	m.text = 'Make'
	h.ok('the completion menu is open', m.completion.enabled)
	h.ok('the menu holds a candidate', #m.completion.lines > 0)

	m:confirm(false)
	h.eq('abort clears the completion window', 0, #m.completion.lines)

	m.enabled = true -- re-open: the menu comes up empty with the filter
	h.ok('the re-open brings the menu back', m.completion.enabled)
	local shown = env.swayimg.viewer.text[m.completion.location]
	-- the none state is a zero count, not any title text (titles change)
	h.ok('the re-open shows the none state', (shown and shown[1] or ''):sub(-2) == ' 0')
	m.enabled = false
end)

-- a complete condition on another line must not shut the menu of the line
-- being typed: the completion serves partial lines
T.partial_line_keeps_the_menu = with_env(function(h)
	local m = new_mode(h)
	m.tag_completion = true
	m.enabled = false -- re-enter with the completion riding along
	m.enabled = true
	m.text = 'Exif.Image.M\nExif.Image.Make == Canon'

	h.ok('the menu stays open', m.completion.enabled)
	local items = {}
	for _, it in ipairs(m.completion.lines or {}) do
		items[#items + 1] = it.text
	end
	table.sort(items)
	h.eq('the partial line matches', 'Exif.Image.Make\nExif.Image.Model', table.concat(items, '\n'))
	m.enabled = false
end)

-- Return with the completion menu open confirms the whole filter: the mode
-- closes over the matches instead of just accepting into the input
T.return_confirms_the_mode = with_env(function(h)
	local m = new_mode(h)
	-- the completion mode must be enabled, not just visible: only then do
	-- its binds shadow the editor's (the reported state)
	m.tag_completion = true
	m.enabled = false
	m.enabled = true
	m.text = 'Make'
	h.ok('the completion menu is open', m.completion.enabled)
	h.ok('the completion mode shadows the editor', m.completion.enabled)

	env.raw_binds['viewer:Return']()
	h.ok('return turns the filter mode off', not m.enabled)
	m.enabled = false
end)

-- Escape with the completion menu open aborts the whole filter, like with
-- the menu closed: the mode turns off instead of swallowing the key
T.escape_aborts_the_mode = with_env(function(h)
	local m = new_mode(h)
	m.tag_completion = true
	m.enabled = false
	m.enabled = true
	m.text = 'Make'
	h.ok('the completion menu is open', m.completion.enabled)
	h.ok('the completion mode shadows the editor', m.completion.enabled)

	env.raw_binds['viewer:Escape']()
	h.ok('escape turns the filter mode off', not m.enabled)
	m.enabled = false
end)

-- ---------------------------------------------------------------------------
-- The live-imagelist lifetime: filtering/confirm remove images from the app
-- list, escaping must put the whole list back - even after a previous confirm
-- ---------------------------------------------------------------------------

local raw_il = env.swayimg.imagelist
local live_paths = function()
	local out = {}
	for _, e in ipairs(raw_il.get()) do
		out[#out + 1] = e.path
	end
	return table.concat(out, '\n')
end

local function live_mode(_, entries)
	entries = entries or fixtures()
	adopt(entries)
	local m = env.mods['sai.mode.image_filter'].new {
		_path = 'sai.mode.image_filter',
		live_imagelist = true, -- the assertions read the app imagelist
		live_pager = false,
		tag_completion = false,
	}
	m.enabled = true
	return m, entries
end

T.escape_restores_after_confirm = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Canon'
	h.eq('filtering shrank the list', paths { e[1], e[2] }, live_paths())
	m:confirm()
	h.eq('confirm keeps the filtered list', paths { e[1], e[2] }, live_paths())
	m.enabled = true
	m:confirm(false) -- escape
	h.eq('escape restores the snapshot order', paths(e), live_paths())
	m.enabled = false
end)

-- escaping must return the images even with no filter text (the restore
-- cannot rely on `_filtered`, which stays equal to all seen)
T.escape_restores_after_confirm_without_text = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Canon'
	m:confirm()
	m.text = '' -- the filter is gone before the next open
	m.enabled = true
	m:confirm(false) -- escape
	for _, img in ipairs(e) do
		h.ok('escape hands back every image: ' .. img, live_paths():find(img, 1, true) ~= nil)
	end
	m.enabled = false
end)

-- the escape restore appends the filtered-out images at the end of the app
-- list: the next open must follow that order, not the stale baseline
T.matched_list_follows_the_restored_order = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'nikon' -- a non-prefix subset, so the restore really reorders
	h.eq('filtering shrank the list', paths { e[3] }, live_paths())
	m:confirm(false) -- escape: the rest returns appended behind the match
	h.eq('the restore appends the rest', paths { e[3], e[1], e[2], e[4] }, live_paths())

	m.enabled = true -- no new images: no renewal, only the order resyncs
	m.text = 'fixtures'
	h.eq('the matched list follows the app list order', live_paths(), table.concat(m._ordered_filtered_paths, '\n'))
	m.enabled = false
end)

-- a reorder outside the mode (a sort, a remade list) must resync the order
-- too: no fresh images means no renewal, the baseline just follows along
T.matched_list_follows_an_external_reorder = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Canon'
	m:confirm(false) -- escape: the mode closes over the whole set

	il.clear() -- through the wrapper: it owns the cached order
	il.add { e[4], e[2], e[3], e[1] } -- a whole new order
	m.enabled = true
	m.text = 'fixtures'
	h.eq('the matched list follows the reordered app list', live_paths(), table.concat(m._ordered_filtered_paths, '\n'))
	m.enabled = false
end)

-- an empty match set empties the list (swayimg can show an empty one)
T.empty_list_when_nothing_matches = with_env(function(h)
	local m = live_mode(h)
	local notified = 0
	local old_notify = env.sai.notify
	env.sai.notify = function(...)
		notified = notified + 1
		return old_notify(...)
	end
	local ran, err = pcall(function()
		m.text = 'Make == Pentax' -- matches nothing
		h.eq('a no-match filter empties the list', '', live_paths())
		h.eq('no notification on the empty list', 0, notified)
		h.eq('no matches recorded', '', table.concat(m._ordered_filtered_paths, '\n'))
	end)
	env.sai.notify = old_notify
	if not ran then error(err, 0) end
	m.enabled = false
end)

-- the list opens on the image the app displays: the cursor sits on the
-- current image's row, not on the first one
T.results_list_opens_on_current = with_env(function(h)
	local entries = fixtures()
	adopt(entries)
	env.swayimg.viewer.open_path(entries[3])

	local m = env.mods['sai.mode.image_filter'].new {
		_path = 'sai.mode.image_filter',
		live_imagelist = false, -- the assertions read the mode's own output
		tag_completion = false,
	}
	m.enabled = true -- the enable itself applies the empty filter
	h.eq('the cursor sits on the current image', 3, m.results_list.line)
	h.eq('the position reads from the live cursor', 3, m.selected_pos)
	local base = m.results_list.title:gsub('\t$', '')
	h.eq('the header counts position and total', base .. ' 3/4', m.results_list:title_fmt(m.results_list.title, nil))
	m.enabled = false
end)

-- a click selects the image displayed on that line: the block row the
-- bind payload reports is window-relative, the list may sit scrolled
T.results_list_click_scrolled = with_env(function(h)
	local entries = fixtures()
	adopt(entries)
	env.swayimg.viewer.open_path(entries[1])

	local m = env.mods['sai.mode.image_filter'].new {
		_path = 'sai.mode.image_filter',
		live_imagelist = false, -- the assertions read the mode's own output
		tag_completion = false,
	}
	m.enabled = true
	m.results_list.max_height = 2 -- the window holds lines 2..3
	m.results_list.scroll = 2

	env.flush_defers() -- a stale single-wait defer would eat the burst counters
	mouse = { x = 100, y = 600 - 10 - 42 - 21 } -- the top visible row
	env.raw_binds['viewer:MouseLeft']()
	env.flush_defers() -- the click's single-wait defer must not leak into the next test
	h.eq('the click selects the displayed line, not the block row', 2, m.selected_pos)
	mouse = nil
	m.enabled = false
end)

-- the cursor setter navigates straight to the match: `selected_pos` is a
-- virtual field (the getter reads the live cursor), so the option protocol
-- must not store a backing option behind it on every press
T.selected_pos_is_virtual = with_env(function(h)
	local m = new_mode(h)
	run(m, 'Make == Canon')
	m.selected_pos = 2
	h.eq('the cursor lands on the match', 2, m.results_list.line)
	h.eq('the getter reads the live cursor', 2, m.selected_pos)
	h.eq('navigation leaves no backing option behind', nil, rawget(m, '_selected_pos'))
	m.enabled = false
end)

-- escaping after the filter emptied the list must put every image back
T.escape_restores_after_empty_match = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Pentax' -- matches nothing: the list empties
	h.eq('a no-match filter empties the list', '', live_paths())
	m:confirm(false) -- escape
	for _, img in ipairs(e) do
		h.ok('escape hands back every image: ' .. img, live_paths():find(img, 1, true) ~= nil)
	end
	m.enabled = false
end)

-- remaking over an emptied list must restore the whole set first: with no
-- effective filter line every image is a match, so the list comes back
T.clearing_the_text_restores_after_empty_match = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Pentax' -- matches nothing: the list empties
	h.eq('a no-match filter empties the list', '', live_paths())
	m.text = ''
	for _, img in ipairs(e) do
		h.ok('cleared filter hands back every image: ' .. img, live_paths():find(img, 1, true) ~= nil)
	end
	m.enabled = false
end)

-- an invalid line must not freeze a remake over an emptied list either: the
-- line is skipped, the other lines still narrow, and with only invalid
-- lines everything is a match again
T.invalid_line_does_not_freeze_the_remake = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Pentax' -- matches nothing: the list empties
	h.eq('a no-match filter empties the list', '', live_paths())
	m.text = '\nMake =\n' -- only invalid lines: nothing filters
	for _, img in ipairs(e) do
		h.ok('invalid line cannot freeze the list: ' .. img, live_paths():find(img, 1, true) ~= nil)
	end
	m.text = 'Make == Canon\nMake ='
	h.eq('the valid line still narrows', paths { e[1], e[2] }, live_paths())
	m.enabled = false
end)

-- a temporarily emptied list (e.g. a stale open) must be re-seeded on the
-- next open, so remaking the filter has a full baseline to narrow
T.remake_re_seeds_an_emptied_list = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Pentax'
	h.eq('a no-match filter empties the list', '', live_paths())
	m.enabled = false -- escape hands the whole set back
	m.text = '' -- remake from scratch
	raw_il.clear() -- the list is empty again before the remake
	h.eq('the app list is empty before the remake', 0, #raw_il.get())
	m.enabled = true -- remake: must hand the full set back first
	h.eq('the remake re-seeds the full set', 4, #raw_il.get())
	il.add(e)
	m.enabled = true
	m.enabled = false
end)

-- mainline swayimg cannot show an empty list: with keep_one_image the
-- filter leaves the current image listed, escaping still brings all back
T.keep_one_image_for_mainline = with_env(function(h)
	local m, e = live_mode(h)
	m.keep_one_image = true
	m.text = 'Make == Pentax' -- matches nothing
	h.eq('one image stays listed', e[1], live_paths())
	m:confirm(false) -- escape
	for _, img in ipairs(e) do
		h.ok('escape hands back every image: ' .. img, live_paths():find(img, 1, true) ~= nil)
	end
	m.enabled = false
end)

-- with an empty list the app reports a dummy current image, so the mode
-- tracks its own cursor over the emptied list
T.typing_after_everything_filtered_out = with_env(function(h)
	local m = live_mode(h)
	m.text = 'Make == Pentax' -- matches nothing: the list empties
	h.eq('a no-match filter empties the list', '', live_paths())
	m.text = 'Make == Pentaxx' -- keep typing over the empty list must not crash
	h.eq('still nothing matches', '', live_paths())
	h.eq('no match means position zero', 0, m.selected_pos)
	local base = m.results_list.title:gsub('\t$', '')
	h.eq('the header counts zero of zero', base .. ' 0/0', m.results_list:title_fmt(m.results_list.title, nil))
	m.enabled = false
end)

-- a non-permanent confirm must not remove anything either
T.escape_restores_with_nonpermanent_confirm = with_env(function(h)
	local m = live_mode(h)
	m.update_imagelist_on_confirm = false
	m.text = 'Make == Canon'
	m:confirm()
	h.eq('non-permanent confirm kept the whole list', live_paths():find('filter_nikon.jpg', 1, true) ~= nil, true)
	m.enabled = true
	m:confirm(false)
	h.eq('non-permanent escape restores too', live_paths():find('filter_nikon.jpg', 1, true) ~= nil, true)
	m.enabled = false
end)

-- a fresh image after a confirm must renew the list; escaping must bring
-- back the fresh and the old filtered-out
T.renewal_then_escape_restores_all = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Canon'
	m:confirm()
	local fresh = fx 'filter_fresh.png'
	raw_il.add { fresh, e[3], e[4] } -- the app list regrows around the confirmed one
	m.enabled = true
	m.text = 'fresh'
	h.eq('the renewal keeps the fresh image', fresh, live_paths())
	m:confirm(false) -- escape
	h.eq('escape hands back the fresh image', true, live_paths():find('filter_fresh.png', 1, true) ~= nil)
	h.eq('escape hands back a filtered-out image', true, live_paths():find('filter_nikon.jpg', 1, true) ~= nil)
	m.enabled = false
end)

-- the renewal must be judged against the last confirmed filter: a group that
-- was filtered out once and returns later must be relearned, not stay dropped
-- from `_imagelist` because some unrelated image triggered a renewal before
T.renewal_judged_against_confirmed = with_env(function(h)
	local m, e = live_mode(h)
	m.text = 'Make == Canon' -- the confirmed group is {canon, canon}
	m:confirm()

	-- a fresh image appears: the first renewal can shrink the mode's list
	raw_il.add { fx 'filter_fresh.png' }
	m.enabled = true
	m.enabled = false

	-- the previously filtered-out group returns to the list: the mode must
	-- relearn it (it is new relative to the confirmed filter)
	raw_il.add { e[3], e[4] }
	m.enabled = true
	m.text = 'nikon'
	h.eq('the returned group filters in again', e[3], live_paths())
	m.enabled = false
end)

-- the machinery rides below its owner: the components come up first,
-- so the corner display the owner generates at its own enable already
-- lists them - no manual regeneration
T.corner_lists_components = with_env(function(h)
	local m = require('sai.mode.image_filter').new { _path = 'sai.mode.image_filter' }
	m.enabled = true

	local lines = {}
	for _, line in ipairs(m.help_pager.lines) do
		---@cast line string|mode_base.text.dyntext
		lines[#lines + 1] = type(line) == 'string' and line or line.callback()
	end
	local out = table.concat(lines, '\n')
	h.contains('the corner lists the completion', out, '[Completion]')
	h.contains('the menu accept key listed', out, 'Accept completion')
	h.contains('the menu navigation listed', out, 'Next completion')

	m.enabled = false
end)

H.maybe_standalone(T)

return T
