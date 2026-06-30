---@module 'swi.mode.cmd'

local U = require 'swi.lib.utils'
local binds = require 'swi.binds'

---@class swi.mode.cmd: swi.mode.input
local M = {
	super = require 'swi.mode.input',
	_path = 'swi.mode.cmd',
	_prompt = 'Code: ',

	-- Private config
	---@type string[]
	_history = {}, ---@private
	_hist_pos = 0, ---@private position in the history list when cycling
	_hist_matcher = '', ---@private cached user text for history cycling
}
-- TODO: add autocompletion, likely just for paths and potentially variables

---@return swi.mode.cmd
function M:new()
	U.new_object(self, M)
	M.super.new(self)
	binds.cmd(self)
	return self
end

function M:on_confirm(out)
	self.text = ''
	self._hist_matcher = ''
	if not out then return end

	self.enabled = false -- disable first to avoid any messages overriding code work
	local cb, err = loadstring(out)
	if not cb or err then return swi.text.set_status(err) end

	local repeated = false
	for _, v in ipairs(self._history) do
		if v == out then
			repeated = true
			break
		end
	end
	if not repeated then table.insert(self._history, 1, out) end
	cb()
end

-- TODO: text change handling needs a better generic approach - user vs sys update
function M:on_text_change(text)
	if text ~= self._history[self._hist_pos] then
		if self._hist_matcher ~= text then
			self._hist_pos, self._hist_matcher = 0, text
		end
	end
end

function M:hist_next()
	for i = self._hist_pos - 1, 1, -1 do
		if self._history[i]:find(self._hist_matcher, 1, true) then
			self._hist_pos = i
			self.text = self._history[i]
		end
	end
	self._hist_pos = 0
	self.text = self._hist_matcher
end
function M:hist_prev()
	for i = self._hist_pos + 1, #self._history, 1 do
		if self._history[i]:find(self._hist_matcher, 1, true) then
			self._hist_pos = i
			self.text = self._history[i]
		end
	end
end

return M
