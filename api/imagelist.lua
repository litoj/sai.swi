---@module 'sai.api.imagelist'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'
local proxy = require 'sai.api.proxy'
local exiv2 = require 'sai.bridge.exiv2'

local api = swayimg.imagelist

---@class sai.api.imagelist: sai.imagelist
local M = {
	super = api,
	_path = 'sai.imagelist',
	marked = {},
	--- <https://github.com/litoj/swayimg/blob/master/src/defaults.hpp#L33>

	---@type order_t|fun(a:swayimg.entry, b:swayimg.entry):boolean a comparator keeps the list ordered, 'none' stops it
	_order = 'alpha',
	_reverse = false,
	_adjacent = false,
	_recursive = false,
	_fsmon = true,

	---@type swayimg.entry[] current while its size stands
	_list = {},
	_loaded = false, --- whether the cached list carries the full image data
}

---@type {[string]:1} map of marked files
local mmap = {}
local msize = 0

---@class sai.api.imagelist.marked: sai.imagelist.marked
local marked = M.marked
local last_lsize = api.size

---@param x string|string[]
---@param enabled? boolean
local function set_mark(x, enabled)
	if msize ~= marked.size then
		return -- already updated
	end

	local changed
	for _, path in ipairs(U.tabled(x)) do
		local current = not not mmap[path]
		if enabled ~= current then
			if U.get_or_default(enabled, not current) then
				mmap[path] = 1
				msize = msize + 1
			else
				mmap[path] = nil
				msize = msize - 1
			end
			changed = true
		end
	end
	if not changed then return end

	e.trigger { event = 'OptionSet', match = 'sai.imagelist.marked.size', data = msize }
end

-- the raw open_path is used on purpose: sai.viewer.go would fire a
-- sai.imagelist.size event on every hop of the restore
---@param list string|string[]|{[string]:1}
---@param enabled? boolean
---@param restore_path? string
local function mark_raw(list, enabled, restore_path)
	list = U.tabled(list)
	restore_path = restore_path or M.get_current().path
	local sapi = swayimg[swayimg.mode] ---@type swayimg_appmode
	---@diagnostic disable-next-line: undefined-field
	local sel = sai.mode ~= 'gallery' and sapi.open_path or sapi.select_path

	if type(next(list)) == 'string' then -- {[path]=1} map
		for p, _ in pairs(list) do
			sel(p)
			sapi.mark_image(enabled)
		end
	else -- list of paths (or entries)
		for _, p in ipairs(list) do
			sel(type(p) == 'table' and p.path or p)
			sapi.mark_image(enabled)
		end
	end
	sel(restore_path)
end

function M.remove(x)
	local ci = M.get_current()
	if x == ci.path then e.trigger { event = 'ImgChangedPre', match = sai.mode, data = ci } end
	api.remove(x)
	-- efficiently reindex when the cost of rehashing all metadata > linear table.remove
	if M._loaded and #M._list - api.size < 20 then
		local new = api.get()
		local j = #M._list
		for i = #new, 1, -1 do
			while M._list[j].path ~= new[i].path do
				table.remove(M._list, j)
				j = j - 1
			end
			M._list[j].index = i
			if i == j then break end -- nothing was added, so same index means we are in sync
			j = j - 1
		end
	else
		M._list, M._loaded = {}, false
	end
	set_mark(x, false)
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
end
function M.clear()
	api.clear()

	mmap = {}
	msize = 0
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.marked.size', data = msize }

	last_lsize = 0
	M._list, M._loaded = {}, false -- the order changed: refetch on the next get
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
end

function M.get_current() return sai.modes[1].get_image() or U.dummy_image end

function M.select(path_or_idx)
	local mode = swayimg.mode
	local sapi = swayimg[mode] ---@type swayimg.viewer|swayimg.gallery

	e.trigger {
		event = 'ImgChangedPre',
		mode = mode,
		match = mode,
		data = mode == 'gallery' and sapi.get_image() or U.lazyimg(sapi),
	}

	local img = M.get(path_or_idx)
	if not img and type(path_or_idx) == 'string' then
		M.add(path_or_idx)
		img = M.get(path_or_idx)
	end
	if not img then return false end
	(sapi.open_path or sapi.select_path)(img and img.path or path_or_idx)
end

---@type (fun(with_meta:boolean?):swayimg.entry[]|swayimg.image[])|(fun(img_key:string|integer):swayimg.image?)
function M.get(x)
	if api.size ~= #M._list then
		M._list = api.get()
		M._loaded = false
	else
		-- TODO: to keep the marks up-to-date we either need a map or this
		for _, img in ipairs(M._list) do
			img.mark = not not mmap[img.path]
		end
	end

	if type(x) == 'boolean' or x == nil then
		if x and not M._loaded then
			exiv2.load_all(M._list)
			M._loaded = true
		end
		return M._list
	end

	local img = M.has(x)
	if not img then return end
	if not M._loaded then exiv2.add_meta(img) end
	return img
end

function M.has(x)
	local img
	if type(x) == 'number' then
		img = M._list[x > 0 and x or (#M._list + 1 + x)]
	else
		for _, v in pairs(M._list) do -- TODO: consider when a map is worth it, + maybe a `img.hide` tag?
			if v.path == x then
				img = v
				break
			end
		end
	end
	return img
end

local function apply_order()
	local list = M.get(true)
	if #list < 2 then return end

	-- the cached entries outlive the raw ones: refresh the positional and
	-- mutable fields before the comparator sees them
	marked:get_size()
	for i, e in ipairs(list) do
		e.index = i
		e.mark = mmap[e.path] ~= nil
	end

	table.sort(list, M._order)

	local current = M.get_current().path

	local i = 1
	while list[i] and list[i].index == i do
		i = i + 1
	end

	if i > #list then return end -- no change

	local paths, re_marks = {}, {} -- paths to reorder + which of them were marked
	for j = i, #list do
		paths[#paths + 1] = list[j].path
		if mmap[list[j].path] then re_marks[#re_marks + 1] = list[j].path end
		list[j].index = j
	end

	if i == 1 then -- the whole list is out of order
		api.clear()
	else
		api.remove(paths)
	end
	api.add(paths)
	last_lsize = api.size

	-- only the rebuilt rows lost their marks: re-assert theirs, keep the cursor
	mark_raw(re_marks, true, current)
end

function M.add(x, adjacent)
	local old = api.size
	if adjacent == nil then adjacent = M.adjacent end

	if type(x) == 'string' and adjacent and not U.is_dir(x) then
		api.recursive = false
		x = x:match '.+/'
	else
		api.recursive = M.recursive
	end
	api.add(x)

	if old == api.size then return false end

	last_lsize = api.size
	M._list, M._loaded = {}, false -- the order changed: refetch on the next get
	if type(M._order) == 'function' then
		-- removal preserves order, a single add re-sorts once: no batch state needed,
		-- just fire past the rebuild so observers never see the intermediate appended list
		local ok, err = pcall(apply_order)
		if not ok then sai.log('Inconsistent order due to error: ' .. err) end
	end
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
	return true
end

---@protected
---@type fun(self: sai.api.imagelist, val: order_t|fun(a:swayimg.entry, b:swayimg.entry):boolean):boolean
function M:set_order(val)
	local old = M._order
	M._order = val
	if type(val) == 'function' then
		api.order = 'none'
		local ok, err = pcall(apply_order)
		if not ok then
			M:set_order(old)
			sai.log('Order function failed: ' .. err)
			return false
		end
	else
		api.order = val
		if val ~= 'none' then
			M._list, M._loaded = {}, false
		end
	end
	return true
end

-- ensure that we return backed value (possibly fn) and not the api value ('none' for fn)
---@protected
function M:get_order() return self._order end

-- the startup list comes unsorted from the app: order it once sai is up
e.subscribe {
	event = 'SwiEnter',
	callback = function()
		if type(M._order) == 'function' then apply_order() end
		return true
	end,
}

function marked:set_size() error 'cannot set imagelist.marked.size' end
function marked:get_size()
	local lsize = api.size
	if lsize ~= last_lsize then
		mmap = {}
		local omsize = msize
		msize = 0
		for _, v in ipairs(api.get()) do
			if v.mark then
				mmap[v.path] = 1
				msize = msize + 1
			end
		end
		last_lsize = lsize
		if msize ~= omsize then e.trigger { event = 'OptionSet', match = 'sai.imagelist.marked.size', data = msize } end
		e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
	end
	return msize
end

-- TODO: replace with a proper imagelist change listener when I convince artemsen to add one
-- <https://github.com/artemsen/swayimg/issues/561>
e.subscribe {
	event = 'User',
	match = 'ShellCmdPost',
	callback = function(ev)
		-- if there is a chance that images disappeared, then check for imagelist size changes
		if ev.data.cmd:find('rm', 1, true) or ev.data.cmd:find('mv', 1, true) then
			sai.defer_fn(marked.get_size, 100)
		end
	end,
}

function marked.add(path_or_list)
	mark_raw(path_or_list, true)
	set_mark(path_or_list, true)
end
function marked.remove(path_or_list)
	mark_raw(path_or_list, false)
	set_mark(path_or_list, false)
end
function marked.toggle(path_or_list)
	mark_raw(path_or_list)
	set_mark(path_or_list)
end
function marked.set_current(enabled)
	local api = swayimg[swayimg.mode] ---@type swayimg.gallery
	local img = api.get_image() or error 'no active image to mark'
	if enabled == 'toggle' then enabled = not img.mark end
	api.mark_image(enabled)
	set_mark(img.path, enabled)
end

function marked.get()
	local t = {}
	for p, _ in pairs(mmap) do
		t[#t + 1] = p
	end
	return t
end

proxy.new(marked)
proxy.new(M)
return M
