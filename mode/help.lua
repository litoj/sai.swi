---@module 'sai.mode.help'

local U = require 'sai.lib.utils'
local pager = require 'sai.lib.pager'
local binds = require 'sai.binds'

---@class help_tab
---@field title string
---@field lines extended_text_template[]

---@class sai.mode.help: sai.lib.remapper
---@field pager? sai.lib.pager<extended_text_template>
---@field tab? integer
---@field gen_tabs? fun(self:sai.mode.help)
---@field _location? text_location the overlay window's block
local M = {
	super = require 'sai.lib.remapper',
	persist_mode_change = true,
	-- this mode brings its own pager: the remapper builds no help display
	help_pager = false,

	_tab = 1,
	---@type help_tab[]
	_tabs = {},
	---@type text_location
	_location = 'topleft',

	-- Owned sub-mode, built in new()
	---@diagnostic disable-next-line: missing-fields
	---@type sai.lib.pager<extended_text_template>
	pager = {},
}

---Create an instance (see sai.mode.var_help) by calling
---`help.new { _path = ..., gen_tabs = ... }` - the passed table becomes the instance.
---@return self
function M:new()
	U.new_object(self, M)
	M.super.new(self) -- the sai tree first: the pager writes through it

	binds.help(self)

	-- the pager rides the mode's own sai tree: one shared layer,
	-- so the mode's takeover keeps its own header and records pop with its lifecycle
	self.pager = pager.new {
		_path = self._path .. '.pager',
		sai = self.sai,
		_location = self._location or 'topleft',
		-- composed per render: a page turn or resize never shows a stale counter
		title_fmt = function(_, title, page_block)
			local head = title
			if self._enabled then head = ('%s [Tab %d/%d]'):format(title, self._tab, #self._tabs) end
			if not page_block then return head end
			return head .. '\t' .. page_block
		end,
	}
	binds.pager_scrolls(self.pager)

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

---Render the current tab into the pager; the index clamps when the set shrinks.
---The title is plain: the lines set right after picks it up for the paint.
---@protected
function M:render()
	self._tab = math.min(self._tab, #self._tabs) -- the set may have shrunk
	local tab = self._tabs[self._tab]
	if not tab then return end
	self.pager.title = tab.title
	self.pager.lines = tab.lines
	self.pager.scroll = 1
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
		self.sai[sai.mode].scale = 100 / m.get_image().width
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
