---@module 'sai.mode.key_help'

local U = require 'sai.lib.utils'
local X = require 'sai.bridge.xkb'
local e = require 'sai.api.eventloop'

---Key help overlay: a tab with the binds of every active bind layer of the current mode.
---@class sai.mode.key_help: sai.mode.help
local M = {
	super = require 'sai.mode.help',
	_path = 'sai.mode.key_help',
	bind_fmt = '%s\t%s', --- format for keybind list and description
	-- bind_fmt = '%20s: %s',
	short_binds = false, --- show binds in the short form (C-x, A-y…) instead of full xkb names
	auto_help = false, --- the binds are listed in the tabs instead
	---@type sai.lib.remapper|false
	_displayed_mode = false, ---@private the mode shown by the auto help display
}

---All tabs, generated straight-up (see sai.mode.help): one per active bind
---layer of the current mode that has binds (bindless overlays are skipped).
function M:tabs()
	local tabs = {}
	for _, bindset in ipairs(U.get_active_bindsets(sai[sai.mode])) do
		if next(bindset._mappings) then
			-- adapter so that U.str_bindlist can read the raw bindmap of the layer
			---@diagnostic disable-next-line: missing-fields
			local api = { get_mappings = function() return bindset._mappings end }
			tabs[#tabs + 1] = {
				title = U.pretty_name(bindset._path),
				lines = U.str_bindlist(api, self.bind_fmt, self.short_binds and X.short_key_name or nil),
			}
		end
	end
	return tabs
end

---Right pane title: the mode name aligned to the value column, then the tab block.
function M:set_tab(idx)
	local ret
	self.pager:bulk_change(function(pager)
		ret = M.super.set_tab(self, idx)
		if ret then
			local tab = self._tabs[self._tab]
			-- without the mode's own binds there is no way to switch tabs
			pager.title = self._enabled and ('%s [Tab %d/%d]'):format(tab.title, self._tab, #self._tabs)
				or (tab.title .. ' [binds]')
		end
	end)
	return ret
end

---Strict display: the pager only, without the mode's own keybinds.
---The full, bind-controlling mode is available through `enabled` (F1).
---Without an activator the topmost active mode is used; modes without
---`auto_help` turn the display off.
---@private
---@param activator? sai.lib.remapper mode to display, nil for the topmost active one
---@return boolean
function M:_display(activator)
	if self._enabled then return true end -- the full mode owns the pager

	if not activator then
		local mode = sai[sai.mode]
		activator = mode:get_active_mode()
		if activator == mode then activator = nil end -- no custom layer left
	end
	if not activator or not activator.auto_help then
		self._displayed_mode = false
		self.pager.enabled = false -- the pager restores the text layer with itself
		return false
	end

	self._displayed_mode = activator
	-- land on the activator's own tab when it has one
	local title = activator._path and U.pretty_name(activator._path)
	local idx = 1
	for i, tab in ipairs(self.tabs(self)) do
		if title and tab.title == title then
			idx = i
			break
		end
	end
	if not self:set_tab(idx) then return true end -- nothing to show yet: keep the pager hidden
	self.pager.enabled = true -- brings the text layer up with itself
	return true
end

M.super.new(M)
rawset(M.pager, '_location', 'topright') -- the right pane, var_help takes the left one

-- auto help display: re-derive it from the active mode stack on every layer
-- change; global so it works before the first F1
e.subscribe {
	event = 'User',
	pattern = { 'ModePush', 'ModePop' },
	callback = function() M:_display() end,
}

return M
