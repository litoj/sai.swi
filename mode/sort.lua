---@module 'sai.mode.sort'

local U = require 'sai.lib.utils'
local flt = require 'sai.lib.filter'
local S = require 'sai.bridge.shell'
local selector = require 'sai.mode.selector'
local completion = require 'sai.mode.completion'
local l = sai.imagelist
local binds = require 'sai.binds'

---Interactive sort builder; confirm keeps the comparator and the picked
---criteria for the next entry, abort restores the entry sort and drops them.
---@class sai.mode.sort: sai.mode.editor
---@field asc_icon string
---@field desc_icon string
---@field completion sai.mode.completion the pool of unpicked fields to complete from, rated by the input
---@field sort_by sai.mode.selector<string> the picked sort keys in their order, single-select, filtered by the input
local M = {
	super = require 'sai.mode.editor',
	_path = 'sai.mode.sort',

	-- Live config
	_prompt = 'Input', -- the status bar adds the colon
	_location = 'status',

	-- Public, changeable at any time
	asc_icon = '↑',
	desc_icon = '↓',

	-- Owned sub-modes, built in new()
	---@diagnostic disable-next-line: missing-fields
	---@type sai.mode.completion
	completion = {},
	---@diagnostic disable-next-line: missing-fields
	---@type sai.mode.selector<string>
	sort_by = {},

	-- Private state
	---@type {[string]:1|-1}
	_dir = {}, ---@private
	---@type string[]
	_criteria = {}, ---@private the picked criteria, in order
	---@type {[string]:fun(self:unknown):unknown}
	_code = {}, ---@private value transforms of the `name:code` criteria; `self` is the name's value (the image itself for the `self` key)
	---@type {[string]:string}
	_code_src = {}, ---@private the code of the `name:code` criteria as typed, recalled into the input by Ctrl+p
	---@type false|{ name: string, xf: fun(self:unknown):unknown }
	_preview = false, ---@private the typed code input, applied live next to the picked criteria until committed
	---@type string[]|false
	_all_tags = false, ---@private every sortable field, collected on enable
	---@type string[]
	_unpicked = {}, ---@private the unpicked sortable fields
	---@type order_t|fun(a:swayimg.entry,b:swayimg.entry):boolean
	_prev_sort = 'none', ---@private the order active on entry
}
setmetatable(M, { __index = M.super })

function M:on_text_changed()
	self:_apply_filter()
	self:_preview_input()
end

---@return sai.mode.sort
function M:new()
	U.new_object(self, M)
	M.super.new(self)

	-- two panes: the field pool to complete from (idle shows every unpicked
	-- field, typing rates it) and the picked criteria, both ride the input filter
	self.completion = completion.new {
		_path = self._path .. '.completion',
		_location = 'topleft',
		_max_height = 10,
		-- the pool lists from the start: idle shows the whole ground
		min_chars = 0,
	}
	self.sort_by = selector.new {
		_path = self._path .. '.sort_by',
		_mappings = {},
		component = true,
		single_select = true,
		_location = 'bottomleft',
		_max_height = 10,
	}

	self.completion.source = function(base) return self:_tag_candidates(base) end
	self.sort_by.line_fmt = function(pane, name, idx)
		local arrow = self._dir[name] == -1 and self.desc_icon or self.asc_icon
		-- the code the criterion carries is rendered too: the input clears on
		-- commit, the pane must still show what was typed, not only the name
		local code, line = self._code_src[name], ('%s %s'):format(name, arrow)
		if code then line = ('%s %s'):format(line, code) end
		if idx == pane.line then return '> ' .. line end
		return line
	end

	binds.sort(self)
	return self
end

---One sort-criterion value; exif via parsed meta.
---@param entry swayimg.image
---@param criterion string
---@return string|number|boolean|nil
local function sortval(entry, criterion)
	if criterion == 'path' then return entry.path end
	if criterion == 'mark' then return entry.mark end
	if criterion == 'index' then return entry.index end
	local v = entry[criterion]
	if v == nil and entry.meta and entry.meta[criterion] ~= nil then v = U.parse_exif_val(entry.meta[criterion]) end
	return v
end

---The value a criterion's transform sees.
---@param entry swayimg.image
---@param name string
---@return unknown the image for `self`, the field or parsed tag value otherwise
local function value(entry, name)
	if name == 'self' then return entry end
	return sortval(entry, name)
end

---The current image's entry off the list: the comparator takes entries (the app-side
---current image carries none), and the base comparison must not cost a metadata load.
---@return swayimg.entry? nil when the current image is not listed
local function current_entry()
	local path = l.get_current().path
	for _, e in ipairs(l.get()) do
		if e.path == path then return e end
	end
end

---Prove a compiled transform over the values the comparison feeds it and
---check its result is a comparable scalar, before it reaches l.order.
---@param target string
---@param xf fun(self:unknown):unknown
---@return string? err nil when the transform took every probe and returned a scalar
local function worst_case(target, xf)
	local real = value(l.get_current(), target)
	-- a dotted tag may be missing on another image, the plain fields never are
	local last = (real ~= nil and target:find('.', 1, true)) and 2 or 1
	for i = 1, last do
		local ok, res = pcall(xf, i == 1 and real or nil)
		if not ok then
			return ('Comparator failed with [%s] as valid params:\n%s'):format(i == 1 and 'current' or 'missing', res)
		end
		if res ~= nil and type(res) ~= 'string' and type(res) ~= 'number' then
			return ('Not a comparable value: %s'):format(type(res))
		end
	end
end

---Build comparator from the active sort criteria; missing sorts last ascending. The typed code
---input previews as an extra criterion: it overrides the same-named pick's transform or rides after.
---@return false|fun(a:swayimg.image, b:swayimg.image):boolean equal criteria break the tie, a `name:code` criterion compares its transform's results
function M:sort_fn()
	local extra = self._preview and not self._dir[self._preview.name] and 1 or 0
	if #self._criteria + extra == 0 then return false end

	local criteria = {}
	for i, name in ipairs(self._criteria) do
		-- the preview of the same name stands in for the picked transform
		local xf = self._preview and self._preview.name == name and self._preview.xf or self._code[name]
		criteria[i] = { name, self._dir[name] or 1, xf }
	end
	if extra == 1 then criteria[#criteria + 1] = { self._preview.name, 1, self._preview.xf } end

	return function(a, b)
		for _, k in ipairs(criteria) do
			local xf, av, bv = k[3], value(a, k[1]), value(b, k[1])
			if xf then
				av, bv = xf(av), xf(bv)
			end
			if av ~= bv then
				if av == nil then
					return k[2] < 0
				elseif bv == nil then
					return k[2] > 0
				end
				-- numbers compare numerically, everything else as strings
				local lt
				if type(av) == 'number' and type(bv) == 'number' then
					lt = av < bv
				else
					lt = tostring(av) < tostring(bv)
				end
				if k[2] < 0 then lt = not lt end
				return lt
			end
		end
		return false -- every criterion equal: not less
	end
end

function M:_refresh_lists()
	local picked = {}
	for _, k in ipairs(self._criteria) do
		picked[k] = true
	end

	local unpicked = {}
	for _, tag in ipairs(self._all_tags) do
		if not picked[tag] then unpicked[#unpicked + 1] = tag end
	end
	self._unpicked = unpicked
	self:_apply_filter()
end

---The unpicked fields as completion items; like the image_filter's tag source.
---@param base string? plain input rates the short name, dotted input the full path
---@return completion_item[]
function M:_tag_candidates(base)
	local just_name = not base or not base:find('.', 1, true)
	local out = {}
	for _, name in ipairs(self._unpicked) do
		out[#out + 1] = { text = name, rate = just_name and name:match '[^.]*$' or name }
	end
	return out
end

---Drive both panes from the input: the pool rates the unpicked fields (idle
---shows the whole ground), the picked pane filters its criteria alongside.
function M:_apply_filter()
	self.completion:update(self.text)
	self:_render_sort_by()
end

---The picked criteria filtered by the input; the rating matches the pool's. A code input
---(`name:code`) rates by the name alone: the pane is the edit's target, the code must not hide its line.
function M:_render_sort_by()
	local base = self.text:match '^%s*([%w.]*)%s*:' or self.text
	if base == '' then
		-- set_lines clamps the cursor; consecutive drops walk down
		self.sort_by.lines = self._criteria
		return
	end
	local just_name = not base:find('.', 1, true)
	local out = {}
	for _, name in ipairs(self._criteria) do
		local cand = just_name and name:match '[^.]*$' or name
		if flt.rate(base, cand, false) then out[#out + 1] = name end
	end
	-- set_lines clamps the cursor; consecutive drops walk down
	self.sort_by.lines = out
end

---Parse the input as a `name:code` edit; nil pair when the input carries no code.
---@return string? name
---@return string? code
function M:code_input() return self.text:match '^%s*([%w.]*)%s*:%s*(.-)%s*$' end

---Resolve the criterion a typed code belongs to: an unnamed code lands on
---the cursor's picked criterion, self over an empty pane.
---@param name string
---@return string
function M:_code_target(name) return #name > 0 and name or self.sort_by.lines[self.sort_by.line] or 'self' end

---@private
---Evaluate the typed code input live, like the filter mode applies its lines. An input that is
---no code, does not compile, or fails the worst-case values constrains nothing: the last-good preview stands.
function M:_preview_input()
	local name, code = self:code_input()
	if not code or #code == 0 then return end
	local xf, err = S.make_runnable(code, { 'self' })

	if xf then
		local target = self:_code_target(name)
		err = worst_case(target, xf)
		if not err then
			-- the preview takes only a transform that passed the worst-case
			-- values: a refused one keeps the last-good preview standing
			self._preview = { name = target, xf = xf }
			self:_apply()
			return
		end
	else
		err = 'Comparator err:\n' .. err
	end

	-- the input renders on the status: the error must not clobber it
	sai.notify(err, nil, 'bottomright')
end

---Push the current criteria into the imagelist. The comparator first proves itself on the
---current entry against itself (metadata loaded or not): a throw or a self-order funnels to the side-notify, the order stands.
---@return boolean false when the criteria did not take: the code refused, or the setter rolled the order back
function M:_apply()
	local fn = self:sort_fn()
	local cur = fn and current_entry()
	if cur then
		local ok, res = pcall(fn, cur, cur)
		if not ok then
			-- the runnable's location adds nothing over the prefix
			local msg = tostring(res):gsub('^runnable:%d+: ', '')
			sai.notify(('Sort code: %s'):format(msg), nil, 'bottomright')
			return false
		end
		if res then -- a self-order breaks table.sort with a cryptic message
			sai.notify('Sort code: not a comparison (a < a holds)', nil, 'bottomright')
			return false
		end
	end
	l.order = fn or 'none'
	-- the setter notifies a throw itself and restores the old order: the
	-- get returning anything else means the new one never took
	return l.order == (fn or 'none')
end

---Add the criterion `name` as the next sort criterion; it drops from the pool.
---An already-picked `name` only takes the new transform, its place and direction stand.
---@param name string
---@param dir? 1|-1 default 1 (ascending)
---@param xf? fun(self:unknown):unknown value a `name:code` criterion compares, `self` is the name's value (the image itself for the `self` key)
---@param src? string the code as typed, recalled into the input by Ctrl+p
---@return boolean false when the new order did not take
function M:add_criterion(name, dir, xf, src)
	if not name then return false end
	if xf then
		self._code[name] = xf
		self._code_src[name] = src
	end
	if self._dir[name] then
		-- picked: only the code changes; the pane paints the code too,
		-- so the cached row must refresh with the new source
		self:_render_sort_by()
		return self:_apply()
	end
	self._criteria[#self._criteria + 1] = name
	self._dir[name] = dir or 1
	self:_refresh_lists()
	return self:_apply()
end

---Accept the candidate under the completion cursor (or `item`), else an input of `name:code`
---(the code sees the name's value as `self`, the images for a `self` line) after the worst-case check; then clear the input.
---@param dir 1|-1
---@param item completion_item?
function M:_accept(dir, item)
	local name, code = self:code_input()
	if code and #code > 0 then
		local target = self:_code_target(name)
		local xf, err = S.make_runnable(code, { 'self' })
		if not xf then
			sai.notify(('Sort code: %s'):format(err), nil, 'bottomright')
			return
		end
		err = worst_case(target, xf)
		if err then
			sai.notify(err, nil, 'bottomright')
			return
		end
		-- the order setter notifies a throwing transform itself and rolls
		-- the order back: the code stays in the input for another pass
		if self:add_criterion(target, dir or 1, xf, code) then
			self._preview = false -- the committed criterion replaces the preview
			self.text = ''
		end
		return
	end

	item = item or self.completion.lines[self.completion.line]
	local n = item and (item.text or item)
	if not n then return end
	self:add_criterion(n, dir or 1)
	self.text = ''
end

---Remove the sort criterion `name`; the field returns to the pool.
---@param name string
function M:remove_criterion(name)
	for i, k in ipairs(self._criteria) do
		if k == name then
			table.remove(self._criteria, i)
			self._dir[name] = nil
			self._code[name] = nil
			self._code_src[name] = nil
			self:_refresh_lists()
			self:_apply()
			return
		end
	end
end

---Flip the direction of the sort criterion `name`; the field keeps its place.
---@param name string
function M:flip_criterion(name)
	if self._dir[name] == nil then return end
	self._dir[name] = -self._dir[name]
	-- the paint closure reads the direction: re-render picks the arrow up
	self:_render_sort_by()
	self:_apply()
end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then
		-- sortable fields: list fields plus loaded exif tags
		local tags = { 'index', 'path', 'size', 'mtime', 'mark' }
		local seen = {} ---@type {[string]:true}
		-- a meta key equal to a list field must not duplicate it
		for _, t in ipairs(tags) do
			seen[t] = true
		end
		for _, e in ipairs(l.get(true)) do
			for k in pairs(e.meta) do
				if not seen[k] then
					seen[k] = true
					tags[#tags + 1] = k
				end
			end
		end
		table.sort(tags)

		self._prev_sort = l.order
		self._all_tags = tags
		-- the panes come up below the mode: their records land under the
		-- mode's, so the corner display lists them under it
		self.completion.enabled = true
		self.sort_by.enabled = true
		M.super.set_enabled(self, val)
		self:_refresh_lists()
	else
		-- the verdict is a plain protected field, readable here
		-- abort restores the entry sort and drops the picks with it; a
		-- confirm keeps them for the next entry, like the filter mode
		if self._verdict == -1 then
			l.order = self._prev_sort
			self._criteria = {}
			self._dir, self._code, self._code_src = {}, {}, {}
		end
		self._preview = false -- the typed preview never survives the close
		self.completion.enabled = false
		self.sort_by.enabled = false
		M.super.set_enabled(self, val)
	end

	return false
end

return M
