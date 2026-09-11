---@module 'sai.api.section'

local mouse_box = require 'sai.bridge.mouse_box'

---The location qualifier: a text-block code in front of any bind
---(`TL+j`); the block owns the pointer, so the bind fires only over
---it. Geometry stays in the mouse box.
---@class sai.api.section
local M = {}

---The section codes in resolution priority order: the first block that contains the pointer wins.
---@type string[]
M.order = { 'TL', 'TR', 'BL', 'BR', 'ST' }

---@type {[text_location]:string} the inverse of the mouse box address table
local loc_section = {}
for _, code in ipairs(M.order) do
	loc_section[mouse_box.code_loc[code]] = code
end

---The `section` bind modifier: the pointer-over-block qualifier.
M.mod = {
	order = 20,
	tokens = M.order,
	parse = function(spec)
		local token = spec:match '^([TB][LR])%+.+' or spec:match '^(ST)%+.+'
		if not token then return nil, spec end
		return token, spec:sub(#token + 2)
	end,
	render = function(token) return token end,
	resolve = function(cands)
		local q, row, loc = mouse_box.block_at(cands)
		if not loc then return end
		return q, row, loc ---@diagnostic disable-line: redundant-return-value -- the row and the block position ride along as the payload
	end,
}

---Qualify a bind with its block's section code.
---@param loc text_location the block the bind follows
---@param b string the declared bind key
---@return string the block's code in front of any unprefixed bind; a prefixed bind passes unchanged
function M.key(loc, b)
	if M.mod.parse(b) then return b end
	return loc_section[loc] .. '+' .. b
end

return M
