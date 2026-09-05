---@module 'sai.lib.utils'
---@class sai.lib.utils
local U = { debug_perf = os.getenv 'DEBUG_PERF' == '1' }

---@type swayimg.image
---@diagnostic disable-next-line: missing-fields
U.dummy_image = {
	path = 'dummy image',
	index = -1,
	meta = {},
	format = '',
}

function U.lazyload(fn)
	return setmetatable({}, {
		__index = function(self, idx)
			-- load just once and replace with the actual data
			fn = fn()
			setmetatable(self, { __index = fn })

			return fn[idx]
		end,
	})
end

---@param api swayimg.viewer|swayimg.gallery
---@return swayimg.image
function U.lazyimg(api)
	return U.lazyload(function() return api.get_image() or U.dummy_image end)
end

---@generic O
---@param x `O`|`O`[]
---@return O[]
function U.tabled(x) return type(x) == 'table' and x or { x } end
---@param t table
---@return table # reverse-indexed table of t
function U.rev_idx(t)
	local r = {}
	for k, v in pairs(t) do
		r[v] = k
	end
	return r
end

---@generic O
---@param t `O`
---@return O t copy
function U.soft_copy(t)
	local ret = {}
	for k, v in pairs(t) do
		ret[k] = v
	end
	return ret
end

---@generic O:table, M:table
---@param self `O`
---@param module `M`
---@return O|M self with module methods and default values
function U.new_object(self, module)
	for k, v in pairs(module) do
		if self[k] == nil then self[k] = type(v) == 'table' and U.soft_copy(v) or v end
	end
	return self
end

---@param defaults table (optionally) nested tables with the default values (or empty)
---@param on_set fun(_, tbl:table) on-change callback with the table with all performed changes
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

---@param t table
---@param indent string?
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
			if not b:byte() == 91 then return true end
		elseif b:byte() == 91 then
			return false
		end
		return a < b
	end)
	if space <= 0 then
		return ('{\n%s%s}'):format(indent, table.concat(s, ',\n' .. indent))
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
function U.pretty_trace(action_match, stacktrace)
	return stacktrace
		:gsub(': in main chunk.*$', '') -- trim all calls past the main trace
		:gsub('^.-' .. action_match .. "'\n", '') -- trim interals up to traced fn
		:gsub('[^\n]+proxy[^\n]+\n', '') -- trim all proxy calls
		:gsub('[^\n<"]+/swayimg/', '') -- trim path to config dir
		:gsub('[ \t]*%./', '') -- trim path to config dir
		:gsub("in function '*([^%s']+)'?", '%1()') -- format as a fn call
		-- :gsub('\n%s+%[C%][^\n]+', '') -- trim [C] calls
		:gsub('\n(%S)', '\n\t%1') -- indent continuing lines
end

function U.print_trace() print(U.pretty_trace('print_trace', debug.traceback())) end

---@return {bind:string[],info:string}[] sorted list of keybinds with description of their function
function U.ordered_binds(api)
	local binds = {}
	for k, v in pairs(api.get_mappings()) do ---@cast v bindcfg
		if v.desc or not v.kind or v.kind == 'default' then
			if not binds[v] then
				binds[v] = {
					bind = {},
					-- first trace line only: the call site is the informative part,
					-- the rest is the internal chain that just eats pager space
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

---@param api sai.lib.keybind_processor
---@param fmt_str string? how to separate keybind list from the action
---@param key_fmt? fun(key:string):string convert each raw xkb bind to its display form
function U.str_bindlist(api, fmt_str, key_fmt)
	fmt_str = fmt_str or '%20s: %s'
	local out = {}
	for _, k in ipairs(U.ordered_binds(api)) do
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
---@param path string?
---@return string
function U.pretty_name(path)
	local name = (path or 'unknown'):gsub('^sai%.mode%.', ''):gsub('^sai%.', ''):gsub('_', ' ')
	return (name:gsub('%a+', function(w) return w:sub(1, 1):upper() .. w:sub(2) end))
end

---Split the currently effective binds of a mode api into per-layer bind sets:
---each active custom mode gets the binds it overrides, the main mode gets the rest.
---Topmost layer first, main mode last.
---@param mode sai.api.mode_base
---@return {_path:string, _mappings:sai.lib.keybind_processor.bindmap}[]
function U.get_active_bindsets(mode)
	local bindsets = {}
	local all = {}
	for k, v in pairs(mode.get_mappings()) do
		all[k] = v
	end
	for i = #mode._active_modes, 1, -1 do
		local binder = mode._active_modes[i]
		local mappings = {}
		for k, v in pairs(binder._mappings) do
			local used = all[k]
			-- recognize only if it is this mapping and if this is a mapping, not un-mapping
			if used and used.cb == v.cb then
				all[k] = nil
				if used.cb then mappings[k] = v end
			end
		end
		bindsets[#bindsets + 1] = { _path = binder._path, _mappings = mappings }
	end
	---@diagnostic disable-next-line: invisible
	bindsets[#bindsets + 1] = { _path = mode._path, _mappings = all } -- the rest is the main mode
	return bindsets
end

---@param wrapper sai.lib.backer API object to inspect
---@param filter? fun(name:string,value:any):boolean|{[string]:0|false} map of banned values or a filter fn
---@return {name:string,value:any}[] fields List of settable fields with their current values
function U.get_dynvars(wrapper, filter)
	if type(filter) ~= 'function' then
		local tbl = filter or {}
		filter = function(k) return tbl[k] == nil end
	end
	local backed
	---@diagnostic disable-next-line: invisible
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

			-- Check if backing field has an official setter, enabler, or override
			if (rawget(wrapper, 'set' .. backing_field) or backed[field]) and filter(backing_field, value) then
				fields[#fields + 1] = { name = field, value = value }
			end
		end
	end
	table.sort(fields, function(a, b) return tostring(a.name) < tostring(b.name) end)

	return fields
end

---The text block positions: per-mode in the app, see types.lua `block_position_t`
U.block_positions = { 'topleft', 'topright', 'bottomleft', 'bottomright' }

---@param mode_api sai.api.mode_base
---@return sai.lib.remapper[]
function U.get_active_modes(mode_api)
	local modes = {}
	for i = #mode_api._active_modes, 1, -1 do
		modes[#modes + 1] = mode_api._active_modes[i]
	end
	return modes
end

---Nicely format the requested value to human readable rational numbers.
---@param img_meta table<string,string> the `.meta` field of the image
---@param tag string name/path of the exif value to get
--- single-word tags resolve to `Exif.Photo.<>`  or `Exif.Image.<>`
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
---@return string|number|nil
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

---Detect if a string can be matched by leaving out up to `max_misses` chars.
---@param str string tested string
---@param match string what should it contain
---@param max_misses integer? max characters to be skipped (0 = like :find())
---@return integer? start
---@return integer? end
function U.fuzzy_find(str, match, max_misses)
	local s, e = str:find(match, 1, true)
	if s or max_misses == 0 then return s, e end

	s = str:find(match:sub(1, 1), 1, true)
	if not s then return end
	local si, mi = s + 1, 2
	max_misses = max_misses and (s + #match + max_misses) or 1024

	while mi <= #match and si <= max_misses do
		e = str:find(match:sub(mi, mi), si, true)
		if not e then return end
		si, mi = e + 1, mi + 1
	end

	if si <= max_misses then return s, si end
end

return U
