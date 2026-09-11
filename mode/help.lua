---@module 'sai.mode.help'

local U = require 'sai.lib.utils'
local flt = require 'sai.lib.filter'
local selector = require 'sai.mode.selector'
local filter_mode = require 'sai.mode.filter'
local binds = require 'sai.binds'

---@class help_tab
---@field title string
---@field lines extended_text_template[]
---@field entries? {line:extended_text_template, action:fun()?}[] per-line actions, aligned with lines

---@class sai.mode.help.pager: sai.mode.selector<extended_text_template>
---@field _filtering boolean the status filter narrows the listing

---@class sai.mode.help: sai.lib.remapper
---@field pager sai.mode.help.pager the listing window; a selector so the filtered line confirms
---@field filter sai.mode.filter the status input narrowing the listing
---@field tab? integer
---@field gen_tabs? fun(self:sai.mode.help)
---@field _location? text_location the overlay window's block
---@field _filtering boolean the status filter narrows the listing
---@field _actions (fun()?)[] per-line actions, aligned with the pager's lines
local M = {
	super = require 'sai.lib.remapper',
	persist_mode_change = true,

	_tab = 1,
	---@type help_tab[]
	_tabs = {},
	---@type text_location
	_location = 'topleft',

	_filtering = false,
	---@type (fun()?)[]
	_actions = {},
	---@type {line:extended_text_template, action:fun()?}[]
	_entries = {},

	-- owned sub-modes, built in new(); false until then keeps the key
	-- present for the build, like the stock hooks
	---@type sai.mode.help.pager|false
	pager = false,
	---@type sai.mode.filter|false
	filter = false,
}

---Fuzzy rate one rendered part, higher first.
---@param text string
---@param part string
---@return number?
local function rate_part(text, part)
	local r = flt.rate(text, part, false)
	if r then return -r end
end

---Create an instance (see sai.mode.var_help) by calling
---`help.new { _path = ..., gen_tabs = ... }` - the passed table becomes the instance.
---@return self
function M:new()
	U.new_object(self, M)
	M.super.new(self) -- the sai tree first: the pager writes through it

	binds.help(self)

	-- the pager rides the mode's own sai tree: one shared layer,
	-- so the mode's takeover keeps its own header and records pop with its lifecycle.
	-- a selector with a blank cursor: confirming a line runs it, idle it reads as a plain list.
	-- persist with the host: a flip parks (never downs) the shared tree
	self.pager = selector.new {
		_path = self._path .. '.pager',
		sai = self.sai,
		_location = self._location or 'topleft',
		component = true,
		single_select = true,
		persist_mode_change = true,
		_filtering = false,
		-- composed per render: a page turn or resize never shows a stale counter
		title_fmt = function(_, title, page_block)
			local head = title
			if self._enabled then head = ('%s [Tab %d/%d]'):format(title, self._tab, #self._tabs) end
			if not page_block then return head end
			return head .. '\t' .. page_block
		end,
	}
	self.pager.line_fmt = function(_, item, idx)
		-- the host flag: the paint closure already captures the mode
		if self._filtering and idx == self.pager.line then return '→ ' .. self.filter:filter_render(item) end
		return item
	end
	self.pager.on_confirm = function()
		self:run_line()
		return false
	end
	binds.help_pager(self.pager)

	-- the status filter narrows the listing in place; the hosts only
	-- implement the per-line actions, the matching lives here.
	-- its own tree: a transient input must not down the host's on close
	---@diagnostic disable-next-line: missing-fields -- the rating loop fills in per input
	self.filter = filter_mode.new {
		_path = self._path .. '.filter',
		_location = 'status',
		_prompt = '/',
		component = true,
	}
	self.filter.unmap 'Shift+Return'
	-- the arrows walk the matches, not the input: history stays filed but unrecalled
	self.filter.unmap 'Up'
	self.filter.unmap 'Down'
	-- a component claims no action binds of its own: the host settles the
	-- input - Return accepts the narrowing, Escape drops it alone, the
	-- overlay stands either way
	self.filter.map('Return', function() self.filter:confirm() end, 'Accept the filter')
	self.filter.map('Escape', function() self.filter:confirm(false) end, 'Abort the filter')
	self.filter.filter_process = function() return self:filter_match() end
	self.filter.filter_show = function(_, matches) self:filter_apply(matches) end
	self.filter.on_confirm = function(_, res)
		if res == false then
			self:filter_reset()
		else
			-- the narrowed view stands: the window scrolls it again
			self._filtering = false
			---@diagnostic disable-next-line: invisible -- the window's nav knob, owned here
			self.pager._filtering = false
			self:run_line()
		end
	end

	self.sai.eventloop.subscribe {
		event = 'User',
		pattern = { 'ModePush', 'ModePop' },
		-- another layer toggled: the tab set changed, land on the first
		callback = function(ev)
			if ev.data == self then return end
			self:gen_tabs()
			self:set_tab(1)
		end,
	}
	-- image to a small backdrop for the overlay
	self.sai.viewer.default_scale = 'keep_width'
	self.sai.slideshow.default_scale = 'keep_width'
	if sai.text.background < 0x88000000 then self.sai.text.background = 0xaa1c1c1c end

	return self
end

---Open the status filter over the current tab.
function M:open_filter()
	self._filtering = true
	---@diagnostic disable-next-line: invisible -- the window's nav knob, owned here
	self.pager._filtering = true
	self.filter.text = ''
	self.filter.enabled = true
end

---Indexes of the current tab's entries matching the query: names
---(before the tab) fuzzy first, descriptions (after it) offset by -100.
---@return integer[]
function M:filter_match()
	local text = self.filter.text
	local out = {}
	if text == '' then
		for idx in ipairs(self._entries) do
			out[#out + 1] = idx
		end
		return out
	end
	local scored = {}
	for idx, entry in ipairs(self._entries) do
		local rendered = self.filter:filter_render(entry.line)
		local before, after = rendered:match '^(.-)\t(.*)$'
		local score = before and rate_part(text, before) or rate_part(text, rendered)
		if score == nil and after then
			score = rate_part(text, after)
			if score then score = score - 100 end
		end
		if score ~= nil then scored[#scored + 1] = { score, idx } end
	end
	table.sort(scored, function(a, b)
		if a[1] ~= b[1] then return a[1] > b[1] end
		return a[2] < b[2]
	end)
	for _, entry in ipairs(scored) do
		out[#out + 1] = entry[2]
	end
	return out
end

---Show the matched entries in the window, actions riding along.
---@param matches integer[] indexes into the current tab's entries
function M:filter_apply(matches)
	local lines, actions = {}, {}
	for _, idx in ipairs(matches) do
		local entry = self._entries[idx]
		lines[#lines + 1] = entry.line
		actions[#actions + 1] = entry.action
	end
	self.pager.lines = lines
	self._actions = actions
	self.pager.line = 1
	self.pager.scroll = 1
end

---Drop the narrowing: the full tab stands again.
function M:filter_reset()
	self._filtering = false
	---@diagnostic disable-next-line: invisible -- the window's nav knob, owned here
	self.pager._filtering = false
	local lines, actions = {}, {}
	for _, entry in ipairs(self._entries) do
		lines[#lines + 1] = entry.line
		actions[#actions + 1] = entry.action
	end
	self.pager.lines = lines
	self._actions = actions
	self.pager.line = 1
	self.pager.scroll = 1
end

---Run the selected line's action, if it carries one.
function M:run_line()
	local action = self._actions[self.pager.line]
	if not action then return end
	local ok, err = pcall(action)
	if not ok then sai.notify(tostring(err)) end
end

---Render the current tab into the pager; the index clamps when the set shrinks.
---The title is plain: the lines set right after picks it up for the paint.
---@protected
function M:render()
	self._tab = math.min(self._tab, #self._tabs) -- the set may have shrunk
	local tab = self._tabs[self._tab]
	if not tab then return end
	self.pager.title = tab.title
	self._entries = tab.entries or {}
	if self._filtering then
		self:filter_apply(self:filter_match())
	else
		self:filter_reset()
	end
end

---@protected
function M:set_tab(idx)
	if not self._tabs[1] then return false end -- nothing to switch to
	self._tab = (idx - 1) % #self._tabs + 1
	self:render()
	return true
end

-- The pager rides the mode's own sai tree, so a mode flip parks and re-applies the brackets with the records.
-- Only the real enable/teardown toggles the pager, never a flip.
---@param val boolean
function M:_set_active(val)
	---@diagnostic disable-next-line: invisible -- the owned input's run flag
	if not val and self.filter._enabled then
		-- parking (or teardown) with the input open: drop the narrowing
		-- first, while the trees still stand
		self.filter:confirm(false)
	end
	M.super._set_active(self, val)
	if val then
		self:gen_tabs() -- the mode flip changed the binds under the tabs
		self:render()
	end
end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return true end
	if val and sai.mode ~= 'gallery' then
		local m = sai.modes[1] ---@cast m sai.api.viewer
		-- no image, no fit: get_image is nil on an empty list
		local img = m.get_image()
		if img then self.sai[sai.mode].scale = 100 / img.width end
	end
	if val then
		-- up first: the mode's sai call is a no-op then, so its records land above the pager's.
		-- the tabs derive the pager's sub-header from its records.
		self.pager.enabled = true
		M.super.set_enabled(self, true)
	else
		-- down after the teardown: the mode's tree call released the
		-- pager's records with its own, the pager call is a no-op there
		M.super.set_enabled(self, false)
		self.pager.enabled = false
	end
	return true
end

return M
