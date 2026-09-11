---@module 'sai.lib.bindmods'

local X = require 'sai.bridge.xkb'
local mouse_box = require 'sai.bridge.mouse_box'

---Custom bind modifiers: tokens parsed off the front of a bind string, resolved against the live state at dispatch time.
---One registry record per modifier; `count` and `section` are the built-ins, any event type carries them.
---@class sai.lib.bindmods.mod
---@field name string the registry key, filled by register
---@field order integer parse and render order, lower first
---@field parse fun(spec:string):string?,string the leading token and the rest of the spec, nil when no match
---@field render fun(tok:string):string the canonical token text
---@field tokens? string[] the accepted tokens, in resolution priority order
---@field resolve? fun(cands:string[]):string? the live token; further return values pass to the action as payload, nil when none qualifies
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

---Register a modifier under `name`; the definition is shared, not copied.
---One burst modifier at most: split keeps a single count per spec.
---@param name string
---@param def sai.lib.bindmods.mod
function M.register(name, def)
	if def.burst and M.burst_mod then error('bindmods: the burst slot is taken by ' .. M.burst_mod, 2) end
	def.name = name
	if def.burst then M.burst_mod = name end
	M.mods[name] = def
	resort()
end

---@param name string
function M.unregister(name)
	if M.burst_mod == name then M.burst_mod = nil end
	M.mods[name] = nil
	resort()
end

---@return sai.lib.bindmods.mod[]
function M.ordered() return ordered end

---A varargs pack that survives nils: the table may stay sparse, the
---count stays exact.
---@param ... any
---@return any[] vals
---@return integer n
local function packn(...) return { ... }, select('#', ...) end

---Parse the modifier tokens off the front of a bind string.
---@param spec string
---@return {[string]:string} toks one entry per qualifier, keyed by modifier name
---@return string ev the event part, in xkb form
---@return integer? count the burst count token, when present
function M.split(spec)
	spec = spec:match '^<(.+)>' or spec
	local toks, count = {}, nil
	while true do
		local matched = false
		for _, m in ipairs(ordered) do
			local tok, rest = m.parse(spec)
			if tok then
				if m.burst then
					count = tonumber(tok)
				else
					toks[m.name] = tok
				end
				spec = rest
				matched = true
				break
			end
		end
		if not matched then break end
	end
	return toks, X.userbind_to_xkb(spec), count
end

---The canonical form of a bind string: the tokens in registry order,
---then the normalized event. Idempotent.
---@param spec string
---@return string
function M.canonical(spec)
	local toks, ev, count = M.split(spec)
	local out = {}
	for _, m in ipairs(ordered) do
		local tok = toks[m.name]
		if m.burst then tok = count and tostring(count) end
		if tok then out[#out + 1] = m.render(tok) .. '+' end
	end
	out[#out + 1] = ev
	return table.concat(out)
end

---The qualifier path of a token set: the non-burst tokens, rendered in
---registry order and joined; `''` for an unqualified bind.
---@param toks {[string]:string}
---@return string
function M.path(toks)
	local out = {}
	for _, m in ipairs(ordered) do
		if not m.burst and toks[m.name] then out[#out + 1] = m.render(toks[m.name]) end
	end
	return table.concat(out, '+')
end

---Resolve the live qualifier path over the families present for an event.
---Each qualifier picks at most one active token and contributes its payload; a nil payload does not end the argument list.
---@param fams {[string]:{toks:{[string]:string}}} the event's families, path -> record
---@return string path
---@return any[] args the callback payload of the qualified tokens
---@return integer nargs the payload length
function M.resolve(fams)
	local toks = {}
	local args, nargs = {}, 0
	for _, m in ipairs(ordered) do
		if m.resolve and m.tokens then
			local present = {}
			for _, fam in pairs(fams) do
				local t = fam.toks[m.name]
				if t then present[t] = true end
			end
			local cands = {}
			for _, t in ipairs(m.tokens) do
				if present[t] then cands[#cands + 1] = t end
			end
			if cands[1] then
				local vals, n = packn(m.resolve(cands))
				if vals[1] then
					toks[m.name] = vals[1]
					for i = 2, n do
						nargs = nargs + 1
						args[nargs] = vals[i]
					end
				end
			end
		end
	end
	return M.path(toks), args, nargs
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
	render = function(tok) return tok end,
})

-- the pointer over a text block: the callback receives the row and the
-- block position, a miss falls through to the unqualified bind
---@diagnostic disable-next-line: missing-fields -- register fills the name
M.register('section', {
	order = 20,
	tokens = { 'TL', 'TR', 'BL', 'BR', 'ST' },
	parse = function(spec)
		local tok = spec:match '^([TB][LR])%+.+' or spec:match '^(ST)%+.+'
		if not tok then return nil, spec end
		return tok, spec:sub(#tok + 2)
	end,
	render = function(tok) return tok end,
	resolve = function(cands)
		local q, row, loc = mouse_box.block_at(cands)
		if not loc then return end
		return q, row, loc ---@diagnostic disable-line: redundant-return-value -- the row and the block position ride along as the payload
	end,
})

return M
