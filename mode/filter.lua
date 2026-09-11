---@module 'sai.mode.filter'

local U = require 'sai.lib.utils'
local flt = require 'sai.lib.filter'

---Live dataset filter: typing rates the source best-first and shows the matches.
---Hosts implement the data-processing contract; the base owns only the rating loop.
---@class sai.mode.filter: sai.mode.editor
---@field filter_source fun(self:sai.mode.filter):any[] the dataset in stable order
---@field filter_rate fun(self:sai.mode.filter, text:string, item:any):number? higher sorts first, nil drops the item
---@field filter_show fun(self:sai.mode.filter, items:any[]) push the matches into the host display
local M = {
	super = require 'sai.mode.editor',
	_path = 'sai.mode.filter',
}
setmetatable(M, { __index = M.super })

---Render an item for rating: strings as-is, dyntext through its callback.
---@param item any
---@return string
function M:filter_render(item)
	if type(item) == 'string' then return item end
	if type(item) == 'table' and type(item.callback) == 'function' then return item.callback() end
	return tostring(item)
end

---Default rating: fuzzy over the whole rendered item, higher first; empty text keeps every item.
---@param text string
---@param item any
---@return number?
function M:filter_rate(text, item)
	if text == '' then return 0 end
	local r = flt.rate(text, self:filter_render(item), false)
	if r then return -r end
end

---Default process: rate every source item, stable best-first.
---Overridable wholesale (conditions, panes).
---@return any[]? matches, nil keeps the last view
function M:filter_process()
	local text = self.text
	local scored = {}
	for idx, item in ipairs(self:filter_source()) do
		local score = self:filter_rate(text, item)
		if score ~= nil then scored[#scored + 1] = { score, idx, item } end
	end
	table.sort(scored, function(a, b)
		if a[1] ~= b[1] then return a[1] > b[1] end
		return a[2] < b[2]
	end)
	local out = {}
	for _, entry in ipairs(scored) do
		out[#out + 1] = entry[3]
	end
	return out
end

---Push the matches; the base owns no display, so every host overrides this.
function M:filter_show() error('filter_show not implemented', 2) end

---The dataset while no host provides one: nothing to match.
---@return any[]
function M:filter_source() return {} end

---Typing re-rates; a nil process keeps the last view (an invalid line constrains nothing).
function M:on_text_changed()
	local matches = self:filter_process()
	if matches ~= nil then self:filter_show(matches) end
end

---@return sai.mode.filter
function M:new()
	U.new_object(self, M)
	M.super.new(self)
	return self
end

return M
