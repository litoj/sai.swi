-- Lua wrapper for exiv2_to_lua C module with auto-compilation.
---@module 'swi.lib.exiv2'

local mod_name = 'exiv2_to_lua'
local so_path = debug.getinfo(1, 'S').source:match '(/.*/)' .. mod_name .. '.so'

if not os.rename(so_path, so_path) then return require('swi.lib.utils').compile_and_load(so_path) end

---@class exiv2
---@field get_exif fun(path:string): meta:{[string]:string}|nil, err:string?
return package.loadlib(so_path, 'luaopen_' .. mod_name)()
