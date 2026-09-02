-- Lua wrapper for exiv2 C++ module with auto-compilation.
---@module 'sai.bridge.exiv2'

---@class exiv2
---@field get_meta fun(path:string): meta:{[string]:string}|nil, err:string?
---@field load_all fun(entries:swayimg.entry[])
local M = require('sai.bridge.shell').load_so(debug.getinfo(1, 'S').short_src:sub(1, -4) .. 'so')
return M
