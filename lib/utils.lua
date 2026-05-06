---@module 'swi.lib.utils'
local U = {}

---@generic O
---@param loader fun():`O`
---@return O
function U.lazy(loader)
	return setmetatable({}, {
		__index = function(self, idx)
			for k, v in pairs(loader()) do
				self[k] = v
			end
			return rawget(self, idx)
		end,
	})
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

---A list of translations of vim-like+key-emmited symbols back to their names
U.key_map = {
	BS = 'BackSpace',
	Del = 'Delete',
	Esc = 'Escape',
	CR = 'Return',
	Enter = 'Return',
	PgUp = 'Prior',
	PgDown = 'Next',
	PageUp = 'Prior',
	PageDown = 'Next',
	['`'] = 'grave',
	['~'] = 'asciitilde',
	[' '] = 'Space',
	['-'] = 'minus',
	['_'] = 'underscore',
	['='] = 'equal',
	['+'] = 'plus',
	[','] = 'comma',
	['.'] = 'period',
	['['] = 'bracketleft',
	[']'] = 'bracketright',
	[':'] = 'Shift+colon',
}
for _, v in ipairs { 'Middle', 'Left', 'Right' } do
	U.key_map[v:sub(1, 1) .. 'MB'] = 'Mouse' .. v
	U.key_map[v .. 'Mouse'] = 'Mouse' .. v
end
for _, v in ipairs { 'Left', 'Right', 'Up', 'Down' } do
	U.key_map['SM' .. v:sub(1, 1)] = 'Scroll' .. v
	U.key_map[v:sub(1, 1) .. 'MS'] = 'Scroll' .. v
end

---Parse vim-like shortcuts into classic gui-style.
---@param bind string
---@return string
function U.transform_key(bind)
	if bind:match '^<.+>$' then bind = bind:sub(2, -2) end
	bind = bind:gsub('[AM][+-]', 'Alt+', 1):gsub('S[+-]', 'Shift+', 1):gsub('C[+-]', 'Ctrl+', 1)

	if bind:match 'Shift%+Tab$' then
		bind = bind:gsub('Shift%+Tab$', 'Shift+ISO_Left_Tab')
	else
		local key = bind:match '[^+-]*.$'
		bind = bind:sub(1, -#key - 1) .. (U.key_map[key] or key)
	end
	return bind
end

U.rev_key_map = U.rev_idx(U.key_map)

function U.short_key_name(bind)
	bind = bind:gsub('Alt[+-]', 'A-'):gsub('Shift[+-]', 'S-'):gsub('Ctrl[+-]', 'C-')
	if bind:match 'ISO_Left_Tab$' then
		bind = bind:gsub('S-(.*)ISO_Left_Tab', '%1')
	else
		local key = bind:match '[^+-]*.$'
		local found = U.rev_key_map[key]
		bind = bind:sub(1, -#key - 1) .. (found or key)
		if found then return ('<%s>'):format(bind) end
	end
	if bind:match '-.' then bind = ('<%s>'):format(bind) end
	return bind
end

U.max_tbl_len = 80

---@param t table
---@param indent string?
function U.tbl_to_str(t, indent)
	indent = (indent or '') .. '  '
	local s = {}
	local space = U.max_tbl_len
	for k, v in pairs(t) do
		if type(v) == 'table' then
			v = U.tbl_to_str(v, indent)
		elseif type(v) == 'function' then
			v = 'fn()'
		elseif type(v) == 'string' then
			v = ('"%s"'):format(v)
		end

		if type(k) == 'table' then k = '[]' end

		s[#s + 1] = type(k) == 'string' and ('%s=%s'):format(k, tostring(v)) or tostring(v)
		space = space - #s[#s]
	end
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

function U.ordered_binds(api)
	local binds = {}
	for k, v in pairs(api.get_mappings()) do ---@cast v bindcfg
		if not binds[v.cb] then
			binds[v.cb] = {
				bind = {},
				info = v.desc or (type(v.cb) == 'string' and v.cb) or v.trace,
				-- quality of the source information
				qual = v.default and 0 or (v.desc and 1) or (type(v.cb) == 'string' and 2) or 3,
			}
		end
		table.insert(binds[v.cb].bind, k)
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

---@param api swi.lib.keybind_processor
---@param fmt_str string how to separate keybind list from the action
function U.str_bindlist(api, fmt_str)
	local out = {}
	for _, k in ipairs(U.ordered_binds(api)) do
		out[#out + 1] = (fmt_str):format(table.concat(k.bind, ', '), k.info:gsub('[\t\n]', ' '))
	end
	return out
end

return U
