---@module 'swi.api.imagelist'

local e = require 'swi.api.eventloop'
local U = require 'swi.lib.utils'

local api = swayimg.imagelist

---@type swi.imagelist
---@diagnostic disable-next-line: missing-fields
local M = { super = api, _path = 'swi.imagelist', marked = {} }

local mlist = {}
local msize = 0

---@type swi.imagelist.marked
local marked = M.marked
local last_lsize = 0

local function set_mark(x, enabled)
	if msize ~= marked.size() then
	else
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
	end

	e.trigger { event = 'OptionSet', match = 'swi.imagelist.marked.size', data = msize }
end

function marked.size()
	local lsize = api.size()
	if lsize ~= last_lsize then
		mlist = {}
		for _, v in ipairs(api.get()) do
			if v.mark then
				mlist[v.path] = 1
				msize = msize + 1
			end
		end
		last_lsize = lsize
	end
	return msize
end

function marked.get()
	local t = {}
	for p, _ in pairs(mlist) do
		t[#t + 1] = p
	end
	return t
end

-- TODO: allow set_current also generally for imagelist - traverse for gallery and open for viewer
function marked.set_current(enabled)
	---@diagnostic disable-next-line: redefined-local
	local api = swayimg[swayimg.get_mode()] ---@type swayimg.gallery
	local img = api.get_image()
	if enabled == 'toggle' then enabled = not img.mark end
	api.mark_image(enabled)
	set_mark(img.path, enabled)
end

function M.get_current() return swi[swayimg.get_mode()].get_image() or U.dummy_image end
function M.remove(x)
	local ci = M.get_current()
	if x == ci.path then e.trigger { event = 'ImgChangedPre', data = ci } end
	api.remove(x)
	set_mark(x, false)
	e.trigger { event = 'OptionSet', match = 'swi.imagelist.size', data = last_lsize }
end
function M.add(x)
	api.add(x)
	last_lsize = api.size()
	e.trigger { event = 'OptionSet', match = 'swi.imagelist.size', data = last_lsize }
end

return require('swi.api.proxy').new(M)
