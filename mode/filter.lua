---@diagnostic disable: invisible
---@module 'swi.mode.filter'

local U = require 'swi.lib.utils'
local pager = require 'swi.lib.pager'
local exiv2 = require 'swi.lib.exiv2'
local l = swi.imagelist
local binds = require('swi.binds').filter

---@alias imgmeta {out:string,filtered_idx:integer,[string]:string|number}|swayimg.image

-- TODO: allow marking matching files instead
---A live-updating filter mode for image search.
---Each line of input is a condition: `<var><op><val>`
---Confirmation jumps to the first matching image.
---@class swi.mode.filter: swi.mode.input
---@field list_pager swi.lib.pager viewer of the filtered items
---@field completion swi.lib.pager
---@field selected_pos integer the index of the current filtered image or 0 for no match
---@field protected _images {[string]:imgmeta}
---@field private _loaded_tags {[string]:boolean} list of available tags and if they've been loaded
local M = {
	super = require 'swi.mode.input',
	_path = 'swi.mode.filter',
	_prompt = 'Filter:\r',
	_location = 'topleft',
	auto_help = true,

	-- Public, changeable at any time
	update_imagelist_on_confirm = true, ---Should imagelist be set to filtered images
	live_imagelist = true, ---Should imagelist be updated with filtering
	live_pager = true, ---Should a pager with the filtered files be displayed
	---Should a pager with completion for the current tag be visible
	---`'i'` for matching with ignored casing
	tag_completion = true, ---@type false|'i'|true
	---Settings for fuzzy matching agains path when no operator is specified
	---Represents gap tolerance in word length percentage (0=contains, 1= 'abc' -> '…a_b__c…')
	default_filter = 0, ---@type number|false

	-- Private config
	---@type {[string]:imgmeta}
	_filtered = {}, ---@protected
	---@type string[]
	_ordered_filtered_paths = {}, ---@protected
	---@type swayimg.entry[]|false
	_original_list = false, ---@protected
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
	self._images = {}
	self._loaded_tags = { path = true, size = true, mtime = true }
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

---Completion rating function
---@param base string what the user typed
---@param tag string what are we suggesting
---@param rate_start boolean? penalize the distance to first matched char (default=true)
---@param max_penalty integer? at what point to abort matching
---@return integer? penalty - how accurate the match was (lower=better)
function M:rate(base, tag, rate_start, max_penalty)
	local bi = 1
	local ti = 1
	if self.tag_completion == 'i' then tag = tag:lower() end
	local penalty = tag:find(base, 1, true)
	if penalty then
		penalty = (rate_start ~= false and penalty or 0) - #base
	else
		penalty = 0
		if rate_start == false then
			ti = tag:find(base:sub(bi, bi), ti, true)
			if not ti then return end
			bi = bi + 1
		end

		max_penalty = max_penalty or 2147483648
		while bi <= #base do
			local f = tag:find(base:sub(bi, bi), ti, true)
			if not f then return end
			penalty = penalty + f - ti - 1
			if penalty > max_penalty then return end
			ti = f
			bi = bi + 1
		end
	end

	return penalty
end

---@protected
-- TODO: make filter list more configurable for general-purpose filtering
-- TODO: allow using filters to determine order of displayed results (probably a togle per filter)
---@return {[1]:string,[2]:fun(raw:string):boolean}?
function M:make_filter(line)
	line = line:match '^%s*(.-)%s*$'
	if line == '' then return end

	local tag, val, oper
	for _, op in ipairs { '!=', '<=', '>=', '<', '>', '==', '=', '!', ':' } do
		tag, val = line:match('^%s*([0-9A-Za-z.]*)%s*' .. op .. '%s*(.-)%s*$')
		if tag then
			oper = op == '=' and '==' or op
			break
		end
	end
	if not oper then
		self:complete(line)
		return {
			'path',
			self.default_filter == 0 and function(p) return p:find(line, 1, true) end --
				or function(p) return self:rate(line, p, false, math.floor((self.default_filter - 1) * #line)) end,
		}
	elseif #tag == 0 and oper ~= ':' then
		return swi.notify 'Tag can be omitted only with the ":" (code) operator'
	elseif #val == 0 and oper ~= '!' then
		return swi.notify 'Value can be omitted only with the "!" (negation) operator'
	end
	self.completion.enabled = false -- already with valid tag -> no need for completion

	local num_val = U.parse_exif_val(val)

	-- TODO: extract to global config
	-- Comparison functions: each takes the raw string value and returns bool
	---@type {[string]:(fun(val:string|integer):boolean)|fun():((fun(val:string):boolean)?)}
	local cmp = {
		['<'] = function(r) return r and r < num_val end,
		['>'] = function(r) return r and r > num_val end,
		['<='] = function(r) return r and r <= num_val end,
		['>='] = function(r) return r and r >= num_val end,
		['!='] = function()
			val = '^' .. val .. '$'
			return function(r) return not r or not tostring(r):find(val) end
		end,
		['!'] = function(x) return not x end,
		['=='] = function()
			val = '^' .. val .. '$'
			return function(r) return r and tostring(r):find(val) end
		end,
		[':'] = function() -- run code; tag value is set as `self` variable, value defaults to imgmeta
			local cb, err = loadstring(val:find('return', 1, true) and val or 'return ' .. val)
			---@diagnostic disable-next-line: need-check-nil
			if not cb or err then return swi.notify(err:gsub('^.-:%d:', 'Syntax error:')) end
			if not cb or err then return swi.text.set_status(err) end
			if #tag == 0 then tag = 'self' end
			return function(r)
				if not r then return end
				_G.self = r
				err = cb()
				_G.self = nil
				return err
			end
		end,
	}

	oper = cmp[oper]
	oper = debug.getinfo(oper, 'u').nparams == 1 and oper or oper()
	if oper then
		if tag ~= 'self' then tag = self:_load_tag(tag) end
		if tag then return { tag, oper } end
	end
end

---@private
---@param tag string
---@return string? # actual name of the tag
function M:_load_tag(tag)
	local tmap = self._loaded_tags
	tag = tag:find('.', 0, true) and tag
		or (tmap['Exif.Photo.' .. tag] ~= nil and 'Exif.Photo.' .. tag)
		or (tmap['Exif.Image.' .. tag] ~= nil and 'Exif.Image.' .. tag)
		or tag
	if tmap[tag] ~= false then return tmap[tag] and tag end

	for _, i in pairs(self._images) do
		i[tag] = U.parse_exif_val(i.meta[tag])
	end

	tmap[tag] = true
	return tag
end

-- TODO: also use it to create a walkable directory tree / bookmarks etc
-- it would be like <C-n> for list mode, then r for recursive toggle,
-- by default in dir search, enter would add it and remove it

-- TODO: hijack cursor if it moves to a position in the corner
-- TODO: split into it's own module
---@protected
---Collect field names from the current image that contain `fragment`.
---Looks at top-level entry fields and all `.meta` keys.
---Results are sorted by match position (closer to start = higher priority).
---@param base string partial tag/field name to search for
function M:complete(base)
	if not self.tag_completion then return end
	if not base or base == '' then
		self.completion.enabled = false
		return
	end

	local hits = {} ---@type {[1]:integer,[2]:string}[]

	local just_name = not base:find('.', 1, true)
	local rating
	for k in pairs(self._loaded_tags) do
		---@diagnostic disable-next-line: cast-local-type
		rating = self:rate(base, just_name and k:match '[^.]*$' or k)
		if rating then hits[#hits + 1] = { rating, k } end
	end

	table.sort(hits, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)

	local out = {}
	for _, h in ipairs(hits) do
		out[#out + 1] = h[2]
	end

	self.completion:bulk_change(function(p)
		p.title = ('Matching tags: %d\t'):format(#out)
		p.lines = out
		p.enabled = self.tag_completion
	end)
end

local function keys_not_in(map, minus)
	local ret = {}
	for path, _ in pairs(map) do
		if not minus[path] then ret[#ret + 1] = path end
	end
	return ret
end

---@protected
function M:on_text_change()
	if #self._text == 0 then return end

	---@type {[1]:string,[2]:fun(raw:string):boolean}[]
	local filters = {}
	for _, li in ipairs(self:get_lines_info()) do
		if #li.line > 0 then
			local cfg = self:make_filter(li.line)
			if not cfg or #li.line <= 2 then return end

			filters[#filters + 1] = cfg
		end
	end

	local of = self._filtered
	local nf = {}
	local lines = {}
	local ordered_filtered_paths = {}
	local val
	local ok, err = pcall(function()
		for _, img in ipairs(self._imagelist) do -- to keep correct order of filtered output
			img = self._images[img.path]
			local ok = true
			for _, cfg in ipairs(filters) do
				val = cfg[1] == 'self' and img or img[cfg[1]]
				if not cfg[2](val) then
					ok = false
					break
				end
			end

			if ok then
				nf[img.path] = img
				lines[#lines + 1] = img.out
				ordered_filtered_paths[#ordered_filtered_paths + 1] = img.path
				img.filtered_idx = #ordered_filtered_paths
			else
				img.filtered_idx = 0
			end
		end
	end)
	---@diagnostic disable-next-line: need-check-nil
	if not ok then return swi.notify(('Error comparing %q:\n%s'):format(val, err:gsub('^.-:%d:', ''))) end
	-- swi.notify '' -- clear previous error messages if everything went well

	self.list_pager:bulk_change(function(p)
		p.lines = lines
		p.title = ('Matching images: %d/%d\t'):format(self:get_selected_pos(), #lines)
	end)

	if self.live_imagelist then
		if not next(nf) then
			swi.notify 'No matching images.\nSkipping imagelist update!'
			return
		end

		l.add(keys_not_in(nf, of))
		l.remove(keys_not_in(of, nf))
	end

	self._ordered_filtered_paths = ordered_filtered_paths
	self._filtered = nf
end

-- TODO: create pager wrapper that allows marking a particular line -> textbox -> use it by input mode
---@protected
function M:set_selected_pos(idx)
	if idx == nil or not self._enabled then return end -- ignore
	if #self._ordered_filtered_paths == 0 then return swi.text.set_status 'No matching images' end

	idx = math.max(1, math.min(#self.list_pager.lines, idx))
	self.list_pager:bulk_change(function(p)
		p.line = idx -- will get rounded to the top line of the last page -> use idx for precission
		p.title = ('Matching images: %d/%d\t'):format(idx, #p.lines)
	end)

	local old_img = self._images[l.get_current().path]
	local new_img = self._images[self._ordered_filtered_paths[idx]]

	if swi.mode == 'viewer' then return swi.viewer.open(new_img.path) end

	local oi = self.live_imagelist and old_img.filtered_idx or old_img.index
	local ni = self.live_imagelist and idx or new_img.index
	local dir = oi < ni and swi.gallery.go.right or swi.gallery.go.left
	for _ = math.abs(oi - ni), 1, -1 do
		dir()
	end
end

---@protected
---@return integer?
function M:get_selected_pos() return self._images[l.get_current().path].filtered_idx or 0 end

function M:set_enabled(val) -- TODO: better handling of mode switching
	if val == self._enabled then return false end

	if val then
		M.super.set_enabled(self, true)
		-- Snapshot the full image list before filtering
		if not next(self._images) or not self.update_imagelist_on_confirm then
			local timer = U.timer()
			local imap = self._images
			local ilist = l.get() ---@type imgmeta[]
			timer 'Got imagelist'
			exiv2.load_all(ilist)
			timer 'Loaded metadata'
			self._imagelist = ilist
			local tmap = self._loaded_tags
			for i, img in ipairs(ilist) do
				if imap[img.path] then -- update existing entries instead of reloading exif
					img = imap[img.path]
					img.index = i
					ilist[i] = img
				else
					imap[img.path] = img
					img.out = self:render_item(img) -- load representations of all items
					for k in pairs(img.meta) do
						tmap[k] = false
					end
				end
			end
			timer 'Available metadata gathered'
			self._filtered = imap
			self:on_text_change()

			if not swi.gallery.pstore then
				swi.gallery.pstore_path = '/tmp/swi-filter/'
				swi.gallery.pstore = true
			end
		end

		if self.live_imagelist and #self._ordered_filtered_paths > 0 then
			l.remove(keys_not_in(self._images, self._filtered))
		end
	else -- val == false
		if
			self.live_imagelist
			and (not self.confirmed or not self.update_imagelist_on_confirm)
			and #self._ordered_filtered_paths > 0
		then
			l.add(keys_not_in(self._images, self._filtered))
		elseif not self.live_imagelist and self.confirmed and self.update_imagelist_on_confirm then
			l.remove(keys_not_in(self._images, self._filtered))
		end

		if self.confirmed then
			if not self.selected_pos then self.selected_pos = 1 end
		elseif self.confirmed == false then
			self._filtered = {} -- text was already removed so filtered files should be too
			self._ordered_filtered_paths = {}
			self.list_pager.lines = {}
			self.list_pager.title = 'Matching images:\t'
		end

		M.super.set_enabled(self, false)
	end

	if self.live_pager or not val then self.list_pager.enabled = val end
	if self.tag_completion and not val then self.completion.enabled = false end

	return false
end

return M
