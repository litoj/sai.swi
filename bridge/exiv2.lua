-- Auto-compiles the C++ module on demand.
---@module 'sai.bridge.exiv2'

---@class exiv2
---@field add_meta fun(img:swayimg.entry|swayimg.image) read one entry's meta and pixel resolution in place: `meta`, `width`, `height`
---@field load_all fun(entries:swayimg.image[]) read every entry's meta and pixel resolution in place
local M = {
	---@type {[string]: swayimg.image}
	_loaded = {}, ---@private
}

---@type exiv2
---@diagnostic disable-next-line: missing-fields
local exiv2 = {}
setmetatable(exiv2, {
	__index = function(_, idx)
		-- the .so resolves exiv2 symbols from the global pool: swayimg provides
		-- them (its own linked libexiv2), a standalone luajit (tests) does not;
		-- the handle stays unused, the load itself is the side effect
		local _ = not _G.sai and require('ffi').load('exiv2', true)
		exiv2 = require('sai.bridge.shell').load_so(debug.getinfo(1, 'S').short_src:sub(1, -4) .. 'so')
		return exiv2[idx]
	end,
})

---Serve cached values when present. Entries carry their mtime: a changed
---mtime re-reads the file instead of serving stale meta.
---@param img swayimg.entry|swayimg.image entry to fill in place
function M.add_meta(img)
	local old = M._loaded[img.path]
	if old and old.mtime == img.mtime then
		img.meta = old.meta
		img.width = old.width
		img.height = old.height
	else
		exiv2.add_meta(img)
		M._loaded[img.path] = img
	end
end

---Serve cached values when present (mtime-guarded, like add_meta).
---@param entries swayimg.image[] entries to fill in place
function M.load_all(entries)
	local todo = {}
	for _, img in pairs(entries) do
		local old = M._loaded[img.path]
		if old and old.mtime == img.mtime then
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
