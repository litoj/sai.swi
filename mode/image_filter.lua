---@module 'sai.mode.image_filter'

local U = require 'sai.lib.utils'
local flt = require 'sai.lib.filter'
local selector = require 'sai.mode.selector'
local completion = require 'sai.mode.completion'
local l = sai.imagelist
local binds = require 'sai.binds'

---@alias imgmeta {out:string,filtered_idx:integer,[string]:string|number}|swayimg.image

-- TODO: allow marking matching files instead
---Live image search; confirm applies the filter, Ctrl+j/k walk the matches.
---@class sai.mode.image_filter: sai.mode.editor
---@field selected_pos integer the cursor in the filtered list, 0 when it is empty
---@field private _flt sai.lib.filter<swayimg.image>
local M = {
	super = require 'sai.mode.editor',
	_path = 'sai.mode.image_filter',
	_prompt = 'Filter:',
	_location = 'topleft',

	-- Public, changeable at any time
	update_imagelist_on_confirm = true,
	live_imagelist = true,
	---@type boolean|sai.mode.selector<string> list of the filtered items you can use to switch between filtered images (false to disable)
	results_list = true,
	keep_one_image = false, --- Mainline swayimg cannot show text on an empty list -> workaround >:/
	---@type false|'i'|true|sai.mode.completion 'i' ignores case, can be changed via c.ignore_case
	completion = true,
	---@type number|false Fuzzy path filter; gap tolerance in word-length %.
	default_filter = 0,

	-- Private config
	_images = {}, ---@type {[string]:imgmeta}	every image, keyed by path, with its rendered list form
	_imagelist = {}, ---@type imgmeta[] original imagelist with preserved order
	_filtered = {}, ---@type {[string]:imgmeta} set of filtered images
	_ordered_filtered_paths = {}, ---@type string[]
	---@type {[string]:boolean}
	_loaded_tags = { index = true, path = true, size = true, mtime = true, mark = true },
	_snapshot = {}, ---@type string[] every image, in the order it last stood in the app list
}

setmetatable(M, { __index = M.super })

---@return sai.mode.image_filter
function M:new()
	U.new_object(self, M)

	-- the generic engine: how to read a variable off an image entry
	---@type string? `val` of the failing comparison, for the error report
	local val
	self._flt = flt.new {
		get = function(img, tag)
			val = tag == 'self' and img or img[tag]
			return val
		end,
		coerce = U.parse_exif_val,
		default_var = 'path',
		default_filter = self.default_filter,
	}
	self._err_val = function() return val end

	M.super.new(self)

	-- the machinery rides the filter's tree (shared: none of it toggles
	-- on its own)
	if self.results_list then
		self.results_list = selector.new {
			_path = self._path .. '.results_list',
			sai = self.sai,
			_location = 'bottomleft',
			_max_height = 10,
			_scroll_ahead = 2,
			component = true,
			-- the position rides the live cursor: the stored title
			-- stays the default one, empty list counts zero
			title_fmt = function(s, title, page_block)
				---@cast s sai.mode.selector<string>
				local pos = #s.lines > 0 and s.line or 0
				local head = ('%s %d/%d'):format(title:gsub('\t$', ''), pos, #s.lines)
				if not page_block then return head end
				return head .. '\t' .. page_block
			end,
		}
		-- the wheel walks the matches: the cursor lands on the image,
		-- the same path the Ctrl+j/k binds take
		self.results_list.move = function(_, delta)
			if #self._ordered_filtered_paths == 0 then return end
			self:set_selected_pos(self:get_selected_pos() + delta)
		end
	end
	self.completion = completion.new {
		_path = self._path .. '.completion',
		sai = self.sai,
		target = self,
		ignore_case = self.completion == 'i',
		source = function(base)
			local just_name = not base:find('.', 1, true)
			local out = {}
			for k in pairs(self._loaded_tags) do
				out[#out + 1] = { text = k, rate = just_name and k:match '[^.]*$' or k }
			end
			return out
		end,
	}

	-- browsing outside the list follows: the cursor moves to the image
	-- the app landed on
	self.sai.eventloop.subscribe {
		event = 'ImgChanged',
		callback = function() self:_sync_cursor() end,
	}

	if not self.component then binds.image_filter(self) end

	return self
end

local HOME = os.getenv 'HOME'

---Define your custom rendering of long filenames
---@param x swayimg.image|swayimg.entry
---@return string
function M:render_item(x)
	---@diagnostic disable: cast-local-type
	x = x.path:gsub(HOME, '~', 1) -- take first letter of each word in the path and the full filename
	return x:match('.*/'):gsub('([a-zA-Z])[a-z0-9]+', '%1') .. x:match '[^/]+$'
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

---@protected
---Parse condition line; resolve tags, steer completion.
---@param line string
---@param partial boolean another line typing; keep its menu
---@return filter.condition<swayimg.image>?
---@return string? err rejection reason, already reported via sai.notify
function M:make_filter(line, partial)
	self._flt.default_filter = self.default_filter -- live config
	local cond, err = self._flt:parse(line)
	if err then
		sai.notify(err)
		return nil, err
	end
	if not cond then return end -- empty line

	if cond[1] == self._flt.default_var then -- operator-less: complete the tag being typed
		-- defer the path filter only while a tag completes and the match
		-- would anyway narrow to nothing: a useful match keeps filtering
		local base = line:match '^%s*(.-)%s*$'
		if self:_suggest(base) > 0 and not self:_matches_any(cond) then return end
	else -- already with a valid tag -> no completions for it
		if not partial then self:_suggest '' end
		if cond[1] ~= 'self' then
			local tag = self:_load_tag(cond[1])
			if not tag then return end
			cond[1] = tag
		end
	end
	return cond
end

---@private
---@param base string?
---@return integer #matching tag candidates (0 when completion is off)
function M:_suggest(base)
	if not self.completion then return 0 end
	return self.completion:update(base)
end

---@private
---A filter that would narrow to nothing offers nothing over the completion menu.
---@param cond filter.condition<swayimg.image>
---@return boolean
function M:_matches_any(cond)
	for _, img in ipairs(self._imagelist) do
		if self._flt:apply(cond, self._images[img.path]) then return true end
	end
	return false
end

---@private
---Keep one image back when the update would empty the list.
---@param adds string[]
---@param removes string[]
function M:_update_live_list(adds, removes)
	if self.keep_one_image and #adds == 0 then
		local removed = {}
		for _, path in ipairs(removes) do
			removed[path] = true
		end
		local live = l.get()
		local survives = false
		for _, entry in ipairs(live) do
			if not removed[entry.path] then
				survives = true
				break
			end
		end
		if not survives and #live > 0 then
			local current = l.get_current().path
			l.clear()
			l.add { current }
			return
		end
	end
	l.remove(removes)
	l.add(adds)
end

---@protected
function M:on_text_changed()
	-- a partial line's menu must survive complete lines: prescan the text
	local partial = false
	for _, line in ipairs(self.lines) do
		if #line > 0 then
			local cond = self._flt:parse(line)
			if cond and cond[1] == self._flt.default_var then
				partial = true
				break
			end
		end
	end

	---@type filter.condition<swayimg.image>[]
	local filters = {}
	for _, line in ipairs(self.lines) do
		if #line > 0 then
			local cfg, err = self:make_filter(line, partial)
			-- an invalid line (or a fragment too short to matter) constrains
			-- nothing: report the error and keep the other lines filtering
			if not err and cfg and #line > 2 then filters[#filters + 1] = cfg end
		end
	end

	local of = self._filtered
	local nf = {}
	local lines = {}
	local ordered_filtered_paths = {}
	local ok, err = pcall(function()
		for _, img in ipairs(self._imagelist) do -- to keep correct order of filtered output
			img = self._images[img.path]
			local ok = true
			for _, cfg in ipairs(filters) do
				if not self._flt:apply(cfg, img) then
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
	if not ok then
		sai.notify(('Error comparing %q:\n%s'):format(self._err_val(), (err or ''):gsub('^.-:%d:', '')))
		return
	end

	self._ordered_filtered_paths = ordered_filtered_paths
	self._filtered = nf

	-- the cursor lands on the current image, so it needs the ordered paths
	if self.results_list then
		self.results_list.lines = lines
		self:_sync_cursor()
	end

	if self.live_imagelist then
		-- the deltas follow _imagelist's order; hash order would shuffle
		-- the live list differently on every keypress
		local adds, removes = {}, {}
		for _, entry in ipairs(self._imagelist) do
			local p = entry.path
			if nf[p] and not of[p] then adds[#adds + 1] = p end
			if of[p] and not nf[p] then removes[#removes + 1] = p end
		end
		-- an empty match set empties the list (swayimg can show an empty list)
		self:_update_live_list(adds, removes)
	end
end

---@protected
---@type fun(self: sai.mode.image_filter, idx: integer?):boolean
-- always false: a virtual field (the getter reads the live cursor), the
-- backer must neither store a backing option nor fire one for it
function M:set_selected_pos(idx)
	if idx == nil or not self._enabled then return false end
	if #self._ordered_filtered_paths == 0 then
		sai.notify 'No matching images'
		return false
	end

	if self.results_list then
		idx = math.max(1, math.min(#self.results_list.lines, idx))
		self.results_list.line = idx
	end

	local path = self._ordered_filtered_paths[idx]

	-- navigate straight to the selection, never via the current image;
	-- the app mode is always one of viewer/gallery/slideshow, all with go
	---@diagnostic disable-next-line: undefined-field
	sai[sai.mode].go(path)

	return false
end

---The cursor sits on the image the app displays, when it is a match:
---on the first filter after the enable, and on every ImgChanged.
function M:_sync_cursor()
	if not self.results_list then return end
	local cur = l.get_current().path
	for i, p in ipairs(self._ordered_filtered_paths) do
		if p == cur then
			if i ~= self.results_list.line then self.results_list.line = i end
			return
		end
	end
end

---@protected
---The mode's line in the filtered list (never the current image).
function M:get_selected_pos()
	if not self.results_list then return 0 end
	local items = self.results_list.lines
	return #items > 0 and self.results_list.line or 0
end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return false end

	if val then
		-- the machinery comes up below the mode: its records land under
		-- the filter's, so the mode's corner display already lists them
		if self.results_list then self.results_list.enabled = true end
		if self.completion then self.completion.enabled = true end

		M.super.set_enabled(self, true)

		local imap = self._images
		local ilist = l.get(true) ---@type imgmeta[] (the meta arrives loaded)
		local tmap = self._loaded_tags
		for i, img in ipairs(ilist) do
			local cached = imap[img.path]
			if cached then -- keep the rendered representation, refresh the index
				cached.index = i
				ilist[i] = cached
			else
				imap[img.path] = img
				img.out = self:render_item(img) -- load representations of all items
				for k in pairs(img.meta) do
					tmap[k] = false -- TODO: move to cpp
				end
			end
		end
		self._filtered = imap

		-- the engine runs over a copy of the app list as it stands: the
		-- filter follows its actual order, but removals splice the cached
		-- list in place, so the baseline must stand apart from it
		self._imagelist = { unpack(ilist) }

		-- the snapshot: the app order first, the images outside the app list
		-- keep the order they last stood in (restores hand it back wholesale)
		local listed, snapshot = {}, {}
		for _, img in ipairs(ilist) do
			listed[img.path] = true
			snapshot[#snapshot + 1] = img.path
		end
		for _, path in ipairs(self._snapshot) do
			if not listed[path] then snapshot[#snapshot + 1] = path end
		end
		self._snapshot = snapshot

		if not sai.gallery.pstore then
			sai.gallery.pstore_path = '/tmp/sai-filter/'
			sai.gallery.pstore = true
		end

		-- an emptied app list cannot seed a remake: hand the whole known set
		-- back first, the text filter then narrows it again
		if self.live_imagelist and #ilist == 0 then l.add(self._snapshot) end
		self:on_text_changed()

		-- drop what the filter excludes (the re-seed refilled the list)
		if self.live_imagelist and #self._ordered_filtered_paths > 0 then
			local removes = {}
			for _, path in ipairs(self._snapshot) do
				if not self._filtered[path] then removes[#removes + 1] = path end
			end
			self:_update_live_list({}, removes)
		end
	else
		-- the menus sit above the input layer on the text stack, so pop them first
		if self.completion then self.completion.enabled = false end
		if self.results_list then self.results_list.enabled = false end

		if self.live_imagelist then
			if self._verdict == 1 and self.update_imagelist_on_confirm then
				-- a permanent confirm: the filtered list stands, nothing returns
			else
				-- escape/non-permanent: hand the whole snapshot back; the
				-- api skips the paths already listed
				l.add(self._snapshot)
			end
		elseif self._verdict == 1 and self.update_imagelist_on_confirm then
			local removes = {}
			for _, path in ipairs(self._snapshot) do
				if not self._filtered[path] then removes[#removes + 1] = path end
			end
			l.remove(removes)
		end

		if self._verdict == -1 then
			self._filtered = {} -- text was already removed so filtered files should be too
			self._ordered_filtered_paths = {}
			if self.results_list then self.results_list.lines = {} end
			if self.completion then self.completion.lines = {} end
		end

		M.super.set_enabled(self, false)
	end

	return false
end

return M
