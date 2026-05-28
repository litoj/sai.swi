---@module 'swi.api.mode_text'

local U = require 'swi.lib.utils'
local e = require 'swi.api.eventloop'

---@class swi.api.mode_text.base
---@field super swayimg_appmode|swayimg.viewer
---@field _api_name appmode_t

---@class swi.api.mode_text: swi.api.mode_text.base, mode_base.text
---@field _tracked {[block_position_t]:mode_text.tracker}|false
local M = {}

---@param self swi.api.mode_text.base
---@return mode_base.text
function M.new(self)
	---@diagnostic disable: inject-field
	self._path = ('swi.%s.text'):format(self._api_name)
	self._tracked = false
	---@diagnostic disable-next-line: return-type-mismatch
	return setmetatable(self, M)
end

---@class mode_text.tracker
---@field [integer] extended_text_template
---@field dynvar {[string]:integer}
---@field processed string[]

---@param img swayimg.image|swayimg.entry
local function replace_exif_vars(line, img)
	for var, path in line:gmatch '({([A-Z][A-Za-z0-9.]+)})' do
		path = U.format_exif(img.meta, path) -- format the value
		line = path and line:gsub(var, path)
	end
	return line
end

local function replace_swi_vars(line, vars, ev)
	if ev then
		line = line:gsub(('{%s}'):format(ev.match), U.to_pretty_str(ev.data))
		if not line or #vars == 1 then return line end
	end

	-- process all other variables
	for var, path in line:gmatch '({swi%.([a-z0-9._]+)})' do
		local val = swi
		for key in path:gmatch '[^.]+' do
			val = val[key]
			if type(val) == 'function' then val = val() end
			if val == nil then return end
		end
		line = line:gsub(var, U.to_pretty_str(val))
	end
	return line
end

local function generate_exif_updater(line)
	return function(img) return replace_exif_vars(line, img) or '' end
end

local function generate_var_updater(line, varpaths)
	return {
		event = 'OptionSet',
		pattern = varpaths,
		callback = function(ev) return replace_swi_vars(line, varpaths, ev):gsub('{', '{{') or '' end,
	}
end

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

---@param tracker mode_text.tracker
---@param img swayimg.image
local function render_on_img(tracker, api, placement, img)
	local p = tracker.processed
	for i, line in pairs(tracker) do
		if i ~= 'processed' then render_hook(p, i, line, img) end
	end
	api.set_text(placement, p)
end

local _roi = render_on_img
e.subscribe {
	event = 'OptionSet',
	pattern = 'swi.text.enabled',
	callback = function(ev)
		render_on_img = ev.data and _roi or function() end
		if ev.data and swi.initialized then
			local smt = swi[swi.mode].text
			for placement, config in pairs(smt._tracked) do
				render_on_img(config, smt.super, placement, U.lazy(smt.super.get_image))
			end
		end
	end,
}

local primed -- for temporarily blocking rendering until swi is loaded
---@param self swi.api.mode_text
local function initialize(self)
	local tracked = {}
	self._tracked = tracked

	if not swi.initialized then -- ensure we don't try to render before app has initialized
		if not primed then
			primed = true
			render_on_img = function() end
		end

		e.subscribe {
			event = 'SwiEnter',
			once = true,
			callback = function()
				render_on_img = _roi
				for placement, config in pairs(tracked) do
					render_on_img(config, self.super, placement, U.lazy(self.super.get_image))
				end
			end,
		}
	end
end

---@param placement block_position_t
function M:__newindex(placement, x)
	self['_' .. placement] = x
	local group = ('%s.dyntext.%s'):format(self._api_name, placement)

	if self._tracked and self._tracked[placement] then e.unsubscribe { group = group } end

	local new_tr = {} -- fn register
	local processed = {}
	local has_hooks = false
	for i, v in pairs(x) do -- find all custom templates
		-- check for a custom template implementation and replace it with the correct generator
		if type(v) == 'string' then
			local varpaths = {}
			for path in v:gmatch '{(swi%.[a-z0-9._]+)}' do
				varpaths[#varpaths + 1] = path
			end

			if #varpaths > 0 then -- dynamic variables
				v = generate_var_updater(v, varpaths)
			elseif v:find '[^{]{[A-Z]' or v:find '^{[A-Z]' then -- exif variables
				v = generate_exif_updater(v)
			end
		end

		-- register the generators and normal lines to be ready to render and update
		if type(v) == 'table' then ---@cast v mode_base.text.dyntext
			local cfg = U.soft_copy(v)
			cfg.callback = function(...)
				render_hook(processed, i, v.callback, ...)
				self.super.set_text(placement, processed)
			end
			cfg.group = group
			cfg.mode = self._api_name
			e.subscribe(cfg)

			-- load the default value
			render_hook(processed, i, v.callback, nil)
			has_hooks = true
		elseif type(v) == 'function' then
			new_tr[i] = v
		else
			processed[i] = v
		end
	end

	if next(new_tr) or has_hooks then
		if not self._tracked then initialize(self) end

		if next(new_tr) then -- update on image change only if functions are in use
			e.subscribe {
				event = 'ImgChanged',
				pattern = self._api_name,
				callback = function(ev) render_on_img(new_tr, self.super, placement, ev.data) end,
			}
		else
			e.unsubscribe { event = 'ImgChanged', pattern = self._api_name, group = group }
		end

		new_tr.processed = processed
		self._tracked[placement] = new_tr
		if swayimg.get_mode() == self._api_name then
			render_on_img(new_tr, self.super, placement, U.lazy(self.super.get_image))
		end
	else
		if self._tracked then self._tracked[placement] = nil end
		self.super.set_text(placement, x)
	end
end

function M.__index(self, idx) return rawget(self, '_' .. idx) end

return M
