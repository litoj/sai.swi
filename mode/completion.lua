---@module 'sai.mode.completion'

local U = require 'sai.lib.utils'
local flt = require 'sai.lib.filter'
local utf8 = require 'sai.bridge.utf8'
local binds = require 'sai.binds'

---@class completion_item
---@field text string the displayed line
---@field insert? string what gets completed (default: `text`)
---@field rate? string what gets matched against the typed text (default: `text`)

---Rate candidates best-first; confirm inserts into target.
---@class sai.mode.completion: sai.mode.selector<completion_item>
---@field source? false|fun(base:string?):completion_item[] the candidate provider (unfiltered)
---@field target? sai.mode.editor the editor receiving the accepted completion
---@field ignore_case? boolean rate candidates case-insensitively
---@field on_confirm? fun(self:sai.mode.completion, item:completion_item|false):false final hook; accepts into the target, never closes the menu
local M = {
	super = require 'sai.mode.selector',
	_path = 'sai.mode.completion',

	-- Live config
	_location = 'bottomright',
	_max_height = 10,

	-- Public, changeable at any time
	---@type false|fun(base:string?):completion_item[]
	source = false,
	---@type sai.mode.editor|false
	target = false,
	ignore_case = false,
	---Shortest input that engages the rating; shorter input clears the
	---menu. Zero lists every candidate from the start.
	min_chars = 2,

	-- machinery of its host
	component = true,

	-- the items are candidate tables: render their text
	line_fmt = function(self, item, idx)
		local text = item and item.text or ''
		if idx == self._line then return '> ' .. text end
		if self._selected_idx[idx] then return '* ' .. text end
		return text
	end,

	-- the count rides the live line count: it must not accumulate in the title
	title_fmt = function(self, title, page_block)
		local head = ('%s %d'):format(title:gsub('\t$', ''), #self.lines)
		if not page_block then return head end
		return head .. '\t' .. page_block
	end,
}
setmetatable(M, { __index = M.super })

---Replace the target's current line with the accepted text (overridable);
---further typing re-rates through update().
---@param item completion_item|false
---@return false
function M:on_confirm(item)
	if item == false then return false end
	local t = self.target
	if not t then return false end
	local line = t.line
	t.visual = { line = line, col = 1 }
	t.col = utf8.len(t.lines[line]) + 1
	t:insert(item.insert or item.text)
	return false
end

---Set `source` on the instance afterwards; the host owns the lifecycle
---(enable/disable) and hosts the menu on its own `sai` tree.
---@return sai.mode.completion
function M:new()
	U.new_object(self, M)
	M.super.new(self)
	-- own machinery binds, not mode defaults: the component gate keeps
	-- the selector set away
	binds.completion(self)
	return self
end

---Rate and order the source's candidates against `base` and adjust the
---menu; below `min_chars` the list clears, the window stays put.
---@param base string? the text to complete (the current word/line)
---@return integer #matches
function M:update(base)
	base = base or ''
	local items = {}
	-- below the engage length nothing is worth matching against
	if self.source and #base >= (self.min_chars or 2) then
		if base == '' then
			-- only reachable with min_chars at zero: list every candidate
			for _, it in ipairs(self.source(base)) do
				items[#items + 1] = it
			end
		else
			local hits = {}
			for _, it in ipairs(self.source(base)) do
				-- the source rates: match the short name, show the full item
				local cand = it.rate or it.text
				if self.ignore_case then
					cand = cand:lower()
					base = base:lower()
				end
				local r = flt.rate(base, cand, false)
				if r then hits[#hits + 1] = { r, it.text, it } end
			end
			table.sort(hits, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
			for _, h in ipairs(hits) do
				items[#items + 1] = h[3]
			end
		end
	end

	self.lines = items
	self.line = 1
	return #items
end

return M
