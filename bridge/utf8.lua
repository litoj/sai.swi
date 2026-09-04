-- Lua wrapper for a utf8 C module: a system-installed one (e.g. the
-- lua51-luautf8 package) is preferred; otherwise the stock Lua 5.3 source is
-- downloaded, patched for LuaJIT and compiled, mirroring the exiv2 bridge module.
---@module 'sai.bridge.utf8'

local shell = require 'sai.bridge.shell'

-- the pristine Lua 5.3 source needs two patches to compile against LuaJIT
local function luajit_compat(src)
	if not src:find 'luaopen_utf8' or not src:find 'utflen' then return false end

	-- the lua-internal header is not distributed next to the source
	local n
	src, n = src:gsub('#include "lprefix%.h"\n', '')
	if n ~= 1 then return false end

	-- LuaJIT's string formatting has no '%U' escape: encode the codepoint manually
	src, n = src:gsub(
		'lua_pushfstring%(L, "%%U", %(long%)code%)',
		function()
			return [[{
    char b[4];
    int n = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    if (n == 1) b[0] = (char)code;
    else {
      int i = n;
      while (--i) { b[i] = (char)(0x80 | (code & 0x3F)); code >>= 6; }
      b[0] = (char)((0xFF << (8 - n)) | code);
    }
    lua_pushlstring(L, b, n);
  }]]
		end
	)
	if n ~= 1 then return false end
	return src
end

---@class utf8
---@field charpattern string pattern matching exactly one utf8 character
---@field len fun(s:string, i?:integer, j?:integer):integer? number of characters in the range; nil + position if invalid
---@field char fun(...:integer):string characters for the given codepoints
---@field codepoint fun(s:string, i?:integer, j?:integer):...integer codepoints of characters in the range
---@field offset fun(s:string, n:integer, i?:integer):integer? byte position of the n-th character relative to i
---@field codes fun(s:string):fun(s:string, pos:integer):integer, integer iterator over position + codepoint pairs
---@field sub fun(s:string, i:integer, j?:integer):string char-aware sub()
---@field isvalid fun(s:string):boolean
---@field clean fun(s:string, repl?:string):string replace invalid byte sequences
---@field find fun(s:string, p:string, init?:integer):integer?, integer? char-aware find() (system module only)
---@field gmatch fun(s:string, p:string):fun():string char-aware gmatch() (system module only)
---@field gsub fun(s:string, p:string, r:any, n?:integer):string, integer char-aware gsub() (system module only)

-- system module names: lua51-luautf8 ships as 'lua-utf8', some distros use 'utf8'
-- (probing can hit unrelated modules, so verify the core api before using it)
local M
for _, name in ipairs { 'lua-utf8', 'utf8' } do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == 'table' and mod.len and mod.offset then
		M = mod
		break
	end
end
if not M then
	local base = debug.getinfo(1, 'S').short_src:sub(1, -4)
	if not os.rename(base .. 'c', base .. 'c') then
		shell.download('https://raw.githubusercontent.com/lua/lua/v5.3.6/lutf8lib.c', base .. 'c', luajit_compat)
	end
	M = shell.load_so(base .. 'so')
end

-- unify the module surface: the stock Lua 5.3 core lacks these conveniences
if not M.sub then
	function M.sub(s, i, j)
		j = j or -1
		local from = M.offset(s, i) or #s + 1
		local to = j == -1 and #s or (M.offset(s, j + 1) or #s + 1) - 1
		return s:sub(from, to)
	end
end
if not M.isvalid then
	function M.isvalid(s) return M.len(s) ~= nil end
end
if not M.clean then
	function M.clean(s, repl)
		repl = repl or '?'
		local out, pos = {}, 1
		while pos <= #s do
			local invalid = select(2, M.len(s, pos))
			if not invalid then break end -- the rest is valid
			out[#out + 1] = s:sub(pos, invalid - 1) .. repl
			pos = invalid + 1
		end
		out[#out + 1] = s:sub(pos)
		return table.concat(out)
	end
end

-- callable form: coerce a string into a valid utf8 string (invalid sequences get replaced)
return setmetatable(M, {
	__call = function(_, s)
		if type(s) ~= 'string' or M.isvalid(s) then return s end
		return M.clean(s)
	end,
})
