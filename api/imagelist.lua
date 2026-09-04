---@module 'sai.api.imagelist'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'
local proxy = require 'sai.api.proxy'

local api = swayimg.imagelist

---@class sai.api.imagelist: sai.imagelist
---@diagnostic disable-next-line: missing-fields
local M = { super = api, _path = 'sai.imagelist', marked = {} }

local mlist = {}
local msize = 0

---@class sai.api.imagelist.marked: sai.imagelist.marked
local marked = M.marked
local last_lsize = api.size

local function set_mark(x, enabled)
	if msize ~= marked.size() then
		return -- already updated
	end

	local changed
	for _, path in ipairs(type(x) == 'string' and { x } or x) do
		if enabled == not mlist[path] then
			if enabled then
				mlist[path] = 1
				msize = msize + 1
			else
				mlist[path] = nil
				msize = msize - 1
			end
			changed = true
		end
	end
	if not changed then return end

	e.trigger { event = 'OptionSet', match = 'sai.imagelist.marked.size', data = msize }
end

---@protected
function M:set_size() error 'cannot set imagelist.size' end
---@protected
function M:get_size() return api.size end

function M.remove(x)
	local ci = M.get_current()
	if x == ci.path then e.trigger { event = 'ImgChangedPre', match = swayimg.mode, data = ci } end
	api.remove(x)
	set_mark(x, false)
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
end
function M.clear()
	api.clear()

	mlist = {}
	msize = 0
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.marked.size', data = msize }

	last_lsize = 0
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
end
function M.add(x)
	api.add(x)
	last_lsize = api.size
	e.trigger { event = 'OptionSet', match = 'sai.imagelist.size', data = last_lsize }
end

function M.get_current() return sai[swayimg.mode].get_image() or U.dummy_image end

---@protected
function marked:set_size() error 'cannot set imagelist.marked.size' end
---@protected
function marked:get_size()
	local lsize = api.size
	if lsize ~= last_lsize then
		mlist = {}
		local omsize = msize
		msize = 0
		for _, v in ipairs(api.get()) do
			if v.mark then
				mlist[v.path] = 1
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

-- TODO: allow set_current also generally for imagelist - traverse for gallery and open for viewer
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
	for p, _ in pairs(mlist) do
		t[#t + 1] = p
	end
	return t
end

proxy.new(marked)
return proxy.new(M)
