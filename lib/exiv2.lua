-- Lua wrapper for exiv2_to_lua C module with auto-compilation.
---@module 'sai.lib.exiv2'

local mod_name = 'exiv2_to_lua'
local so_path = debug.getinfo(1, 'S').source:match '[^@]+/' .. mod_name .. '.so'

---@class exiv2
---@field get_meta fun(path:string): meta:{[string]:string}|nil, err:string?
---@field load_all fun(entries:swayimg.entry[])

---@type exiv2
local M
if not os.rename(so_path, so_path) then
	M = require('sai.lib.utils').compile_and_load(so_path) ---@type exiv2
else
	local fn, err = package.loadlib(so_path, 'luaopen_' .. mod_name)
	if not fn then error(err) end
	M = fn() ---@type exiv2
end
return M
