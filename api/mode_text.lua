---@module 'sai.api.mode_text'

local U = require 'sai.lib.utils'
local e = require 'sai.api.eventloop'
local utf8 = require 'sai.bridge.utf8'

---@class sai.api.mode_text: mode_base.text
---@field protected super swayimg_appmode|swayimg.viewer
---@field _api_name appmode_t
---@field _armed boolean text hooks currently subscribed
---@field _tracked {[block_position_t]:mode_text.tracker}
---@field _metrics {[block_position_t]:table} the widest rendered line `{cells, kv}`, for the mouse box
local M = {}

---The block width in cells: a tab splits a line into the key and value columns.
---@param lines table<integer,string>
---@return table metrics `{cells:integer, kv:boolean}` the block is as wide as the sum of the
---  column maxima (the app aligns the values after the widest key); characters count as
---  codepoints - a multibyte one renders into a single cell, a bad byte into one fallback;
---  `kv` marks the winner a key/value layout: its columns are two padded pixmaps, the
---  mouse box adds the gap between them
local function longest_line(lines)
	local key, val, plain = 0, 0, 0
	for _, l in pairs(lines) do
		local delim = l:find('\t', 1, true)
		if delim then
			key = math.max(key, utf8.len(l, 1, delim - 1) or delim - 1)
			val = math.max(val, utf8.len(l, delim + 1) or #l - delim)
		else
			plain = math.max(plain, utf8.len(l) or #l)
		end
	end
	local kv = key > 0 or val > 0
	return { cells = math.max(plain, key + val), kv = kv and key + val >= plain }
end

---@param self {super:swayimg_appmode,_api_name:appmode_t}
---@return sai.api.mode_text
function M:new()
	self._tracked = {}
	self._armed = false
	self._metrics = {}
	local mt = setmetatable(self, M)
	-- the construction seeds never pass __newindex: measure them here once
	for _, p in ipairs { 'topleft', 'topright', 'bottomleft', 'bottomright' } do
		local seed = self['_' .. p]
		if seed then self._metrics[p] = longest_line(seed) end
	end
	return mt
end

---@class mode_text.tracker parked block: render state plus resubscribe specs
---@field [integer] fun(img:swayimg.image):(string|string[]?) image-change generators, keyed by line index
---@field dyntext {[integer]:mode_base.text.dyntext} event-based lines; group/mode stamped on arm
---@field processed table<integer,string> rendered lines, keyed by line index

---@param line string template line with one `{Exif.Tag}` hole
---@return fun(img:swayimg.image):string
function M.generate_exif_updater(line)
	local s, e, val = line:find '{([A-Z][A-Za-z0-9.]+)}'
	---@param img swayimg.image
	---@return string
	return function(img)
		local val = U.format_exif(img.meta, val)
		if val then return line:sub(1, s - 1) .. val .. line:sub(e + 1) end
		return ''
	end
end

---@param line string template line with lowercase `{field}` holes
---@return fun(img:swayimg.image):string
function M.generate_img_data_updater(line)
	-- NOTE: technically could match badly if str is like '{{escaped}} {actualvar}'
	-- NOTE: technically if multiple kinds are in the same str, only one will be parsed
	local s, e, val = line:find '{([a-z]+)}'
	---@param img swayimg.image
	---@return string
	return function(img)
		local line, s, e, val = line, s, e, val
		while s do
			val = tostring(img[val])
			line = line:sub(1, s - 1) .. val .. line:sub(e + 1)
			s, e, val = line:find('{([a-z]+)}', s + #val)
		end
		return line
	end
end

---With an event, only its own match plus a single-var fast path.
---@param str string template text
---@param vars string[] sai paths the line reads
---@param ev sai.eventloop.event? triggering OptionSet event, nil for a full render
---@return string? rendered text, nil when a path is missing
local function replace_sai_vars(str, vars, ev)
	if ev then
		local rep = U.to_pretty_str(ev.data)
		if not rep or rep == '' then return '' end
		str = str:gsub(('{%s}'):format(ev.match), rep)
		if #vars == 1 then return str end
	end

	for var, path in str:gmatch '({sai%.([a-z0-9._]+)})' do
		local val = sai
		for key in path:gmatch '[^.]+' do
			val = val[key]
			if val == nil then return end
		end
		str = str:gsub(var, U.to_pretty_str(val))
	end
	return str
end

---@param line string template line with `{sai.path}` holes
---@param varpaths string[] sai option paths the line reads
---@return mode_base.text.dyntext
function M.generate_var_updater(line, varpaths)
	return {
		event = 'OptionSet',
		pattern = varpaths,
		callback = function(ev)
			local x = replace_sai_vars(line, varpaths, ev)
			return x and x:gsub('\n%s*', ' '):gsub('{', '{{') or ''
		end,
	}
end

---Write one hook result into the rendered lines; table results spread over following lines.
---@param processed table<integer,string> rendered lines, keyed by line index
---@param i integer line index the hook owns
---@param hook fun(...)
---@param ... unknown hook arguments: event, image, or nil for the initial call
local function render_hook(processed, i, hook, ...)
	local out = hook(...)
	if type(out) == 'table' then
		i = i - 1
		for j, line in pairs(out) do
			processed[i + j] = line
		end
	elseif out then
		processed[i] = out
	end
end

---@diagnostic disable: invisible

---@param self sai.api.mode_text
---@param tracker mode_text.tracker
---@param placement block_position_t
---@param img swayimg.image
local function render_on_img(self, tracker, placement, img)
	local p = tracker.processed
	for i, line in pairs(tracker) do
		if i ~= 'processed' and i ~= 'dyntext' then render_hook(p, i, line, img) end
	end
	self._metrics[placement] = longest_line(p)
	self.super.text = { [placement] = p }
end

---@diagnostic disable: invisible

---Subscribe one parked block and flush it: the arm-time catch-up.
---@param self sai.api.mode_text
---@param placement block_position_t
local function arm_placement(self, placement)
	local tr = self._tracked[placement]
	if not tr then return end
	local group = ('%s.dyntext.%s'):format(self._api_name, placement)
	for i, spec in pairs(tr.dyntext) do
		local cfg = U.soft_copy(spec)
		cfg.callback = function(...)
			render_hook(tr.processed, i, spec.callback, ...)
			self._metrics[placement] = longest_line(tr.processed)
			self.super.text = { [placement] = tr.processed }
		end
		cfg.group = group
		cfg.mode = self._api_name
		e.subscribe(cfg)
		render_hook(tr.processed, i, spec.callback, nil)
	end

	local has_fns = false
	for k in pairs(tr) do
		if type(k) == 'number' then
			has_fns = true
			break
		end
	end
	if has_fns then
		e.subscribe {
			event = 'ImgChanged',
			pattern = self._api_name,
			group = group,
			callback = function(ev) render_on_img(self, tr, placement, ev.data) end,
		}
	end
	render_on_img(self, tr, placement, U.lazyimg(self.super))
end

do
	local function check_visibility(ev, newmode)
		local self = sai[ev.mode].text ---@type sai.api.mode_text
		local want = sai.initialized and (newmode or ev.mode) == self._api_name and sai.text.enabled
		if want == self._armed then return end
		self._armed = want
		if not self._tracked then return end
		if want then
			for placement in pairs(self._tracked) do
				arm_placement(self, placement)
			end
		else
			for placement in pairs(self._tracked) do
				e.unsubscribe { group = ('%s.dyntext.%s'):format(self._api_name, placement) }
			end
		end
	end

	e.subscribe { event = 'SwiEnter', once = true, callback = check_visibility }
	e.subscribe { event = 'ModeChangedPre', callback = function(ev) check_visibility(ev, ev.data) end }
	e.subscribe { event = 'ModeChanged', callback = check_visibility }
	e.subscribe { event = 'OptionSet', match = 'sai.text.enabled', callback = check_visibility }
	---@diagnostic enable: invisible
end

---Compile a text-block template into tracked render specs, or write it through when static.
---@param placement block_position_t
---@param x extended_text_template[]
function M:__newindex(placement, x)
	self['_' .. placement] = x
	local group = ('%s.dyntext.%s'):format(self._api_name, placement)

	if self._tracked and self._tracked[placement] then e.unsubscribe { group = group } end

	local new_tr = {}
	local specs = {}
	local processed = {}
	local has_hooks = false
	local has_fns = false
	for i, v in pairs(x) do
		if type(v) == 'string' and v:find('{', 1, true) then
			local varpaths = {}
			for path in v:gmatch '{(sai%.[a-z0-9._]+)}' do
				varpaths[#varpaths + 1] = path
			end

			if #varpaths > 0 then
				v = M.generate_var_updater(v, varpaths)
			elseif v:find '[^{]{[A-Z]' or v:find '^{[A-Z]' then
				v = M.generate_exif_updater(v)
			elseif v:find '[^{]{[wh]' or v:find '^{[wh]' then -- allow only width/height
				v = M.generate_img_data_updater(v)
			end
		end

		if type(v) == 'table' then ---@cast v mode_base.text.dyntext
			specs[i] = U.soft_copy(v)
			if self._armed then render_hook(processed, i, v.callback, nil) end
			has_hooks = true
		elseif type(v) == 'function' then
			new_tr[i] = v
			has_fns = true
		else
			processed[i] = v
		end
	end

	if has_fns or has_hooks then
		new_tr.processed = processed
		new_tr.dyntext = specs
		self._tracked[placement] = new_tr
		if self._armed then arm_placement(self, placement) end
	else
		if self._tracked then self._tracked[placement] = nil end
		self._metrics[placement] = longest_line(x)
		self.super.text = { [placement] = x }
	end
end

function M:__index(idx) return rawget(self, '_' .. idx) end

return M
