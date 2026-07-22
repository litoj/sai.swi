---@diagnostic disable: invisible
---@module 'sai.api.viewer'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'
local mode_base = require 'sai.api.mode_base'
local mode_text = require 'sai.api.mode_text'

---@class sai.api.viewer: sai.viewer, sai.api.mode_base
---@field super swayimg.viewer
---@field _last {w:integer,h:integer,x:integer,y:integer}|false
---@field text sai.api.mode_text.base
local M = {
	_scale = false, ---@type number|one_time_scale_t|false
	_default_scale = 'optimal', ---@type default_scale_t
}

---@return sai.viewer.panner
local function new_panner(self)
	local pan
	pan = {
		default_size = 50,
		by = function(x, y)
			local p = self.position
			self.position = { x = p.x - x, y = p.y - y }
		end,
		left = function(p) pan.by(-(p or pan.default_size), 0) end,
		right = function(p) pan.by((p or pan.default_size), 0) end,
		up = function(p) pan.by(0, -(p or pan.default_size)) end,
		down = function(p) pan.by(0, (p or pan.default_size)) end,
	}

	return pan
end

-- TODO: use USR1 to add debounce for repeated presses and viewer.open to then jump to the file
-- directly
---@param api swayimg.viewer
local function new_go(api, api_name)
	return setmetatable({}, {
		__index = function(tbl, idx)
			tbl[idx] = function()
				e.trigger { event = 'ImgChangedPre', mode = api_name, match = api_name, data = U.lazyimg(api) }
				api.open(idx)
			end
			return tbl[idx]
		end,
		__call = function(x)
			e.trigger { event = 'ImgChangedPre', mode = api_name, match = api_name, data = U.lazyimg(api) }
			if type(x) == 'number' then -- direct index
				local list = sai.imagelist.get()
				local img = list[x]
				if not img then
					sai.log('No image at index ' .. x)
					return
				end
				api.open_path(img.path)
			else -- image path
				api.open_path(x)
				e.trigger {
					event = 'OptionSet',
					mode = api_name,
					match = 'sai.imagelist.size',
					data = sai.imagelist.size(),
				}
			end
		end,
	})
end

---@param factor_fn fun(last:lastimg, img:swayimg.image):number
---@return fun(self:sai.api.viewer,x:default_scale_t):string
local function gen_keep(factor_fn)
	return function(self, x)
		---@alias lastimg {w:integer,h:integer,x:integer,y:integer}
		rawset(self, '_last', { w = 0, h = 0, x = 0, y = 0 })
		e.subscribe {
			event = 'ImgChangedPre',
			pattern = self.text._api_name,
			callback = function(ev)
				if self._default_scale ~= x then return true end

				local img = ev.data or error()
				---@diagnostic disable-next-line: assign-type-mismatch
				self._last = self.super.get_position() ---@type lastimg
				self._last.w = img.width
				self._last.h = img.height
			end,
		}
		e.subscribe {
			event = 'ImgChanged',
			pattern = self.text._api_name,
			callback = function(ev)
				if self._default_scale ~= x then return true end

				local last = self._last
				if not last then return end -- adjust only when ImgChangedPre was fired
				---@diagnostic disable-next-line: assign-type-mismatch
				self._last = false

				self.super.set_abs_scale(self.super.get_scale() * factor_fn(last, ev.data), 0, 0)
				self.super.set_abs_position(last.x, last.y)
			end,
		}

		return 'keep'
	end
end

---@type {[default_scale_t|integer]:fun(self:sai.api.viewer,x:default_scale_t):string?}
M.custom_scale_handlers = {
	keep_width = gen_keep(function(last, img) return last.w / img.width end),
	keep_height = gen_keep(function(last, img) return last.h / img.height end),
	keep_size = gen_keep(function(last, img) return (last.w + last.h) / (img.width + img.height) end),
	keep_fit = gen_keep(function(last, img) return math.min(last.w / img.width, last.h / img.height) end),
	keep_fill = gen_keep(function(last, img) return math.max(last.w / img.width, last.h / img.height) end),
}

---@param x default_scale_t
function M:set_default_scale(x)
	local handled
	if M.custom_scale_handlers[x] then handled = M.custom_scale_handlers[x](self, x) end
	if not handled then
		for _, f in ipairs(M.custom_scale_handlers) do
			handled = f(self, x)
			if handled then break end
		end
		if not handled then handled = x end
	end

	self._raw_default_scale = handled
	self.super.set_default_scale(handled)
end

function M:set_scale(x)
	if type(x) == 'string' then
		self.super.set_fix_scale(x)
	else
		self.super.set_abs_scale(x)
	end
end
function M:get_scale()
	if self._scale then return self._scale end
	if self._raw_default_scale == 'keep' then return self.super.get_scale() end
	return self._default_scale
end

function M:set_position(x)
	if type(x) == 'string' then
		self.super.set_fix_position(x)
	else
		self.super.set_abs_position(x.x, x.y)
	end
end

function M:set_image_background(x)
	if type(x) == 'table' then
		self.super.set_image_chessboard(x.size, x[1], x[2])
	else
		self.super.set_image_background(x)
	end
end

function M:set_preload_limit(x)
	x = math.floor(x)
	self.super.limit_preload(x)
	self._preload_limit = x
	return true
end

function M:set_history_limit(x)
	x = math.floor(x)
	self.super.limit_history(x)
	self._history_limit = x
	return true
end

---@param api_name 'viewer'|'slideshow'
---@return sai.viewer|sai.slideshow
function M.new(api_name)
	local api = swayimg[api_name] ---@type swayimg.viewer
	local self = {
		super = api,

		_history_limit = 0,
		_preload_limit = 0,

		--- https://github.com/artemsen/swayimg/blob/master/src/viewer.cpp#L29
		_centering = true,
		_loop = true,
		_default_position = 'center',
		_image_background = { 0xff333333, 0xff4c4c4c, size = 20 }, -- chessboard
	}

	if api_name == 'viewer' then
		self._default_scale = 'optimal'
		self._window_background = 0xff000000
		self.text = mode_text.new {
			super = api,
			_api_name = api_name,
			_topleft = {
				'File:\t{name}',
				'Format:\t{format}',
				'File size:\t{sizehr}',
				'File time:\t{time}',
				'EXIF date:\t{meta.Exif.Photo.DateTimeOriginal}',
				'EXIF camera:\t{meta.Exif.Image.Model}',
			},
			_topright = {
				'Image:\t{list.index} of {list.total}',
				'Frame:\t{frame.index} of {frame.total}',
				'Size:\t{frame.width}x{frame.height}',
			},
			_bottomleft = { 'Scale: {scale}' },
			_bottomright = {},
		}
	else --- https://github.com/artemsen/swayimg/blob/master/src/slideshow.cpp#L17
		self._default_scale = 'fit'
		self._window_background = 'auto'
		self.text = mode_text.new {
			super = api,
			_api_name = api_name,
			_topleft = {},
			_topright = { '{name}' },
			_bottomleft = {},
			_bottomright = {},
		}
	end
	self._raw_default_scale = self._default_scale

	---@cast self sai.api.viewer

	self.get_abs_scale = api.get_scale
	self.pan = new_panner(self)
	self.go = new_go(api)
	self.scale_centered = function(s, x, y)
		api.set_abs_scale(s, x, y)
		self._scale = s
	end

	self.export = function(path)
		api.export(path)
		swayimg.text.set_status 'Export done'
		e.trigger { event = 'User', match = 'ExportFinished', data = path }
	end

	api.on_image_change(function()
		self._scale = false
		e.trigger { event = 'ImgChanged', mode = api_name, match = api_name, data = U.lazyimg(api) }
	end)

	for k, v in pairs(M) do
		self[k] = v
	end
	self.new = nil

	self = mode_base.new(self, api_name) ---@type sai.api.viewer

	return self
end

return M
