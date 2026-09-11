---@module 'sai.lib.utils'
---@class sai.lib.utils
local U = { debug_perf = os.getenv 'DEBUG_PERF' == '1' }
local exiv2 = require 'sai.bridge.exiv2'

---@type swayimg.image
U.dummy_image = {
	path = 'dummy image',
	index = 0,
	meta = {},
	format = '',
	width = 0,
	height = 0,
	frames = 0,
	size = 0,
	-- the app hands the modification time over as a string, like {time} in
	-- the text scheme: the dummy mirrors the field's declared type
	mtime = '0',
	mark = false,
}

---Proxy that loads once on first index, then reads the loaded table.
---@param fn fun():table
---@return table
function U.lazyload(fn)
	return setmetatable({}, {
		__index = function(self, idx)
			-- load just once and replace with the actual data
			local data = fn()
			setmetatable(self, { __index = data })

			return data[idx]
		end,
	})
end

---@param api swayimg.viewer|swayimg.gallery
---@return swayimg.image current image, or a dummy when the list is empty
function U.lazyimg(api)
	return U.lazyload(function() return api.get_image() or U.dummy_image end)
end

---Entry proxy that fills exif meta on first missing-key access.
---@param img swayimg.entry
---@return swayimg.image
function U.lazymeta(img)
	return setmetatable(img, {
		__index = function(self, idx)
			exiv2.add_meta(self)
			return rawget(self, idx)
		end,
	})
end

---@generic O
---@param x `O`?
---@param def O
---@return O
function U.get_or_default(x, def)
	if x == nil then return def end
	return x
end

---@generic O
---@param x `O`|`O`[]
---@return O[]
function U.tabled(x) return type(x) == 'table' and x or { x } end
---@param t table
---@return table
function U.rev_idx(t)
	local r = {}
	for k, v in pairs(t) do
		r[v] = k
	end
	return r
end

---@generic O
---@param t `O`
---@return O
function U.soft_copy(t)
	local ret = {}
	for k, v in pairs(t) do
		ret[k] = v
	end
	return ret
end

---Fill missing keys from a module table.
---@generic O:table, M:table
---@param self `O`
---@param module `M`
---@return O|M
function U.new_object(self, module)
	for k, v in pairs(module) do
		if self[k] == nil then self[k] = type(v) == 'table' and U.soft_copy(v) or v end
	end
	return self
end

---@param defaults table (optionally) nested tables with the default values (or empty)
---@param on_set fun(_, tbl:table)
---@return table
---@return fun(_, tbl:table):false handler for setting the entire field where this table resides
function U.deep_backer(defaults, on_set)
	local meta = {} ---@type metatable
	local function rawupdate(self, new)
		for idx, v in pairs(new) do
			local key = '_' .. idx
			if type(v) == 'table' then
				if rawget(self, key) == nil then
					rawset(self, key, setmetatable({ __super = self, __name = idx }, meta))
				end
				rawupdate(self[key], v)
			else
				rawset(self, key, v)
			end
		end
	end
	function meta:__index(idx)
		local key = '_' .. idx
		local ret = rawget(self, key)
		if ret == nil then
			ret = setmetatable({ __super = self, __name = idx }, meta)
			rawset(self, key, ret)
		end
		return ret
	end
	function meta:__newindex(idx, val)
		local update = { [idx] = val }
		rawupdate(self, update)
		self(update)
	end
	---@diagnostic disable-next-line: undefined-field
	function meta:__call(val) self.__super { [self.__name] = val } end
	---@diagnostic disable-next-line: redundant-parameter
	function meta:__tostring(indent, visited)
		visited = visited or { [self] = 'root' }
		local copy = {}
		visited[copy] = visited[self]
		for k, v in pairs(self) do
			if k:sub(1, 1) == '_' and k:sub(2, 2) ~= '_' then copy[k:sub(2)] = v end
		end
		return U.tbl_to_str(copy, indent, visited)
	end

	local self = setmetatable({}, { __index = meta.__index, __newindex = meta.__newindex, __call = on_set })
	rawupdate(self, defaults)
	return self, function(_, tbl)
		rawupdate(self, tbl)
		on_set(nil, tbl)
		return false
	end
end

U.max_tbl_len = 80

---One line when short.
---@param t table
---@param indent string?
---@param visited? table seen tables for cycle display
---@return string
function U.tbl_to_str(t, indent, visited)
	local m = getmetatable(t)
	indent = (indent or '') .. '  '
	visited = visited or { [t] = 'root' }
	if m and m.__tostring then return m.__tostring(t, indent, visited) end
	local s = {}
	local space = U.max_tbl_len
	for k, v in pairs(t) do
		if type(v) == 'table' then
			if visited[v] then
				v = ('<%s>'):format(visited[v])
			else
				visited[v] = ('%s.%s'):format(visited[t], k)
				v = U.tbl_to_str(v, indent, visited)
			end
		elseif type(v) == 'function' then
			v = 'fn()'
		elseif type(v) == 'string' then
			v = ('"%s"'):format(v)
		end

		if type(k) == 'table' then k = '[]' end

		s[#s + 1] = (type(k) == 'string' and '%s=%s' or '[%s]=%s'):format(tostring(k), tostring(v))
		space = space - #s[#s]
	end
	table.sort(s, function(a, b) -- if number-indexed (`[xxx]`), then go first
		if a:byte() == 91 then
			if b:byte() ~= 91 then return true end
		elseif b:byte() == 91 then
			return false
		end
		return a < b
	end)
	if space <= 0 then
		return ('{\n%s%s\n%s}'):format(indent, table.concat(s, ',\n' .. indent), indent:sub(1, -2))
	else
		return #s == 0 and '{}' or ('{ %s }'):format(table.concat(s, ', '))
	end
end

---Original tostring method
U.ts = tostring

function U.to_pretty_str(x)
	if type(x) == 'table' then return U.tbl_to_str(x, '') end
	if type(x) == 'number' then
		if x > 0x00ffffff then return ('0x%x'):format(x) end
		if math.floor(x * 100) == x * 100 then return '' .. x end
		return ('%.5f'):format(x)
	end
	return U.ts(x)
end

_G.tostring = U.to_pretty_str

---@param action_match string luapat to match the last internal trace to trim
---@param stacktrace string use debug.traceback() to get the trace
---@return string trimmed trace
function U.pretty_trace(action_match, stacktrace)
	return (
		stacktrace
			:gsub(': in main chunk.*$', '') -- trim all calls past the main trace
			:gsub('^.-' .. action_match .. "'\n", '') -- trim internals up to traced fn
			:gsub('[^\n]+proxy[^\n]+\n', '') -- trim all proxy calls
			:gsub('[^\n<"]+/swayimg/', '') -- trim path to config dir
			:gsub('[ \t]*%./', '') -- trim path to config dir
			:gsub("in function '*([^%s']+)'?", '%1()') -- format as a fn call
			-- :gsub('\n%s+%[C%][^\n]+', '') -- trim [C] calls
			:gsub('\n(%S)', '\n\t%1')
	) -- indent continuing lines
end

---Group keybinds by action, best-described first.
---@param bindmap sai.lib.keybind_processor.bindmap
---@return {bind:string[],info:string}[] grouped binds, best-described first
function U.ordered_binds(bindmap)
	local binds = {}
	for k, v in pairs(bindmap) do
		if v.desc or not v.kind or v.kind == 'default' then
			if not binds[v] then
				binds[v] = {
					bind = {},
					-- first trace line only: the call site
					info = v.desc or (type(v.cb) == 'string' and v.cb) or v.trace:match '^[^\n]+',
					-- quality of the source information
					qual = v.kind == 'default' and 0 or (v.desc and 1) or (type(v.cb) == 'string' and 2) or 3,
				}
			end
			table.insert(binds[v].bind, k)
		end
	end

	local out = {}
	for _, v in pairs(binds) do
		table.sort(v.bind, function(a, b) return #a < #b or (#a == #b and a < b) end)
		out[#out + 1] = v
	end
	table.sort(out, function(a, b)
		if a.qual ~= b.qual then return a.qual < b.qual end
		if a.qual < 3 then return a.info < b.info end
		return #a.info < #b.info or (#a.info == #b.info and a.info < b.info)
	end)

	return out
end

---@param bindmap sai.lib.keybind_processor.bindmap
---@param fmt_str string? how to separate keybind list from the action
---@param key_fmt? fun(key:string):string convert each raw xkb bind to its display form
---@return string[]
function U.str_bindlist(bindmap, fmt_str, key_fmt)
	fmt_str = fmt_str or '%20s: %s'
	local out = {}
	for _, k in ipairs(U.ordered_binds(bindmap)) do
		local keys = k.bind --- freshly built by ordered_binds, safe to map in place
		if key_fmt then
			for i, key in ipairs(keys) do
				keys[i] = key_fmt(key)
			end
		end
		out[#out + 1] = (fmt_str):format(table.concat(keys, ', '), k.info:gsub('[\t\n]', ' '))
	end
	return out
end

---Human-readable mode or bind/var layer name from its module path.
---`root` strips its prefix first, so a name shown under its parent's tab carries no redundant clutter.
---@param path string?
---@param root? string the parent the path sits under
---@return string
function U.pretty_name(path, root)
	local name = (path or 'unknown'):gsub('^sai%.mode%.', ''):gsub('^sai%.', '')
	if root then
		root = root:gsub('^sai%.mode%.', ''):gsub('^sai%.', '')
		local prefix = root .. '.'
		if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1) end
	end
	name = name:gsub('_', ' '):gsub('%.', ' ')
	return (name:gsub('%a+', function(w) return w:sub(1, 1):upper() .. w:sub(2) end))
end

---@param wrapper sai.lib.backer API object to inspect
---@return {name:string,value:unknown}[] fields List of settable fields with their current values
function U.get_dynvars(wrapper)
	local backed
	for k, v in pairs(rawget(wrapper, 'super') or {}) do
		if type(k) == 'userdata' then -- the raw cpp api has fieldmethods hidden in an object
			backed = v
			break
		end
	end
	if not backed then backed = {} end
	local fields = {}

	for backing_field, value in pairs(wrapper) do
		if backing_field:sub(1, 1) == '_' then
			local field = backing_field:sub(2)

			-- needs official setter, enabler, or override
			if rawget(wrapper, 'set' .. backing_field) or backed[field] then
				fields[#fields + 1] = { name = field, value = value }
			end
		end
	end
	table.sort(fields, function(a, b) return tostring(a.name) < tostring(b.name) end)

	return fields
end

---The text block positions: per-mode in the app, see types.lua `block_position_t`
U.block_positions = { 'topleft', 'topright', 'bottomleft', 'bottomright' }

---Pad every line to the longest so centered text renders as a block.
---@param str string
---@return string
function U.align_block(str)
	if not str:find('\n', 1, true) then return str end
	local width = 0
	for line in str:gmatch '[^\n]+' do
		width = math.max(width, #line)
	end
	local out = str:gsub('[^\n]+', function(line) return line .. (' '):rep(width - #line) end)
	return out
end

---@param img_meta table<string,string> `.meta` field of the image
---@param tag string exif name/path; single word tries Exif.Photo, then Exif.Image
---@return string?
function U.format_exif(img_meta, tag)
	if not img_meta then return end

	if tag and tag:find('.', 0, true) then
		tag = img_meta[tag]
	else
		tag = img_meta['Exif.Photo.' .. tag] or img_meta['Exif.Image.' .. tag]
	end
	if not tag then return end

	local a, b = tag:match '^(%-?[0-9 ]+)/([0-9][0-9 ]*)$'
	if a then
		a, b = a:gsub(' ', ''):gsub('^0+(.)', '%1'), b:gsub(' ', ''):gsub('^0+(.)', '%1')
		local x, y = tonumber(a), tonumber(b)
		local n = x / y
		if math.floor(n) == n then -- integer, not rational number -> done
			return '' .. n
		elseif n < 1 and (a:match '^10*$' or b:match '^10*$') then -- decimal point offset through the other side
			return ('1/%d'):format(y / x)
		else
			return '' .. n
		end
	end

	return tag
end

-- TODO: support date comparisons
---@param val? string raw exif value
---@return string|number|nil number for rationals and numerics, else the raw value
function U.parse_exif_val(val)
	if not val then return end
	local a, b = val:match '^(%-?[0-9 ]+)/([0-9][0-9 ]*)$'
	if a then
		a = a:gsub(' ', ''):gsub('^0+(.)', '%1')
		b = b:gsub(' ', ''):gsub('^0+(.)', '%1')
		local x, y = tonumber(a), tonumber(b)
		return x / y
	else
		return tonumber(val) or val
	end
end

---No-op timer unless `DEBUG_PERF=1`.
---@return fun(timestamp_msg:string)
function U.timer()
	if not U.debug_perf then
		return function() end
	end

	local time = os.clock()
	return function(tmsg)
		print(tmsg .. '; cpu in ms:\t' .. math.floor((os.clock() - time) * 1000))
		time = os.clock()
	end
end

---Debounced twin of `sai.defer_fn`: only the latest scheduled fn fires.
---@return fun(fn:fun(), delay:integer)
function U.debounce()
	local gen = 0
	return function(fn, delay)
		gen = gen + 1
		local mine = gen
		sai.defer_fn(function()
			if mine ~= gen then return end -- a newer call took over
			fn()
		end, delay)
	end
end

---@param path string
---@return boolean
function U.is_dir(path)
	-- a trailing `/.` opens only on directories (ENOTDIR otherwise)
	local probe = io.open(path .. '/.', 'r')
	if probe then
		probe:close()
		return true
	end
	local f = io.open(path, 'r')
	if not f then error('no such path: ' .. path) end
	f:close()
	return false
end

return U
