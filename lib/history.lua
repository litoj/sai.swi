---@module 'sai.lib.history'

local e = require 'sai.api.eventloop'

---Newest-first entry list with a recall cycle.
---Up is `next` (older), Down is `prev` (newer, past newest restores once).
---@class sai.lib.history
---@field file? string|false permanent store, false means memory only
---@field max_size? integer|false cap on entries, false means no cap
---@field package _pos? integer 0 at prompt, else 1-based index into entries
---@field package _match? string|nil saved filter while cycling, nil out of cycle; no-match calls keep nil sticky
---@field package _leave_hook? table|false exit save hook once installed
local M = {}

---The store holds one entry per line, so escape the newline.
---@param s string
---@return string
local function encode(s) return (s:gsub('\\', '\\\\'):gsub('\n', '\\n')) end

---Inverse of encode.
---@param s string
---@return string
local function decode(s)
	return (
		s:gsub('\\(.)', function(c)
			if c == 'n' then return '\n' end
			if c == '\\' then return '\\' end
			return '\\' .. c
		end)
	)
end

---Install the exit save hook once per instance when a file is set.
---@param self sai.lib.history
local function ensure_hook(self)
	if self._leave_hook or type(self.file) ~= 'string' then return end
	self._leave_hook = e.subscribe {
		event = 'SwiLeavePre',
		once = true,
		callback = function()
			self:save()
			return true
		end,
	}
end

---Trim oldest entries past the cap.
---@param self sai.lib.history
local function trim(self)
	local cap = self.max_size
	if type(cap) ~= 'number' or cap < 0 then return end
	while #self > cap do
		table.remove(self)
	end
end

---Seed entries, newest first, over the permanent store when one is set.
---@param cfg? string[]|sai.lib.history
---@return sai.lib.history
function M.new(cfg)
	local self = setmetatable({ _pos = 0, _leave_hook = false, file = false, max_size = false }, { __index = M })
	local seed = {}
	if type(cfg) == 'table' then
		self.file = cfg.file or false
		self.max_size = cfg.max_size or false
		for i = 1, #cfg do
			seed[#seed + 1] = cfg[i]
		end
	end
	for i = 1, #seed do
		self[#self + 1] = seed[i]
	end
	trim(self)
	if type(self.file) == 'string' then
		self:load()
		-- reversed: each add lands on top, so the first seed stays newest
		for i = #seed, 1, -1 do
			self:add(seed[i])
		end
		ensure_hook(self)
	end
	return self
end

---File a confirmed input on top. Empty inputs never file.
---A repeat moves the entry to the top. Resets the recall cycle.
---@param text string
function M:add(text)
	if text == nil or text == '' then return end
	for i, v in ipairs(self) do
		if v == text then
			table.remove(self, i)
			break
		end
	end
	table.insert(self, 1, text)
	trim(self)
	self._pos, self._match = 0, nil
	ensure_hook(self)
end

---Leave the recall cycle.
function M:reset()
	self._pos, self._match = 0, nil
end

---Any entry contains the match as a plain substring.
---@param self sai.lib.history
---@param match string
---@return boolean
local function any_match(self, match)
	for _, e in ipairs(self) do
		if e:find(match, 1, true) then return true end
	end
	return false
end

---A call continues the cycle when the match is the saved filter or a
---prefix of the entry under the cursor (the state right after a recall).
---@param self sai.lib.history
---@param match string
---@return boolean
local function continues(self, match)
	if match == self._match then return true end
	local cur = self[self._pos]
	return cur ~= nil and cur:sub(1, #match) == match
end

---Start or restart the cycle at the prompt with `match` as the filter.
---False when no entry matches: the filter then stays out of the cycle.
---@param self sai.lib.history
---@param match string
---@return boolean
local function begin(self, match)
	if self._match ~= nil and continues(self, match) then return true end
	if not any_match(self, match) then
		self._match = nil
		return false
	end
	self._match = match
	self._pos = 0
	return true
end

---Recall the next older matching entry (Up). Holds at oldest.
---Returns nil when nothing changes.
---@param match string text from input start to cursor
---@return string?
function M:next(match)
	if not begin(self, match or '') then return nil end
	for i = self._pos + 1, #self do
		if self[i]:find(self._match, 1, true) then
			self._pos = i
			return self[i]
		end
	end
	return nil
end

---Recall the next newer matching entry (Down). Past newest restores the
---saved text once, then nil. Returns nil when nothing changes.
---@param match string text from input start to cursor
---@return string?
function M:prev(match)
	if not begin(self, match or '') then return nil end
	for i = self._pos - 1, 1, -1 do
		if self[i]:find(self._match, 1, true) then
			self._pos = i
			return self[i]
		end
	end
	if self._pos == 0 then return nil end
	local saved = self._match
	self._pos, self._match = 0, nil
	return saved
end

---Point at a new permanent store, load it, save on exit from now on.
---@param path string|false
function M:set_file(path)
	self.file = path or false
	if type(self.file) == 'string' then
		self:load()
		ensure_hook(self)
	end
end

---Cap the entries, drop oldest past it now.
---@param n integer|false
function M:set_max_size(n)
	self.max_size = n
	trim(self)
end

---Read the permanent store over the entries. Missing file reads empty.
function M:load()
	if type(self.file) ~= 'string' then return end
	local f = io.open(self.file, 'r')
	if not f then return end
	local out = {}
	for line in f:lines() do
		local e = decode(line)
		if e ~= '' then out[#out + 1] = e end
	end
	f:close()
	while #self > 0 do
		table.remove(self)
	end
	for i = 1, #out do
		self[#self + 1] = out[i]
	end
	trim(self)
	self._pos, self._match = 0, nil
end

---Write the entries to the permanent store. No file is a no-op.
function M:save()
	if type(self.file) ~= 'string' then return end
	local f = io.open(self.file, 'w') or error('Could not write file: ' .. self.file)
	for _, e in ipairs(self) do
		f:write(encode(e), '\n')
	end
	f:close()
end

return M
