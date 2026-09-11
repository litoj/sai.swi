---Tests for the sai.imagelist api over a recording stack. Each test resets
---the list through the public api; metadata arrives through the real exiv2
---bridge off real fixture files.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local raw_il = env.swayimg.imagelist -- the app side, for changes behind sai's back
local il = env.sai.imagelist

-- committed binaries with baked exif
local function fx(name) return H.dir .. '/fixtures/' .. name end
-- clear + add invalidate the cache: no test plants entries by hand
local function reset(paths)
	il.clear()
	il.add(paths)
end

local T = {}

-- the cache stands while the size stands; a plain get() never loads
T.list_cache = with_env(function(h)
	local a, b, c = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg', fx 'filter_nikon.jpg'
	reset { a, b }

	local list = il.get()
	h.eq('the cached list holds two entries', 2, #list)
	h.ok('a plain get leaves entries bare', list[1].meta == nil)

	local again = il.get()
	h.ok('the cached list is returned as-is', again == list)

	-- the app side changes behind sai's back
	raw_il.add(c)
	again = il.get()
	h.ok('a size change re-reads the list', again ~= list)
	h.eq('the re-read list holds three entries', 3, #again)
	h.ok('the refetched entries are bare', again[3].meta == nil)
end)

-- get(true) loads through the bridge; the loaded list stays cached
T.full_load = with_env(function(h)
	local a, b = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg'
	reset { a, b }

	local list = il.get(true)
	h.eq('the exif got loaded', 'Canon', list[1].meta['Exif.Image.Make'])
	h.eq('the actual resolution got loaded', 100, list[1].width)
	h.eq('the actual resolution got loaded (height)', 80, list[1].height)

	local again = il.get(true)
	h.ok('the loaded list is returned as-is', again == list)
	h.eq('the loaded meta rides along', 'Canon', il.get()[1].meta['Exif.Image.Make'])
end)

-- mutations drop the cache: refetch bare, reload on demand
T.mutations_invalidate = with_env(function(h)
	local a, b, c = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg', fx 'filter_nikon.jpg'
	reset { a, b }
	h.eq('the exif loads', 'Canon', il.get(true)[1].meta['Exif.Image.Make'])

	il.remove(a)
	local list = il.get()
	h.eq('remove leaves one entry', 1, #list)
	h.eq('the removed path is gone', b, list[1].path)
	h.ok('the refetched entry is bare', list[1].meta == nil)
	h.eq('the surviving entry loads its meta', 'Canon', il.get(true)[1].meta['Exif.Image.Make'])

	il.clear()
	h.eq('clear empties the cached list', 0, #il.get())

	il.add(c)
	list = il.get(true)
	h.eq('add lists the new entry', 1, #list)
	h.eq('the added entry loads its meta', 'Nikon', list[1].meta['Exif.Image.Make'])
end)

-- the rebuild sorts in place, loaded entries intact
T.order_rebuild = with_env(function(h)
	local a, b = fx 'filter_canon2.jpg', fx 'filter_canon1.jpg'
	reset { a, b }
	il.get(true)

	il.order = function(x, y) return x.path < y.path end
	local list = il.get()
	h.eq('the new order reads back through sai', b, list[1].path)
	h.eq('the loaded meta survived the rebuild', 'Canon', list[1].meta['Exif.Image.Make'])

	il.order = 'none'
end)

-- the enum forwards (the raw api re-sorts); a comparator parks the raw
-- order at 'none' until an enum clears it
T.order_field = with_env(function(h)
	local a, b = fx 'filter_canon2.jpg', fx 'filter_canon1.jpg'
	reset { a, b }

	il.order = 'alpha'
	h.eq('the enum forwards to the raw api', 'alpha', env.swayimg.imagelist.order)
	h.eq('the enum reads back through the proxy', 'alpha', il.order)

	il.order = function(x, y) return x.path < y.path end
	h.eq('a comparator takes over', 'function', type(il.order))
	h.eq("the raw order parks at 'none' behind the comparator", 'none', env.swayimg.imagelist.order)
	h.eq('the comparator re-sorted the list', b, env.swayimg.imagelist.get()[1].path)

	il.order = 'none'
	h.eq("'none' clears the comparator", 'none', il.order)
	h.eq('the list stands as the last rebuild left it', b, env.swayimg.imagelist.get()[1].path)
end)

-- silent immediate re-sort, marks and current kept by path
T.order_write_effects = with_env(function(h)
	local c1, c2, n, p = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg', fx 'filter_nikon.jpg', fx 'filter_plain.png'
	reset { c1, c2, n, p }

	-- the user marked the second image (the `a` keybind flow)
	env.swayimg.viewer.open_path(c2)
	il.marked.set_current(true)
	env.swayimg.viewer.open_path(c1)

	local function order()
		local out = {}
		for _, e in ipairs(env.swayimg.imagelist.get()) do
			out[#out + 1] = e.path:match '[^/]+$'
		end
		return table.concat(out, '\n')
	end

	-- adopt first: re-adoption fires once, the rebuild must fire none
	local _ = il.marked.size

	local size_events = 0
	local e = require 'sai.api.eventloop'
	e.subscribe {
		event = 'OptionSet',
		pattern = { 'sai.imagelist.size', 'sai.imagelist.marked.size' },
		group = 'test_size_events',
		callback = function() size_events = size_events + 1 end,
	}

	il.order = function(a, b) return a.size < b.size end
	h.ok('the comparator write takes', il.order ~= false)
	h.eq(
		'writing the order re-sorts',
		'filter_plain.png\nfilter_canon1.jpg\nfilter_nikon.jpg\nfilter_canon2.jpg',
		order()
	)
	h.eq('the rebuild fired no size events', 0, size_events)

	h.eq('the marked entry is still marked', true, env.swayimg.imagelist.get()[4].mark)
	h.eq('the current image restored by path', c1, il.get_current().path)

	il.order = 'none'
	h.eq("'none' stops the ordering", 'none', il.order)
	h.eq(
		'the order stays as it was',
		'filter_plain.png\nfilter_canon1.jpg\nfilter_nikon.jpg\nfilter_canon2.jpg',
		order()
	)
	h.eq('still no size events', 0, size_events)
	e.unsubscribe { event = 'OptionSet', group = 'test_size_events' }
end)

-- adjacent single paths resolve to directories; missing paths stay loud
T.adjacent_resolves_dirs = with_env(function(h)
	il.clear()
	il.add('/tmp', true)
	h.eq('a directory adds as-is', '/tmp', il.get()[1].path)

	il.clear()
	il.add(H.dir .. '/init.lua', true)
	h.eq('a file adds its directory', H.dir .. '/', il.get()[1].path)

	il.clear()
	local ran, err = pcall(il.add, '/tmp/sai-imagelist-missing-xyz', true)
	h.ok('a missing path errors', not ran)
	h.contains('the error names the path', tostring(err), 'sai-imagelist-missing-xyz')
	h.eq('the list stands untouched', 0, #il.get())
end)

-- string lists must mark by path: the raw side hopped to nil and marked
-- the current image instead
T.marked_string_list_marks_raw = with_env(function(h)
	local a, b = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg'
	reset { a, b }
	il.marked.add { a }

	local marks = {}
	for _, e in ipairs(env.swayimg.imagelist.get()) do
		marks[e.path] = e.mark
	end
	h.eq('listed path marked raw', true, marks[a])
	h.eq('the unlisted path stays unmarked', false, marks[b])
end)

-- has resolves positive, negative and path lookups; misses stay nil
T.has_resolves_index_and_path = with_env(function(h)
	local a, b = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg'
	reset { a, b }
	il.get() -- has reads the fetched list: prime it after the reset

	h.eq('first by index', a, il.has(1).path)
	h.eq('second by index', b, il.has(2).path)
	h.eq('negative counts from the end', b, il.has(-1).path)
	h.eq('lookup by path', a, il.has(a).path)
	h.eq('missing path misses', nil, il.has '/tmp/sai-imagelist-missing-xyz')
	h.eq('missing index misses', nil, il.has(99))
end)

-- get by path or index loads the single entry meta on demand
T.get_single_loads_meta = with_env(function(h)
	local a, b = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg'
	reset { a, b }

	h.eq('the entry meta loads', 'Canon', il.get(a).meta['Exif.Image.Make'])
	h.eq('the index form loads too', 'Canon', il.get(2).meta['Exif.Image.Make'])
	h.eq('a miss stays nil', nil, il.get '/tmp/sai-imagelist-missing-xyz')
end)

-- select opens by path or index; an unknown real file joins the list
T.select_opens_and_auto_adds = with_env(function(h)
	local a, b, n = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg', fx 'filter_nikon.jpg'
	reset { a }

	il.select(b)
	h.eq('the unknown file joined', 2, #il.get())
	h.eq('the joined file opened', b, il.get_current().path)

	il.select(1)
	h.eq('select by index opens', a, il.get_current().path)

	il.select(n)
	h.eq('another unknown file joins and opens', n, il.get_current().path)
end)

-- get_current is a dummy on the empty list, the open image otherwise
T.get_current_follows_open = with_env(function(h)
	il.clear()
	h.eq('empty list reports the dummy', '', il.get_current().path)

	local a = fx 'filter_canon1.jpg'
	reset { a }
	h.eq('the first image shows by default', a, il.get_current().path)
end)

-- marked add/remove/toggle/get round-trip through the raw side
T.marked_toggle_remove_get = with_env(function(h)
	local a, b = fx 'filter_canon1.jpg', fx 'filter_canon2.jpg'
	reset { a, b }

	il.marked.add { a, b }
	h.eq('both marked', 2, il.marked.get_size())

	il.marked.toggle { a }
	local got = il.marked.get()
	table.sort(got)
	h.eq('toggle unmarks the toggled path', b, table.concat(got, '\n'))

	il.marked.remove { b }
	h.eq('remove clears the last mark', 0, il.marked.get_size())

	il.marked.set_current 'toggle'
	h.eq('toggle on the current marks', 1, il.marked.get_size())
	il.marked.set_current 'toggle'
	h.eq('toggle again unmarks', 0, il.marked.get_size())

	il.clear()
end)

-- the size event fires once the list stands ordered: observers never see
-- the intermediate appended state
T.size_fires_ordered = with_env(function(h)
	local small, big = fx 'filter_plain.png', fx 'filter_canon2.jpg'
	reset { big }
	il.order = function(a, b) return a.size < b.size end

	local seen
	local e = require 'sai.api.eventloop'
	e.subscribe {
		event = 'OptionSet',
		pattern = 'sai.imagelist.size',
		group = 'test_size_ordered',
		callback = function()
			local out = {}
			for _, im in ipairs(il.get()) do
				out[#out + 1] = im.path:match '[^/]+$'
			end
			seen = table.concat(out, '\n')
		end,
	}
	il.add(small)
	h.eq('observers see the ordered list', 'filter_plain.png\nfilter_canon2.jpg', seen)
	il.order = 'none'
	e.unsubscribe { event = 'OptionSet', group = 'test_size_ordered' }
end)

-- Large-list remove coverage: every case builds a 12-entry list out of
-- real fixture copies (distinct /tmp paths, real exif) and checks both
-- list forms after the removal: get() for paths/indexes and get(true)
-- for paths plus the loaded exif values. Joined strings read back the
-- whole list, so a failure prints what the list actually holds.
local function big_list(n)
	local srcs = { fx 'filter_canon1.jpg', fx 'filter_canon2.jpg', fx 'filter_nikon.jpg' }
	local out = {}
	for i = 1, n do
		local dst = ('/tmp/sai-rm-%02d.jpg'):format(i)
		H.exec(("cp '%s' '%s'"):format(srcs[(i - 1) % #srcs + 1], dst))
		out[i] = dst
	end
	return out
end

-- the baked exif of big_list position i: Canon, Canon, Nikon, ...
local function make_for(i) return i % 3 == 0 and 'Nikon' or 'Canon' end

local function joined_paths(list)
	local out = {}
	for _, e in ipairs(list) do
		out[#out + 1] = e.path
	end
	return table.concat(out, '\n')
end

local function joined_indexes(list)
	local out = {}
	for _, e in ipairs(list) do
		out[#out + 1] = tostring(e.index)
	end
	return table.concat(out, ',')
end

local function joined_makes(list)
	local out = {}
	for _, e in ipairs(list) do
		out[#out + 1] = e.meta and e.meta['Exif.Image.Make'] or '?'
	end
	return table.concat(out, ',')
end

local function seq_indexes(n)
	local out = {}
	for i = 1, n do
		out[i] = tostring(i)
	end
	return table.concat(out, ',')
end

-- remove the head of a 12-entry list
T.remove_first_large = with_env(function(h)
	local paths = big_list(12)
	reset(paths)

	il.remove(paths[1])

	local want_paths, want_makes = {}, {}
	for i = 2, 12 do
		want_paths[#want_paths + 1] = paths[i]
		want_makes[#want_makes + 1] = make_for(i)
	end

	local list = il.get(false)
	h.eq('remove(first): get(false) paths in order', table.concat(want_paths, '\n'), joined_paths(list))
	h.eq('remove(first): get(false) indexes sequential', seq_indexes(11), joined_indexes(list))

	local full = il.get(true)
	h.eq('remove(first): get(true) paths in order', table.concat(want_paths, '\n'), joined_paths(full))
	h.eq('remove(first): get(true) exif values in order', table.concat(want_makes, ','), joined_makes(full))
end)

-- remove the middle of a 12-entry list
T.remove_middle_large = with_env(function(h)
	local paths = big_list(12)
	reset(paths)

	il.remove(paths[6])

	local want_paths, want_makes = {}, {}
	for i, p in ipairs(paths) do
		if i ~= 6 then
			want_paths[#want_paths + 1] = p
			want_makes[#want_makes + 1] = make_for(i)
		end
	end

	local list = il.get(false)
	h.eq('remove(middle): get(false) paths in order', table.concat(want_paths, '\n'), joined_paths(list))
	h.eq('remove(middle): get(false) indexes sequential', seq_indexes(11), joined_indexes(list))

	local full = il.get(true)
	h.eq('remove(middle): get(true) paths in order', table.concat(want_paths, '\n'), joined_paths(full))
	h.eq('remove(middle): get(true) exif values in order', table.concat(want_makes, ','), joined_makes(full))
end)

-- remove the tail of a 12-entry list
T.remove_last_large = with_env(function(h)
	local paths = big_list(12)
	reset(paths)

	il.remove(paths[12])

	local want_paths, want_makes = {}, {}
	for i = 1, 11 do
		want_paths[i] = paths[i]
		want_makes[i] = make_for(i)
	end

	local list = il.get(false)
	h.eq('remove(last): get(false) paths in order', table.concat(want_paths, '\n'), joined_paths(list))
	h.eq('remove(last): get(false) indexes sequential', seq_indexes(11), joined_indexes(list))

	local full = il.get(true)
	h.eq('remove(last): get(true) paths in order', table.concat(want_paths, '\n'), joined_paths(full))
	h.eq('remove(last): get(true) exif values in order', table.concat(want_makes, ','), joined_makes(full))
end)

-- remove a few entries one by one from a 12-entry list
T.remove_few_large = with_env(function(h)
	local paths = big_list(12)
	reset(paths)

	il.remove(paths[2])
	il.remove(paths[6])
	il.remove(paths[11])

	local dropped = { [2] = true, [6] = true, [11] = true }
	local want_paths, want_makes = {}, {}
	for i, p in ipairs(paths) do
		if not dropped[i] then
			want_paths[#want_paths + 1] = p
			want_makes[#want_makes + 1] = make_for(i)
		end
	end

	local list = il.get(false)
	h.eq('remove(few): get(false) paths in order', table.concat(want_paths, '\n'), joined_paths(list))
	h.eq('remove(few): get(false) indexes sequential', seq_indexes(9), joined_indexes(list))

	local full = il.get(true)
	h.eq('remove(few): get(true) paths in order', table.concat(want_paths, '\n'), joined_paths(full))
	h.eq('remove(few): get(true) exif values in order', table.concat(want_makes, ','), joined_makes(full))
end)

-- remove several entries at once from a 12-entry list
T.remove_batch_large = with_env(function(h)
	local paths = big_list(12)
	reset(paths)

	il.remove { paths[3], paths[4] }

	local want_paths, want_makes = {}, {}
	for i, p in ipairs(paths) do
		if i ~= 3 and i ~= 4 then
			want_paths[#want_paths + 1] = p
			want_makes[#want_makes + 1] = make_for(i)
		end
	end

	local list = il.get(false)
	h.eq('remove(batch): get(false) paths in order', table.concat(want_paths, '\n'), joined_paths(list))
	h.eq('remove(batch): get(false) indexes sequential', seq_indexes(10), joined_indexes(list))

	local full = il.get(true)
	h.eq('remove(batch): get(true) paths in order', table.concat(want_paths, '\n'), joined_paths(full))
	h.eq('remove(batch): get(true) exif values in order', table.concat(want_makes, ','), joined_makes(full))
end)

H.maybe_standalone(T)

return T
