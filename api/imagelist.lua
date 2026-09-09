---@module 'sai.api.imagelist'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'
local proxy = require 'sai.api.proxy'
local exiv2 = require 'sai.bridge.exiv2'

local api = swayimg.imagelist

---@class sai.api.imagelist: sai.imagelist
---@field private _order order_t|fun(a:swayimg.entry, b:swayimg.entry):boolean the comparator half of the `order` field
---@field private _list swayimg.entry[] the cached image list, current while its size stands
---@field private _loaded boolean whether the cached list carries the full image data
---@diagnostic disable-next-line: missing-fields
local M = { super = api, _path = 'sai.imagelist', marked = {}, _order = 'alpha', _list = {}, _loaded = false }

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
	local sel = sai.mode ~= 'gallery' and swayimg[swayimg.mode].open_path or swayimg.gallery.select_path
	local sapi = swayimg[swayimg.mode] ---@type swayimg_appmode

	if type(next(list)) == 'string' then
		for p, _ in pairs(list) do
			---@diagnostic disable-next-line: param-type-mismatch
			sel(p)
			sapi.mark_image(enabled)
		end
	else
		for _, i in ipairs(list) do
			sel(i.p)
			sapi.mark_image(enabled)
		end
	end
	sel(restore_path)
end

function M.remove(x)
	local ci = M.get_current()
	if x == ci.path then e.trigger { event = 'ImgChangedPre', match = swayimg.mode, data = ci } end
	api.remove(x)
	set_mark(x, false)
	M._list, M._loaded = {}, false -- the order changed: refetch on the next get
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

---@diagnostic disable-next-line: undefined-field
function M.get_current() return sai[swayimg.mode].get_image() or U.dummy_image end

function M.get(full)
	if api.size ~= #M._list then
		M._list = api.get()
		M._loaded = false
	end
	if full and not M._loaded then
		exiv2.load_all(M._list)
		M._loaded = true
	end
	return M._list
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

	local paths = {}
	for _, entry in ipairs(list) do
		paths[#paths + 1] = entry.path
	end
	api.clear()
	api.add(paths)
	last_lsize = api.size

	mark_raw(mmap, true, current)
end

function M.add(x)
	api.add(x)
	last_lsize = api.size
	M._list, M._loaded = {}, false -- the order changed: refetch on the next get
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
	if type(M._order) == 'function' then
		local ok, err = pcall(apply_order)
		if not ok then sai.log('Inconsistent order due to error: ' .. err) end
	end
end

---The `order` field: a comparator the list is kept ordered by, or the app's
---own order setting (forwarded to the raw api, which re-sorts right away).
---`'none'` stops the ordering, keeping the list as it is.
---@protected
---@param val order_t|fun(a:swayimg.entry, b:swayimg.entry):boolean
function M:set_order(val)
	local old = M._order
	M._order = val
	if type(val) == 'function' then
		api.order = 'none'
		local ok, err = pcall(apply_order)
		if not ok then
			M:set_order(old)
			sai.log('Invalid order function: ' .. err)
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

---@protected
function marked:set_size() error 'cannot set imagelist.marked.size' end
---@protected
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
		if ev.data.cmd:find('rm', 1, true) or ev.data.cmd:find('mv', 1, true) then --
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
	---@diagnostic disable-next-line: redefined-local
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
return proxy.new(M)
