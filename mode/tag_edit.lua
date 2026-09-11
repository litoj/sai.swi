---@module 'sai.mode.tag_edit'

local U = require 'sai.lib.utils'
local S = require 'sai.bridge.shell'
local completion = require 'sai.mode.completion'
local l = sai.imagelist

---Pick a tag, then set its new value; Return writes it via the exiv2 command line, exiftool
---when exiv2 refuses the format. The pick pool lists every loaded tag with the current image's value: a meta viewer too.
---@class sai.mode.tag_edit: sai.mode.editor
---@field completion sai.mode.completion the tag pool while picking, the picked tag's values across the images while setting
local M = {
	super = require 'sai.mode.editor',
	_path = 'sai.mode.tag_edit',

	-- Owned sub-mode, built in new()
	---@diagnostic disable-next-line: missing-fields
	---@type sai.mode.completion
	completion = {},

	-- Live config
	_prompt = 'Tag', -- the status bar adds the colon
	_location = 'status',

	-- a recalled value misses its tag: the history has nothing to offer
	update_history = false,

	-- Private state
	---@type string|false
	_tag = false, ---@private the tag as picked (typed text or candidate), false while picking
	---@type string[]
	_keys = {}, ---@private the picked tag's full keys: a dotted pick stays alone, a dotless name expands to every loaded match
	---@type completion_item[]
	_values = {}, ---@private the picked tag's values across the images, deduplicated
	---@type string[]
	_all_tags = {}, ---@private every meta tag across the images, collected on enable
	---@type table<string,string>|false
	_cur_meta = false, ---@private the current image's entry meta: the pool shows its values
	_del_armed = false, ---@private an Enter on an empty value armed the deletion
}
setmetatable(M, { __index = M.super })

---The mode's own binds; the shared binds module hosts the core mode sets only.
local function bind(self)
	-- unmap first: the editor's own cfgs carry no kind, an overwrite would warn
	self.unmap 'Return'
	self.unmap 'Escape'
	self.unmap 'Ctrl+Escape'

	-- Return must not run the editor's confirm: its stay-open path re-enables
	-- the mode, and the enable resets the picked tag
	self.map('Return', function() self:_confirm() end, 'Pick the tag / write the value')
	self.map('Escape', function()
		-- the first Escape only drops the picked tag
		if self._tag then
			self:_unpick()
		else
			self:confirm(false)
		end
	end, 'Drop the picked tag, else abort')
	self.map('Ctrl+Escape', function() self.enabled = false end, 'Hide mode')

	-- the pane: Tab picks a tag, else completes the value into the input
	local pool = self.completion
	pool.unmap 'Tab' -- replaced: the host picks the tag with it
	pool.map('Tab', function()
		if self._tag then
			pool:confirm()
		else
			self:_accept()
		end
	end, 'Pick this tag / complete the value')
	pool.map('Ctrl+j', function() pool:move(1) end, 'Next candidate')
	pool.map('Ctrl+k', function() pool:move(-1) end, 'Previous candidate')
	pool.map('TL+MouseLeft', function(row, _)
		if not row then return end
		pool:select_at_mouse()
		if self._tag then
			pool:confirm()
		else
			self:_accept()
		end
	end, 'Pick the clicked tag / complete with the clicked value')
end

---@return sai.mode.tag_edit
function M:new()
	U.new_object(self, M)
	M.super.new(self)

	-- one pane, two grounds: the tag pool while picking, the picked tag's
	-- values while setting; idle lists the whole ground
	self.completion = completion.new {
		_path = self._path .. '.completion',
		_location = 'topleft',
		_max_height = 10,
		min_chars = 0,
		target = self,
	}
	self.completion.source = function(base) return self:_candidates(base) end
	-- the completion's click select would grab the pointer off the mode
	self.completion.unmap 'MouseLeft'

	if not self.component then bind(self) end
	return self
end

---The write command; override to use a different writer.
---@param keys string[] the full tag keys to write
---@param value string the new value, empty deletes the keys
---@return string command for sai.exec: `%m` (the marked files) or `%f` (the current one) - `%s` would drop the marks in viewer mode
function M:make_cmd(keys, value)
	local op = value == '' and 'del' or 'set'
	local mods = {}
	for _, k in ipairs(keys) do
		mods[#mods + 1] = '-M' .. S.quote(op .. ' ' .. k .. (op == 'set' and ' ' .. value or ''))
	end
	return 'exiv2 ' .. table.concat(mods, ' ') .. ' ' .. (#l.marked.get() > 0 and '%m' or '%f')
end

-- exiv2 and exiftool name the Exif blocks differently; the maker notes
-- carry the make as their group, without the Exif lead
local exiftool_fam1 = {
	Image = 'IFD0',
	Photo = 'ExifIFD',
	Iop = 'InteropIFD',
	GPSInfo = 'GPS',
}

---@param k string exiv2 full key, e.g. `Exif.Image.Rating`
---@return string? exiftool group path, e.g. `Exif:IFD0:Rating`; nil without a known family
local function exiftool_key(k)
	local fam, sub, leaf = k:match '^(%a+)%.([%w]+)%.([%w_]+)$'
	if not fam then return end
	if fam == 'Exif' then
		local std = exiftool_fam1[sub]
		if std then return ('Exif:%s:%s'):format(std, leaf) end
		-- the rest are the maker notes: the make is the group
		return ('%s:%s'):format(sub, leaf)
	elseif fam == 'Xmp' then
		return ('XMP:%s:%s'):format(sub, leaf)
	elseif fam == 'Iptc' then
		return ('IPTC:%s:%s'):format(sub, leaf)
	end
end

---The fallback write command: exiv2 refuses to write whole formats (BMFF images: jxl, avif,
---heic), exiftool writes those. `-n` keeps the values raw, like the exiv2 writer takes them. Override for a different fallback.
---@param keys string[] the full tag keys to write
---@param value string the new value, empty deletes the keys
---@return string? command for sai.exec: `%m` (the marked files) or `%f` (the current one); nil when no key translates
function M:make_fallback_cmd(keys, value)
	local args = {}
	for _, k in ipairs(keys) do
		local mapped = exiftool_key(k)
		if mapped then args[#args + 1] = S.quote('-' .. mapped .. '=' .. value) end
	end
	if not args[1] then return end
	return 'exiftool -n -overwrite_original '
		.. table.concat(args, ' ')
		.. ' '
		.. (#l.marked.get() > 0 and '%m' or '%f')
end

function M:on_text_changed()
	self._del_armed = false
	self.completion:update(self.text)
end

---The completion ground of the active state: the tag pool, else the picked tag's values.
---The pool shows each tag with the value the current image carries, so it doubles as a meta viewer.
---@param base string? plain input rates the short name, dotted input the full path
---@return completion_item[]
function M:_candidates(base)
	if not self._tag then
		local just_name = not base or not base:find('.', 1, true)
		local cur = self._cur_meta or {}
		local out = {}
		for _, name in ipairs(self._all_tags) do
			local v = cur[name]
			out[#out + 1] = {
				-- a tag the current image lacks shows its bare name
				text = v ~= nil and (name .. ':\t' .. tostring(v)) or name,
				insert = name,
				rate = just_name and name:match '[^.]*$' or name,
			}
		end
		return out
	end
	return self._values
end

---A dotless name expands to every loaded key with that leaf, like exiftool's `-all:`.
---A leaf no image carries resolves to the Exif family: `set` creates the tag.
---@param tag string
---@return string[]
function M:_resolve(tag)
	if tag:find('.', 1, true) then return { tag } end
	local keys = {}
	for _, t in ipairs(self._all_tags) do
		if t:match '[^.]*$' == tag then keys[#keys + 1] = t end
	end
	return #keys > 0 and keys or { 'Exif.Image.' .. tag }
end

---Register the tag to set: `tag`, else the candidate under the completion cursor, else the typed text. The completion swaps to the tag's values across the images.
---@param tag string?
function M:_accept(tag)
	if not tag then
		local item = self.completion.lines[self.completion.line]
		-- insert carries the bare tag: the pool line shows a value too
		tag = item and (item.insert or item.text) or self.text:match '^%s*(.-)%s*$'
	end
	if not tag or tag == '' then return end
	self._tag = tag
	self._keys = self:_resolve(tag)
	self._del_armed = false

	-- dedup and sort: the menu order must not follow the hash order
	local seen = {}
	local values = {}
	for _, e in ipairs(l.get(true)) do
		for _, k in ipairs(self._keys) do
			local v = e.meta[k]
			if v ~= nil then
				v = tostring(v)
				if not seen[v] then
					seen[v] = true
					values[#values + 1] = { text = v }
				end
			end
		end
	end
	table.sort(values, function(a, b) return a.text < b.text end)
	self._values = values

	self.prompt = 'Set ' .. tag
	self.text = ''
	self.completion:update ''
end

---Drop the picked tag: back to the pool, the prompt follows.
function M:_unpick()
	self._tag = false
	self._keys = {}
	self._values = {}
	self._del_armed = false
	self.prompt = 'Tag'
	self.text = ''
	self.completion:update ''
end

---The mode's Return: pick the typed tag first, then write the value; a refusal keeps the state.
---An empty value arms the deletion: the second Enter deletes the tag.
function M:_confirm()
	if not self._tag then
		-- Enter takes the typed text, not the completion candidate
		local tag = self.text:match '^%s*(.-)%s*$'
		if tag == '' then
			sai.notify 'No tag picked'
		else
			self:_accept(tag)
			sai.notify(('%s picked - not written yet'):format(tag))
		end
		return
	end

	local value = self.text
	if value == '' and not self._del_armed then
		self._del_armed = true
		sai.notify(('No value given - press Enter again to delete %s'):format(self._tag))
		return
	end
	self:_write(value)
end

---Run the write (the deletion when `value` is empty); a refusal keeps the state.
---A refused format goes to the fallback writer before it counts as a failure.
---@param value string
function M:_write(value)
	local out, code, err = sai.exec(self:make_cmd(self._keys, value))
	if tonumber(code) ~= 0 then
		local fb = self:make_fallback_cmd(self._keys, value)
		if fb then
			out, code, err = sai.exec(fb)
		end
		if tonumber(code) ~= 0 then
			sai.notify(err ~= '' and err or (out ~= '' and out or 'the write failed'), -10)
			return
		end
	end

	self:_apply_meta(value ~= '' and value or nil)
	-- torn down first, like the editor's own confirm: the message lands after the closing render
	self.enabled = false
	sai.notify(value ~= '' and ('Wrote %s = %s'):format(self._tag, value) or ('Deleted %s'):format(self._tag))
end

---Mirror the write into the meta of the written files: without it, the
---exiv2 cache serves the pre-write values until the next stat re-read.
---@param value? string nil deletes the keys
function M:_apply_meta(value)
	-- mirrors `%s`: the marked files, else the current one
	local targets = {}
	for _, p in ipairs(l.marked.get()) do
		targets[p] = true
	end
	if not next(targets) then targets[l.get_current().path] = true end

	for _, e in ipairs(l.get(true)) do
		if targets[e.path] then
			for _, k in ipairs(self._keys) do
				e.meta[k] = value
			end
		end
	end
end

function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then
		-- the pool values come from the current entry's meta, not
		-- l.get_current(): that image carries swayimg's own parse, whose
		-- key set disagrees with the bridge-loaded pool
		local cur_path = l.get_current().path
		local tags = {}
		local seen = {}
		for _, e in ipairs(l.get(true)) do
			if e.path == cur_path then self._cur_meta = e.meta end
			for k in pairs(e.meta) do
				if not seen[k] then
					seen[k] = true
					tags[#tags + 1] = k
				end
			end
		end
		table.sort(tags)
		self._all_tags = tags

		-- the pane comes up below the mode: its records land under the
		-- mode's, so the corner display lists them under it
		self.completion.enabled = true
		M.super.set_enabled(self, val)
		self:_unpick()
	else
		self.completion.enabled = false
		M.super.set_enabled(self, val)
	end

	return false
end

return M
