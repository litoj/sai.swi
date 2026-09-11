---Tests for sai.lib.history: cycle (Up=next older, Down=prev newer),
---matcher, nil stickiness, add dedup, max_size trim, file round-trip,
---save on SwiLeavePre exit hook.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local eq = H.eq

local env = H.recording_stack {}
local with_env = env.with_env

local Hist = require('sai.lib.history').new

local T = {}

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

T.new_empty = function()
	local h = Hist()
	eq('empty holds nothing', 0, #h)
	eq('position starts at prompt', 0, h._pos)
	eq('no saved text', nil, h._match)
end

T.new_with_entries_keeps_order = function()
	local h = Hist { 'echo one', 'echo two' }
	eq('newest first', 'echo one', h[1])
	eq('older behind it', 'echo two', h[2])
	eq('position starts at prompt', 0, h._pos)
	eq('no saved text', nil, h._match)
end

T.new_copies_entries = function()
	local seed = { 'a', 'b' }
	local h = Hist(seed)
	h:add 'c'
	eq('seed untouched', 2, #seed)
	eq('copy grows', 3, #h)
end

-- ---------------------------------------------------------------------------
-- Up = next (older), Down = prev (newer)
-- ---------------------------------------------------------------------------

T.next_cycles_older = with_env(function()
	local h = Hist { 'echo one', 'echo two' }
	eq('first Up recalls newest', 'echo one', h:next '')
	eq('position at newest', 1, h._pos)
	eq('second Up recalls older', 'echo two', h:next 'echo one')
	eq('position at older', 2, h._pos)
end)

T.next_holds_at_oldest = with_env(function()
	local h = Hist { 'echo one' }
	h:next ''
	eq('Up recalls only entry', 'echo one', h[1])
	eq('second Up returns nil', nil, h:next 'echo one')
	eq('position holds', 1, h._pos)
	eq('saved text kept', '', h._match)
end)

T.prev_walks_newer = with_env(function()
	local h = Hist { 'echo one', 'echo two' }
	h:next ''
	h:next 'echo one'
	eq('Down recalls newer', 'echo one', h:prev 'echo two')
	eq('position back at newest', 1, h._pos)
end)

T.prev_past_newest_returns_saved_once = with_env(function()
	local h = Hist { 'echo one' }
	h:next ''
	h:next 'echo one' -- hold at oldest
	eq('Down returns saved text once', '', h:prev 'echo one')
	eq('cycle left history', 0, h._pos)
	eq('saved text cleared', nil, h._match)
	eq('next Down holds nil', nil, h:prev '')
end)

T.prev_at_prompt_holds = with_env(function()
	local h = Hist { 'echo one' }
	eq('Down at prompt does nothing', nil, h:prev '')
	eq('position stays out', 0, h._pos)
end)

T.empty_history_returns_nil = with_env(function()
	local h = Hist()
	eq('Up with nothing is nil', nil, h:next 'typed')
	eq('Down with nothing is nil', nil, h:prev 'typed')
	eq('stays out', 0, h._pos)
	eq('stays nil', nil, h._match)
end)

-- ---------------------------------------------------------------------------
-- Matcher: substring, skip, nil stickiness, cycle continuation
-- ---------------------------------------------------------------------------

T.matcher_skips_nonmatching = with_env(function()
	local h = Hist { 'echo one', 'print two' }
	eq('Up skips non-match', 'echo one', h:next 'ec')
	eq('Up holds without more', nil, h:next 'echo one')
	eq('Down restores typed', 'ec', h:prev 'echo one')
end)

T.matcher_matches_substrings = with_env(function()
	local h = Hist { 'echo one', 'print echo' }
	eq('first Up prefix match', 'echo one', h:next 'echo')
	eq('second Up substring match', 'print echo', h:next 'echo one')
	eq('Down walks back', 'echo one', h:prev 'print echo')
	eq('Down restores typed', 'echo', h:prev 'echo one')
end)

T.unmatched_keeps_nil_sticky = with_env(function()
	local h = Hist { 'echo one' }
	eq('Up without match is nil', nil, h:next 'zz')
	eq('saved stays nil', nil, h._match)
	eq('Down without match is nil', nil, h:prev 'zz')
	eq('saved stays nil', nil, h._match)
end)

T.same_match_continues_deeper = with_env(function()
	local h = Hist { 'echo one', 'echo two' }
	eq('first Up recalls newest', 'echo one', h:next 'ec')
	eq('same match again goes deeper', 'echo two', h:next 'ec')
	eq('position at the older entry', 2, h._pos)
end)

T.prefix_of_current_entry_continues = with_env(function()
	local h = Hist { 'echo one', 'echo two' }
	h:next 'e'
	h:next 'e'
	eq('reached older', 'echo two', h[2])
	-- the user extends the recalled entry: still its prefix, cycle continues
	eq('Up with extended prefix holds at oldest', nil, h:next 'echo t')
	eq('position kept', 2, h._pos)
end)

T.prefix_shift_after_substring_recall_continues = with_env(function()
	local h = Hist { 'echo one', 'print echo' }
	eq('first Up prefix match', 'echo one', h:next 'ec')
	eq('second Up substring match', 'print echo', h:next 'ec')
	-- the cursor sat inside the recalled entry: its prefix continues the cycle
	eq('Up with the entry prefix holds', nil, h:next 'pr')
	eq('filter unchanged', 'ec', h._match)
end)

T.edit_to_unmatched_freezes = with_env(function()
	local h = Hist { 'echo one' }
	h:next 'ec'
	eq('Up without new match is nil', nil, h:next 'zz')
	eq('cycle cleared', nil, h._match)
	eq('Down stays nil', nil, h:prev 'zz')
end)

-- ---------------------------------------------------------------------------
-- Multiline entries: just strings to the history, newlines included
-- ---------------------------------------------------------------------------

T.multiline_entry_recalls_verbatim = with_env(function()
	local h = Hist { 'one\ntwo', 'plain' }
	eq('Up recalls the multiline entry', 'one\ntwo', h:next '')
	eq('Up recalls past it', 'plain', h:next 'one\ntwo')
	eq('Down walks back to the multiline entry', 'one\ntwo', h:prev 'plain')
end)

T.add_files_multiline_verbatim = function()
	local h = Hist()
	h:add 'a\nb'
	eq('multiline entry stored whole', 'a\nb', h[1])
end

-- ---------------------------------------------------------------------------
-- Add, reset, max_size
-- ---------------------------------------------------------------------------

T.add_moves_to_top = function()
	local h = Hist { 'one', 'two', 'three' }
	h:add 'three'
	eq('no duplicate', 3, #h)
	eq('re-added moves to top', 'three', h[1])
	eq('second keeps place', 'one', h[2])
	eq('third keeps place', 'two', h[3])
end

T.add_resets_cycle = with_env(function()
	local h = Hist { 'one' }
	h:next ''
	h:add 'two'
	eq('position reset', 0, h._pos)
	eq('saved cleared', nil, h._match)
	eq('newest first', 'two', h[1])
end)

T.add_skips_empty = function()
	local h = Hist()
	h:add ''
	eq('empty adds nothing', 0, #h)
end

T.reset_clears_cycle = with_env(function()
	local h = Hist { 'one' }
	h:next ''
	h:reset()
	eq('position reset', 0, h._pos)
	eq('saved cleared', nil, h._match)
end)

T.max_size_trims_on_add = function()
	local h = Hist { max_size = 2 }
	h:add 'a'
	h:add 'b'
	h:add 'c'
	eq('size capped', 2, #h)
	eq('newest first', 'c', h[1])
	eq('oldest dropped', 'b', h[2])
end

T.set_max_size_trims = function()
	local h = Hist { 'a', 'b', 'c' }
	h:set_max_size(2)
	eq('shrinks to cap', 2, #h)
	eq('newest kept', 'a', h[1])
	eq('second kept', 'b', h[2])
end

-- ---------------------------------------------------------------------------
-- File: round-trip, multiline escape, save on exit
-- ---------------------------------------------------------------------------

T.file_roundtrip_multiline = with_env(function(_)
	local path = '/tmp/sai_history_test_roundtrip.txt'
	os.remove(path)
	local a = Hist { 'a\nb', 'c\\d', 'plain' }
	a:set_file(path)
	a:save()
	local b = Hist()
	b:set_file(path)
	eq('count survives', 3, #b)
	eq('multiline survives', 'a\nb', b[1])
	eq('backslash survives', 'c\\d', b[2])
	eq('plain survives', 'plain', b[3])
	os.remove(path)
end)

T.file_save_on_exit_hook = with_env(function(h)
	local path = '/tmp/sai_history_test_exit.txt'
	os.remove(path)
	local hist = Hist { 'echo hi' }
	hist:set_file(path)
	hist:add 'echo bye'
	local e = require 'sai.api.eventloop'
	e.trigger { event = 'SwiLeavePre', data = 0 }
	h.ok('file written on exit', H.file_exists(path))
	local back = Hist()
	back:set_file(path)
	h.eq('saved newest first', 'echo bye', back[1])
	h.eq('older behind it', 'echo hi', back[2])
	os.remove(path)
end)

T.file_false_saves_nothing = with_env(function(h)
	local hist = Hist { 'x' }
	hist:set_file(false)
	hist:save()
	h.pass 'save without file is a no-op'
	h.eq('no exit hook without a file', false, hist._leave_hook)
end)

-- seeds land over the loaded file: the first seed stays the newest
T.seeds_merge_over_loaded_file = with_env(function(h)
	local path = '/tmp/sai_history_test_merge.txt'
	os.remove(path)
	Hist({ 'old one', 'old two', file = path }):save()

	local m = Hist { 'seed one', 'old two', file = path }
	h.eq('first seed on top', 'seed one', m[1])
	h.eq('duplicate seed deduped against the file', 'old two', m[2])
	h.eq('file entry kept its place', 'old one', m[3])
	h.eq('entry count after the merge', 3, #m)
	os.remove(path)
end)

H.maybe_standalone(T)

return T
