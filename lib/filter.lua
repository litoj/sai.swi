---@module 'sai.lib.filter'

local S = require 'sai.bridge.shell'

---@alias filter.condition<T> {[1]:string, [2]:fun(val:unknown, item:T):boolean}

---Condition parsing and rating engine.
---@class sai.lib.filter<T>
---@field get? fun(item:T, var:string):unknown
---@field coerce? fun(val:string):string|number (default: none)
---@field default_var? string the variable matched by operator-less lines
---@field default_filter? number|false fuzzy gap tolerance, also for `~` (0 = plain substring, 1 = full fuzzy; `~` falls back to 1)
local M = {}

---Detect if a string can be matched by leaving out up to `max_misses` chars.
---@param str string tested string
---@param match string what should it contain
---@param max_misses integer? max characters to be skipped (0 = like :find())
---@return integer? start match start
---@return integer? end match end
function M.fuzzy_find(str, match, max_misses)
	-- case follows the input: an all-lowercase query folds, mixed-case keeps capitals as anchors
	if not match:find '%u' then
		str, match = str:lower(), match:lower()
	end
	local s, e = str:find(match, 1, true)
	if s or max_misses == 0 then return s, e end

	s = str:find(match:sub(1, 1), 1, true)
	if not s then return end
	-- the greedy anchor never retries a later first-char occurrence ("Ex" of "Exif" can strand "ExTi" past tolerance)
	-- moot while candidates are leaf names
	local si, mi = s + 1, 2
	max_misses = max_misses and (s + #match + max_misses) or 1024

	while mi <= #match and si <= max_misses do
		e = str:find(match:sub(mi, mi), si, true)
		if not e then return end
		si, mi = e + 1, mi + 1
	end

	if si <= max_misses then return s, si end
end

---Lower is better, nil is no match.
---@param base string what the user typed
---@param candidate string
---@param rate_start? boolean penalize the distance to the first matched char (default true)
---@param max_penalty? integer abort matching beyond this gap tolerance
---@return integer?
function M.rate(base, candidate, rate_start, max_penalty)
	local s, e = M.fuzzy_find(candidate, base, max_penalty)
	if not s or (rate_start ~= false and s > 1) then return end
	return e - s + #candidate / 128 -- len/128: to make shorter matches be first
end

---@generic T
---@param cfg? sai.lib.filter<T>
---@return sai.lib.filter<T>
function M.new(cfg) return setmetatable(cfg or {}, { __index = M }) end

---Line operators:
---  - `<` `>` `<=` `>=` compare coerced values, `!` negates presence,
---    `:` runs code, `~` fuzzy-matches
---  - `==` / `!=` match a luapat wrapped in `^...$`, with `-` escaped
---    (a bare `-` would quantify)
local operators = { '!=', '<=', '>=', '<', '>', '==', '=', '!', ':', '~' }

---@param line string
---@return filter.condition?
---@return string? err
function M:parse(line)
	line = line:match '^%s*(.-)%s*$'
	if line == '' then return end

	local tag, val, oper
	for _, op in ipairs(operators) do
		tag, val = line:match('^%s*([0-9A-Za-z.]*)%s*' .. op .. '%s*(.-)%s*$')
		if tag then
			oper = op == '=' and '==' or op
			break
		end
	end

	if not oper then
		local df = self.default_filter
		local base = line
		return {
			self.default_var,
			df == 0 and function(p) return p ~= nil and tostring(p):find(base, 1, true) end
				or function(p) return p ~= nil and M.rate(base, tostring(p), false, df) end,
		}
	elseif #tag == 0 and oper ~= ':' then
		return nil, 'Tag can be omitted only with the ":" (code) operator'
	elseif #val == 0 and oper ~= '!' then
		return nil, 'Value can be omitted only with the "!" (negation) operator'
	end

	local num_val = self.coerce and self.coerce(val) or val

	---@type {[string]:(fun(val:unknown):boolean)|fun():((fun(val:string):boolean)?, string?)}
	local cmp = {
		['<'] = function(r) return r ~= nil and r < num_val end,
		['>'] = function(r) return r ~= nil and r > num_val end,
		['<='] = function(r) return r ~= nil and r <= num_val end,
		['>='] = function(r) return r ~= nil and r >= num_val end,
		['!='] = function()
			local pat = '^' .. val:gsub('%-', '%%-') .. '$'
			return function(r) return r == nil or not tostring(r):find(pat) end
		end,
		['!'] = function(r) return not r end,
		['=='] = function()
			local pat = '^' .. val:gsub('%-', '%%-') .. '$'
			return function(r) return r ~= nil and tostring(r):find(pat) end
		end,
		['~'] = function()
			local tol = self.default_filter
			if type(tol) ~= 'number' or tol == 0 then tol = 1 end
			return function(r) return r ~= nil and M.rate(val, tostring(r), false, tol) end
		end,
		[':'] = function() -- run code with the item value as self
			if #tag == 0 then tag = 'self' end
			local cb, err = S.make_runnable(val, { 'self' })
			if not cb then return nil, err end
			return function(v) return not not cb(v) end
		end,
	}

	oper = cmp[oper]
	local err
	if debug.getinfo(oper, 'u').nparams ~= 1 then
		oper, err = oper()
	end
	if oper then return { tag, oper } end
	return nil, err
end

---@generic T
---@param self sai.lib.filter<T>
---@param cond filter.condition<T>
---@param item T
---@return boolean
function M:apply(cond, item) return not not cond[2](self.get(item, cond[1]), item) end

return M
