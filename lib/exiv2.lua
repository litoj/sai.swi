-- Lua wrapper for exiv2_to_lua C module with auto-compilation.
---@module 'swi.lib.exiv2'

local mod_name = 'exiv2_to_lua'
local path = debug.getinfo(1, 'S').source:match '(/.*/)' .. mod_name
local so_path = path .. '.so'
local cpp_path = path .. '.cpp'

if not os.rename(so_path, so_path) then
	local out = swi.exec(string.format('g++ -O3 -shared -fPIC -o %s %s 2>&1 >/dev/null', so_path, cpp_path))
	if out ~= '' then swi.log('Failed to compile module: ' .. out) end
end

local loader = package.loadlib(so_path, 'luaopen_' .. mod_name)
if not loader then error('Unable to load library: ' .. so_path) end

---@class exiv2
---@field get_exif fun(path:string): meta:{[string]:string}|nil, err:string?
return loader()
