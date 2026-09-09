---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for the sai.imagelist api: the cached `_list` of `get()` - while
---its size stands the same table comes back, a size change re-reads it
---from the app, and `get(true)` loads the full image data (exif, actual
---pixel resolution) exactly once per list version. Sai-side mutations and
---order changes drop the cache, the order rebuild sorts it in place.
---The tests share one api stack (and its cache), so each resets the list
---first: they stay independent of the run order.
---Runs over a recording api stack (see H.recording_stack).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

-- counts every file the bridge was asked to read
local loads = {}
package.loaded['sai.bridge.exiv2'] = {
	-- sets the meta and the actual pixel dimensions in place, like the
	-- real bridge (the exif tags can lie about the size, the decoded
	-- structure cannot)
	load_all = function(list)
		for _, e in ipairs(list) do
			loads[#loads + 1] = e.path
			e.meta = { ['Exif.Image.Make'] = 'Canon' }
			e.width, e.height = 6000, 4000
		end
	end,
}

local env = H.recording_stack()
local with_env = env.with_env

-- the raw imagelist stub: faithful to the app, every get() hands out FRESH
-- entry tables and they never carry meta themselves
local entries = {}
local raw_il = env.swayimg.imagelist
raw_il.size = 0
raw_il.order = 'numeric' -- the app's default (swayimg defaults.hpp)
raw_il.get = function()
	local out = {}
	for i, e in ipairs(entries) do
		out[i] = { path = e.path, index = i, size = e.size, mtime = e.mtime, mark = e.mark or false }
		if e.meta then out[i].meta = e.meta end
		if e.width then out[i].width = e.width end
		if e.height then out[i].height = e.height end
	end
	return out
end
raw_il.clear = function()
	entries = {}
	raw_il.size = 0
end
raw_il.add = function(x)
	for _, p in ipairs(type(x) == 'table' and x or { x }) do
		entries[#entries + 1] = { path = p }
	end
	raw_il.size = #entries
end
raw_il.remove = function(x)
	for _, p in ipairs(type(x) == 'table' and x or { x }) do
		for i, e in ipairs(entries) do
			if e.path == p then
				table.remove(entries, i)
				break
			end
		end
	end
	raw_il.size = #entries
end

local T = {}

-- the list cache: while its size stands get() hands out the same table, a
-- size change re-reads it from the app; a plain get() never touches exiv2
T.list_cache = with_env(function(h)
	loads = {}
	local il = env.sai.imagelist
	il.clear()
	entries = {
		{ path = '/tmp/sai/cache/a.jpg' },
		{ path = '/tmp/sai/cache/b.jpg' },
	}
	raw_il.size = 2

	local list = il.get()
	h.eq('two entries', 2, #list)
	h.eq('no bridge reads on a plain get', 0, #loads)

	local again = il.get()
	h.ok('the cached list is returned as-is', again == list)
	h.eq('still no reads', 0, #loads)

	-- the app changes the list behind sai's back: a size change refetches
	raw_il.add '/tmp/sai/cache/c.jpg'
	again = il.get()
	h.ok('a size change re-reads the list', again ~= list)
	h.eq('three entries now', 3, #again)
	h.eq('still no reads', 0, #loads)
end)

-- the full load: get(true) reads every entry through the bridge exactly
-- once per list version, the loaded entries stay cached with the list
T.full_load = with_env(function(h)
	loads = {}
	local il = env.sai.imagelist
	il.clear()
	entries = {
		{ path = '/tmp/sai/full/a.jpg' },
		{ path = '/tmp/sai/full/b.jpg' },
	}
	raw_il.size = 2

	local list = il.get(true)
	h.eq('the exif got loaded', 'Canon', list[1].meta['Exif.Image.Make'])
	h.eq('the actual resolution got loaded', 6000, list[1].width)
	h.eq('the actual resolution got loaded (height)', 4000, list[1].height)
	h.eq('each file read exactly once', '/tmp/sai/full/a.jpg\n/tmp/sai/full/b.jpg', table.concat(loads, '\n'))

	local again = il.get(true)
	h.ok('the loaded list is returned as-is', again == list)
	h.eq('no file re-read over the loaded list', 2, #loads)

	-- a plain get() over a loaded list hands out the loaded entries
	again = il.get()
	h.ok('same table', again == list)
	h.eq('the loaded meta rides along', 'Canon', again[1].meta['Exif.Image.Make'])
	h.eq('still no reads', 2, #loads)
end)

-- sai-side mutations drop the cached list: the next get() refetches it
-- bare, the next full one re-reads it
T.mutations_invalidate = with_env(function(h)
	loads = {}
	local il = env.sai.imagelist
	il.clear()
	entries = {
		{ path = '/tmp/sai/mut/a.jpg' },
		{ path = '/tmp/sai/mut/b.jpg' },
	}
	raw_il.size = 2
	il.get(true)
	h.eq('both read', 2, #loads)

	il.remove '/tmp/sai/mut/a.jpg'
	local list = il.get()
	h.eq('one entry left', 1, #list)
	h.eq('the removed path is gone', '/tmp/sai/mut/b.jpg', list[1].path)
	h.ok('the refetched entry is bare', list[1].meta == nil)
	il.get(true)
	h.eq('the new version re-read', 3, #loads)
	h.eq('the read was the surviving path', '/tmp/sai/mut/b.jpg', loads[3])

	il.clear()
	h.eq('clear empties the cached list', 0, #il.get())

	il.add '/tmp/sai/mut/c.jpg'
	list = il.get()
	h.eq('one entry added', 1, #list)
	h.eq('the added path reads on the next full get', '/tmp/sai/mut/c.jpg', il.get(true)[1].path)
	h.eq('four reads total', 4, #loads)
end)

-- the order rebuild sorts the cached list in place: the new order reads
-- back through sai with no refetch and no re-read
T.order_rebuild = with_env(function(h)
	loads = {}
	local il = env.sai.imagelist
	il.clear()
	entries = {
		{ path = '/tmp/sai/rebuild/b.jpg' },
		{ path = '/tmp/sai/rebuild/a.jpg' },
	}
	raw_il.size = 2
	il.get(true)
	h.eq('both read', 2, #loads)

	il.order = function(a, b) return a.path < b.path end
	local list = il.get()
	h.eq('the new order reads back through sai', '/tmp/sai/rebuild/a.jpg', list[1].path)
	h.eq('no refetch over the rebuild', 2, #loads)
	h.eq('the loaded meta survived the rebuild', 'Canon', list[1].meta['Exif.Image.Make'])

	il.order = 'none'
end)

-- the order field: the app's own enum forwards to the raw api (which
-- re-sorts right away), a comparator takes over (the raw order parks at
-- 'none' while sai owns the sorting) until an enum clears it
T.order_field = with_env(function(h)
	loads = {}
	local il = env.sai.imagelist
	il.clear()
	entries = {
		{ path = '/tmp/sai/order/b.jpg' },
		{ path = '/tmp/sai/order/a.jpg' },
	}
	raw_il.size = 2

	il.order = 'alpha'
	h.eq('the enum forwards to the raw api', 'alpha', env.swayimg.imagelist.order)
	h.eq('the enum reads back through the proxy', 'alpha', il.order)

	il.order = function(a, b) return a.path < b.path end
	h.eq('a comparator takes over', 'function', type(il.order))
	h.eq("the raw order parks at 'none' behind the comparator", 'none', env.swayimg.imagelist.order)
	h.eq('the comparator re-sorted the list', '/tmp/sai/order/a.jpg', env.swayimg.imagelist.get()[1].path)

	il.order = 'none'
	h.eq("'none' clears the comparator", 'none', il.order)
	h.eq('the list stands as the last rebuild left it', '/tmp/sai/order/a.jpg', env.swayimg.imagelist.get()[1].path)
end)

H.maybe_standalone(T)

return T
