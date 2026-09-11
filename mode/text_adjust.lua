---@module 'sai.mode.text_adjust'

local reg = require 'sai.lib.registry'
local binds = require 'sai.binds'

---Live text-box adjustment
---@class sai.mode.text_adjust: sai.lib.remapper
local M = {
	super = require 'sai.lib.remapper',
	_path = 'sai.mode.text_adjust',

	---@type number how quickly to change height percentile
	step = 1 / 10,
}

-- the blocks in section order: the pointer resolves them the same way
local locmap = {
	topleft = 'TL',
	topright = 'TR',
	bottomleft = 'BL',
	bottomright = 'BR',
	status = 'ST',
}

---@param loc text_location
---@return sai.lib.pager?
function M:owner_at(loc)
	local stack = reg.binds[sai.modes[1]][locmap[loc] .. '+ScrollUp']
	for i = #stack, 1, -1 do
		local layer = stack[i].layer
		if layer ~= self and layer ~= self.help_pager then return layer end
	end
end

local function add_in_dir(val, dir)
	if val > 1 then
		return math.max(2, val + dir)
	else
		return math.max(M.step, math.min(1, val + dir * M.step))
	end
end

---@param loc text_location
---@param dir -1|1 scroll direction: up = -1, down = 1
function M:adjust_height(loc, dir)
	local target = self:owner_at(loc)
	if not target then
		sai.notify('No active pager in location: ' .. loc)
		return
	end
	local val = target.max_height
	target.max_height = add_in_dir(val, dir)
	if loc ~= 'status' then
		sai.eventloop.trigger {
			event = 'OptionSet',
			match = target._path .. '.max_height',
			data = target.max_height,
			old = val,
		}
	end
end

---@param loc text_location
---@param dir -1|1 scroll direction: up = -1, down = 1
function M:adjust_scrolloff(loc, dir)
	local target = self:owner_at(loc)
	-- ignore pager
	if not target or not rawget(target, '_scroll_ahead') then
		sai.notify('No active selector in location: ' .. loc)
		return
	end
	---@cast target sai.mode.selector
	local val = target.scroll_ahead
	target.scroll_ahead = add_in_dir(val, dir)
	if loc ~= 'status' then
		sai.eventloop.trigger {
			event = 'OptionSet',
			---@diagnostic disable-next-line: invisible
			match = target._path .. '.scroll_ahead',
			data = target.scroll_ahead,
			old = val,
		}
	end
end

---@param src text_location
---@param dst text_location where to swap to (puts the dst pager to src if dst is occupied)
function M:swap(src, dst)
	local target = self:owner_at(src)
	if not target then
		sai.notify('No active pager in location: ' .. src)
		return
	end
	local next = self:owner_at(dst)
	target.location = dst
	if next then next.location = src end
end

M.super.new(M)
binds.text_adjust(M)
return M
