-- Lua wrapper for exiv2 C++ module with auto-compilation.
---@module 'sai.bridge.exiv2'

---@class exiv2
---@field add_meta fun(img:swayimg.entry|swayimg.image)
---Reads every entry's meta and its actual pixel resolution (decoded from
---the data, not the exif tags) in place: `meta`, `width`, `height`.
---@field load_all fun(entries:swayimg.image[])
local M = {
	---@type {[string]: swayimg.image}
	_loaded = {}, ---@private
}

---@type exiv2
---@diagnostic disable-next-line: missing-fields
local exiv2 = {}
setmetatable(exiv2, {
	__index = function(_, idx)
		exiv2 = require('sai.bridge.shell').load_so(debug.getinfo(1, 'S').short_src:sub(1, -4) .. 'so')
		return exiv2[idx]
	end,
})

function M.add_meta(img)
	local old = M._loaded[img.path]
	if old then
		img.meta = old.meta
		img.width = old.width
		img.height = old.height
	else
		exiv2.add_meta(img)
		M._loaded[img.path] = img
	end
end

function M.load_all(entries)
	local todo = {}
	for _, img in pairs(entries) do
		local old = M._loaded[img.path]
		if old then
			img.meta = old.meta
			img.width = old.width
			img.height = old.height
		else
			todo[#todo + 1] = img
		end
	end

	exiv2.load_all(todo)

	for _, img in ipairs(todo) do
		M._loaded[img.path] = img
	end
end

return M
