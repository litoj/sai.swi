---@diagnostic disable: invisible
---@module 'swi.mode.filter'

local U = require 'swi.lib.utils'
local pager = require 'swi.lib.pager'
local l = swi.imagelist
local binds = require('swi.binds').filter

-- TODO: completion in the bottom right
-- TODO: make filter list more configurable for general-purpose filtering

---@alias imgmeta {out:string,filtered_idx:integer,[string]:string|number}|swayimg.image

---A live-updating filter mode for image search.
---Each line of input is a condition: `<var><op><val>`
---Confirmation jumps to the first matching image.
---@class swi.mode.filter: swi.mode.input
---@field list_pager swi.lib.pager viewer of the filtered items
---@field completion swi.lib.pager
---@field selected_pos integer the index of the current filtered image or 0 for no match
local M = {
	super = require 'swi.mode.input',
	_path = 'swi.mode.filter',
	_prompt = 'Filter:\r',
	_location = 'topleft',
	auto_help = true,

	-- Public, changeable at any time
	reset_on_enable = true, ---Should filter text persist mode disabling
	keep_filtered_on_confirm = true, ---Should imagelist be set to filtered images
	live_imagelist = true, ---Should imagelist be updated with filtering
	live_pager = true, ---Should a pager with the filtered files be displayed
	tag_completion = true, ---Should a pager with completion for the current tag be visible

	-- Private config
	---@type {[string]:imgmeta}
	_filtered = {}, ---@protected
	---@type {[string]:imgmeta}
	_images = {}, ---@protected
	---@type swayimg.entry[]|false
	_original_list = false, ---@protected
	---@type {[string]:true} list of tags that have been loaded and evaluated
	_loaded_tags = {}, ---@protected
	---@type imgmeta[]
	_imagelist = {}, ---@protected
}

setmetatable(M, { __index = M.super })

---@return swi.mode.filter
function M:new()
	U.new_object(self, M)
	---@diagnostic disable-next-line: missing-fields
	self.list_pager = pager.new {
		_title = 'Matching images:\t',
		_path = self._path .. '.list_pager',
		_location = 'bottomleft',
		_max_height = 10,
	}
	---@diagnostic disable-next-line: missing-fields
	self.completion = pager.new {
		_title = 'Matching tags:\t',
		_path = self._path .. '.completion',
		_location = 'bottomright',
		_max_height = 10,
	}
	M.super.new(self)
	binds(self)

	return self
end

local HOME = os.getenv 'HOME'

---Define your custom rendering of long filenames
---@param x swayimg.image|swayimg.entry
---@return string
function M:render_item(x)
	---@diagnostic disable-next-line: cast-local-type
	x = x.path:gsub(HOME, '~', 1) -- take first letter of each word in the path and the full filename
	return x:match('.*/'):gsub('([a-zA-Z])[a-z0-9]+', '%1') .. x:match '[^/]+$'
end

---@private
---@param tag string
function M:_load_tag(tag)
	if self._loaded_tags[tag] or select(2, next(self._images))[tag] ~= nil then return end

	local val
	for _, i in pairs(self._images) do
		if tag:find('.', 0, true) then
			val = i.meta[tag]
		else
			val = i.meta['Exif.Photo.' .. tag] or i.meta['Exif.Image.' .. tag]
		end

		if val then
			local a, b = tag:match '^(%-?[0-9 ]+)/([0-9][0-9 ]*)$'
			if a then
				a = a:gsub(' ', ''):gsub('^0+(.)', '%1')
				b = b:gsub(' ', ''):gsub('^0+(.)', '%1')
				local x, y = tonumber(a), tonumber(b)
				i[tag] = x / y
			else
				i[tag] = tonumber(val) or val
			end
		end
	end

	self._loaded_tags[tag] = true
end

---Collect field names from the current image that contain `fragment`.
---Looks at top-level entry fields and all `.meta` keys.
---Results are sorted by match position (closer to start = higher priority).
---@param fragment string partial tag/field name to search for
function M:complete(fragment)
	if not self.tag_completion then return end
	if not fragment or fragment == '' then
		self.completion.lines = {}
		return
	end

	local img = l.get_current()
	if not img then return end

	fragment = fragment:lower()
	local hits = {} ---@type {[1]:integer,[2]:string}[]

	-- Top-level entry fields (path, format, width, height, etc.)
	for k, v in pairs(img) do
		if type(v) ~= 'table' and type(k) == 'string' then
			local pos = k:find(fragment, 1, true)
			if pos then hits[#hits + 1] = { pos, k } end
		end
	end
	---@diagnostic disable-next-line: undefined-field
	for k, v in pairs(img.meta or {}) do
		if type(v) ~= 'table' then
			local pos = k:find(fragment, 1, true)
			if pos then
				hits[#hits + 1] = { pos, k }
				if #hits >= self.completion.page_size then break end
			end
		end
	end

	table.sort(hits, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)

	local out = {}
	for _, h in ipairs(hits) do
		out[#out + 1] = h[2]
	end

	self.completion:bulk_change(function(p)
		p.title = ('Matching tags: %d\t'):format(#out)
		p.lines = out
	end)
end

---@return {[1]:string,[2]:fun(raw:string):boolean}?
function M:make_filter(line)
	line = line:match '^%s*(.-)%s*$'
	if line == '' then return end

	local tag, val, oper
	for _, op in ipairs { '!=', '<=', '>=', '<', '>', '=', '!', ':' } do
		tag, val = line:match('^%s*([0-9A-Za-z]*)%s*' .. op .. '%s*(.-)%s*$')
		if tag and #tag > 0 then
			oper = op
			break
		end
	end
	if not oper then
		self:complete(line)
		return swi.text.set_status 'Missing comparison operator'
	elseif #tag == 0 and oper ~= ':' then
		return swi.text.set_status 'Tag can be omitted only with the ":" (code) operator'
	elseif #val == 0 and oper ~= '!' then
		return swi.text.set_status 'Value can be omitted only with the "!" (negation) operator'
	end
	self.completion.lines = {}

	local num_val = tonumber(val) or val

	-- Comparison functions: each takes the raw string value and returns bool
	---@type {[string]:(fun(val):boolean)|fun():((fun(val):boolean)?)}
	local cmp = {
		['<'] = function(r) return r < num_val end,
		['<='] = function(r) return r <= num_val end,
		['>'] = function(r) return r > num_val end,
		['>='] = function(r) return r >= num_val end,
		['!'] = function(x) return not x end,
		['!='] = function(r) return r ~= val end,
		['='] = function()
			val = '^' .. val .. '$'
			return function(r) return r:find(val) end
		end,
		[':'] = function()
			local cb, err = loadstring(val:find('return', 1, true) and val or 'return ' .. val)
			if not cb or err then return swi.text.set_status(err) end
			if #tag == 0 then tag = 'self' end
			return function(r)
				_G[tag] = r
				err = cb()
				_G[tag] = nil
				return err
			end
		end,
	}

	oper = cmp[oper]
	oper = debug.getinfo(oper, 'u').nparams == 1 and oper or oper()
	if oper then
		if tag ~= 'self' then self:_load_tag(tag) end
		return { tag, oper }
	end
end

---@protected
function M:on_text_change()
	---@type {[1]:string,[2]:fun(raw:string):boolean}[]
	local filters = {}
	for _, li in ipairs(self:get_line_info()) do
		if #li.line > 0 then
			local cfg = self:make_filter(li.line)
			if not cfg then return end

			filters[#filters + 1] = cfg
		end
	end

	local of = self._filtered
	local nf = {}
	local lines = {}
	local ok, err = pcall(function()
		for _, img in ipairs(self._imagelist) do -- to keep correct order of filtered output
			img = self._images[img.path]
			local ok = true
			for _, cfg in ipairs(filters) do
				if not cfg[2](cfg[1] == 'self' and img or img[cfg[1]]) then
					ok = false
					break
				end
			end

			if ok then
				nf[img.path] = img
				lines[#lines + 1] = img.out
				img.filtered_idx = #lines
			else
				img.filtered_idx = 0
			end
		end
	end)
	if not ok then return swi.text.set_status(err) end

	self.list_pager:bulk_change(function(p)
		p.lines = lines
		p.title = ('Matching images: %d/%d\t'):format(self:get_selected_pos(), #lines)
	end)

	if self.live_imagelist then
		if not next(nf) then -- ensure there is always at least one image
			local cur = l.get_current().path
			nf[cur] = of[cur]
		end

		for k, _ in pairs(nf) do
			if not of[k] then l.add(k) end
		end
		for k, _ in pairs(of) do
			if not nf[k] then l.remove(k) end
		end
	end

	self._filtered = nf
end

---@protected
function M:set_selected_pos(idx)
	if idx == nil or not self._enabled then return end -- ignore
	if #self.list_pager.lines == 0 then return swi.text.set_status 'No matching images' end

	idx = math.max(1, math.min(#self.list_pager.lines, idx))
	self.list_pager:bulk_change(function(p)
		p.line = idx -- will get rounded to the top line of the last page -> use idx for precission
		p.title = ('Matching images: %d/%d\t'):format(idx, #p.lines)
	end)

	local old_img = self._images[l.get_current().path]
	local new_img
	for _, v in pairs(self._filtered) do
		if v.filtered_idx == idx then
			new_img = v
			break
		end
	end

	if swi.mode == 'viewer' then return swi.viewer.open(new_img.path) end

	local oi = self.live_imagelist and old_img.filtered_idx or old_img.index
	local ni = self.live_imagelist and new_img.filtered_idx or new_img.index
	local dir = oi < ni and swi.gallery.go.right or swi.gallery.go.left
	for _ = math.abs(oi - ni), 1, -1 do
		dir()
	end
end

---@protected
---@return integer?
function M:get_selected_pos() return self._images[l.get_current().path].filtered_idx or 0 end

---@param text? string|false
function M:confirm(text)
	if text == false then
		-- restore original imagelist, other situations are handled during disabling
		if self.keep_filtered_on_confirm then
			local fl = self._filtered
			for k, _ in pairs(self._images) do
				if not fl[k] then l.add(k) end
			end
		end
	else
		if not self.selected_pos then self.selected_pos = 1 end
	end

	return M.super.confirm(self, text)
end

function M:set_enabled(val) -- TODO: better handling of mode switching
	if val == self._enabled then return false end

	if val then
		-- Snapshot the full image list before filtering
		if not next(self._images) or not self.keep_filtered_on_confirm then
			local il = {}
			self._images = il
			self._loaded_tags = {}
			self._imagelist = l.get()
			for _, i in pairs(self._imagelist) do
				il[i.path] = i
				---@diagnostic disable-next-line: inject-field
				i.out = self:render_item(i) -- load representations of all items
			end
		end

		if self.reset_on_enable then
			self.text = ''
			self.list_pager.lines = {}
			self.list_pager.title = 'Matching images:\t'
			self.completion.lines = {}
		elseif #self._filtered > 0 then
			local fl = self._filtered
			for k, _ in pairs(self._images) do
				if not fl[k] then l.remove(k) end
			end
		end
	elseif self.live_imagelist and not self.keep_filtered_on_confirm then
		for k, _ in pairs(self._images) do
			if not self._filtered[k] then l.add(k) end
		end
	end

	if self.live_pager or not val then self.list_pager.enabled = val end
	if self.tag_completion or not val then self.completion.enabled = val end
	M.super.set_enabled(self, val)

	return false
end

return M
