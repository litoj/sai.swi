---@module 'sai.lib.bindmods'

local X = require 'sai.bridge.xkb'
local section = require 'sai.api.section'

---Custom bind modifiers: tokens parsed off the front of a bind string, resolved against the live state at dispatch time.
---One registry record per modifier; `count` ships here, `section` lives in its own module.
---@class sai.lib.bindmods.mod
---@field name string the registry key, filled by register
---@field order integer parse and render order, lower first
---@field parse fun(spec:string):string?,string the leading token and the rest of the spec, nil when no match
---@field render fun(token:string):string the canonical token text
---@field tokens? string[] the accepted tokens, in resolution priority order
---@field resolve? fun(cands:string[]):string? the live token; further return values pass to the action as payload, nil when none qualifies
---@field expand? fun(mod:sai.lib.bindmods.mod, items:string[], reg:{[string]:boolean}):string[] the items with the family's registered variations prepended; the default prepends every registered token in priority order
---@field burst? boolean the repeat-count dimension: dispatch holds the burst open while a higher count is registered

---@class sai.lib.bindmods
---@field mods {[string]: sai.lib.bindmods.mod}
---@field burst_mod? string the registered burst modifier's name
local M = { mods = {} }

local ordered = {} ---@type sai.lib.bindmods.mod[]

local function resort()
	ordered = {}
	for _, def in pairs(M.mods) do
		ordered[#ordered + 1] = def
	end
	table.sort(ordered, function(a, b) return a.order < b.order end)
end

---Register a modifier under `name`.
---One burst modifier at most: split keeps a single count per spec.
---@param name string the registry key
---@param def sai.lib.bindmods.mod the modifier definition; shared, not copied
function M.register(name, def)
	if def.burst and M.burst_mod then error('bindmods: the burst slot is taken by ' .. M.burst_mod, 2) end
	def.name = name
	if def.burst then M.burst_mod = name end
	M.mods[name] = def
	resort()
end

---@param name string the registry key
function M.unregister(name)
	if M.burst_mod == name then M.burst_mod = nil end
	M.mods[name] = nil
	resort()
end

---@return sai.lib.bindmods.mod[] the registered modifiers in parse and render order
function M.ordered() return ordered end

---A varargs pack that survives nils: the table may stay sparse, the
---count stays exact.
---@param ... any
---@return any[] vals
---@return integer n
local function packn(...) return { ... }, select('#', ...) end

---Parse the modifier tokens off the front of a bind string.
---@param spec string the declared bind key
---@return {[string]:string} tokens one entry per qualifier, keyed by modifier name
---@return string event the event part, in xkb form
---@return integer? count the burst count token, when present
function M.split(spec)
	spec = spec:match '^<(.+)>' or spec
	local tokens, count = {}, nil
	while true do
		local matched = false
		for _, m in ipairs(ordered) do
			local token, rest = m.parse(spec)
			if token then
				if m.burst then
					count = tonumber(token)
				else
					tokens[m.name] = token
				end
				spec = rest
				matched = true
				break
			end
		end
		if not matched then break end
	end
	return tokens, X.userbind_to_xkb(spec), count
end

---The canonical form of a bind string. Idempotent.
---@param spec string the declared bind key
---@return string the tokens in registry order, then the normalized event
function M.canonical(spec)
	local tokens, event, count = M.split(spec)
	local out = {}
	for _, m in ipairs(ordered) do
		local token = tokens[m.name]
		if m.burst then token = count and tostring(count) end
		if token then out[#out + 1] = m.render(token) .. '+' end
	end
	out[#out + 1] = event
	return table.concat(out)
end

---The qualifier path of a token set.
---@param tokens {[string]:string} the qualifier tokens, keyed by modifier name
---@return string the non-burst tokens, rendered in registry order and joined; `''` for an unqualified bind
function M.path(tokens)
	local out = {}
	for _, m in ipairs(ordered) do
		if not m.burst and tokens[m.name] then out[#out + 1] = m.render(tokens[m.name]) end
	end
	return table.concat(out, '+')
end

---The default family expansion.
---@param mod sai.lib.bindmods.mod the expanding modifier
---@param items string[] the candidate paths so far
---@param reg {[string]:boolean} the family's registered tokens for the event
---@return string[] every registered token prepends its variations, in priority order, the input items stay last
function M.default_expand(mod, items, reg)
	local tokens = {}
	for _, token in ipairs(mod.tokens or {}) do
		if reg[token] then tokens[#tokens + 1] = token end
	end
	if not tokens[1] then return items end
	local out = {}
	for _, token in ipairs(tokens) do
		for _, item in ipairs(items) do
			out[#out + 1] = item == '' and token or (token .. '+' .. item)
		end
	end
	for _, item in ipairs(items) do
		out[#out + 1] = item
	end
	return out
end

---The candidate qualifier paths for an event.
---@param fams {[string]:sai.api.mode_base.bind_family} the event's families, keyed by qualifier path
---@return string[] `''` expanded by every special-mod family, most specific first
function M.candidates(fams)
	local items = { '' }
	for _, m in ipairs(ordered) do
		if not m.burst and m.tokens then
			local reg = {}
			for _, fam in pairs(fams) do
				local token = fam.tokens[m.name]
				if token then reg[token] = true end
			end
			items = (m.expand or M.default_expand)(m, items, reg)
		end
	end
	return items
end

---Liveness of one candidate path.
---@param path string the candidate qualifier path
---@param fams {[string]:sai.api.mode_base.bind_family} the event's families
---@return any[]? args the payload riding the live path, nil when a token misses
---@return integer nargs the argument count
function M.validate(path, fams)
	local fam = fams[path]
	if not fam then return nil, 0 end
	local args, nargs = {}, 0
	for _, m in ipairs(ordered) do
		if not m.burst and m.resolve then
			local token = fam.tokens[m.name]
			if token then
				local vals, n = packn(m.resolve { token })
				if not vals[1] then return nil, 0 end
				for i = 2, n do
					nargs = nargs + 1
					args[nargs] = vals[i]
				end
			end
		end
	end
	return args, nargs
end

---First live candidate path, without firing.
---@param fams {[string]:sai.api.mode_base.bind_family} the event's families
---@return string? the live path, nil when none validates
function M.live(fams)
	for _, path in ipairs(M.candidates(fams)) do
		if M.validate(path, fams) then return path end
	end
	return nil
end

-- the nth press of a burst, counted within the mode's multiclick_delay
---@diagnostic disable-next-line: missing-fields -- register fills the name
M.register('count', {
	order = 10,
	burst = true,
	parse = function(spec)
		local n, rest = spec:match '^(%d+)([%+%-].+)$'
		if not n or tonumber(n) < 1 then return nil, spec end
		return n, rest:sub(2)
	end,
	render = function(token) return token end,
})

-- the location qualifier lives in its own module: tokens, match and key helper
---@diagnostic disable-next-line: missing-fields -- register fills the name
M.register('section', section.mod)

return M
