---@module 'sai.mode.key_help'

local U = require 'sai.lib.utils'

---Key help overlay: a tab with the binds of every active bind layer of the current mode.
---@class sai.mode.key_help: sai.mode.help
---@field bind_fmt string Default format for keybind list and description
local M = {
	super = require 'sai.mode.help',
	_path = 'sai.mode.key_help',
	bind_fmt = '%s\t%s',
	-- bind_fmt = '%20s: %s',
	auto_help = false, --- the binds are listed in the tabs instead
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
				lines = U.str_bindlist(api, self.bind_fmt),
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
			pager.title = ('%s [Tab %d/%d]'):format(tab.title, self._tab, #self._tabs)
		end
	end)
	return ret
end

M.super.new(M)
M.pager.location = 'topright' -- the right pane, var_help takes the left one
return M
