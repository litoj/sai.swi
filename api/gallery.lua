---@module 'sai.api.gallery'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'

local api = swayimg.gallery

---@class sai.api.gallery: sai.gallery, sai.api.mode_base
local M = {
	super = api,

	_pinch_factor = 100.0,

	--- https://github.com/artemsen/swayimg/blob/master/src/gallery.cpp#L42
	_aspect = 'fill',
	_border_size = 5,
	_selected_scale = 1.15,

	_window_color = 0xff000000,
	_unselected_color = 0xff202020,
	_selected_color = 0xff404040,
	_border_color = 0xffaaaaaa,

	_hover = true,
	_pstore = false,
	_pstore_path = (os.getenv 'XDG_CACHE_HOME' or (os.getenv 'HOME' .. '/.cache')) .. '/swayimg',
	_preload = false,
	_cache_size = 100,
	_thumb_size = 200,
	_padding_size = 5,
	_embedded_thumb = true,
}

M.text = require('sai.api.mode_text').new {
	super = api,
	_api_name = 'gallery',
	_topleft = { 'File:\t{name}' },
	_topright = { '{list.index} of {list.total}' },
	_bottomleft = {},
	_bottomright = {},
}

local function pre_change()
	e.trigger {
		event = 'ImgChangedPre',
		mode = 'gallery',
		match = 'gallery',
		data = api.get_image() or U.dummy_image,
	}
end

M.go = setmetatable({}, {
	__index = function(tbl, idx)
		tbl[idx] = function()
			pre_change()
			api.select(idx)
		end
		return tbl[idx]
	end,
	__call = function(_, x, y)
		if y then -- coordinates
			pre_change()
			api.select_at(x, y)
		else
			sai.imagelist.select(x)
		end
	end,
})

---@protected
function M:set_cache_size(x)
	x = math.floor(x)
	self.super.cache = x
	self._cache_size = x
	return true
end

---@protected
---@param x number
---@param idx string
---@return true
local function set_int(self, x, idx)
	x = math.floor(x)
	self.super[idx] = x
	self['_' .. idx] = x
	return true
end

M.set_thumb_size = set_int
M.set_padding_size = set_int
M.set_border_size = set_int

-- NOTE: injecting function to also affect mode_text
local api_get_img = api.get_image
function api.get_image()
	local img = api_get_img()
	return img and U.lazymeta(img) or nil
end

e.subscribe { -- ad-hoc registering for when user wants to subscribe
	event = 'Subscribed',
	mode = 'gallery',
	pattern = 'ImgChanged',
	once = true,
	callback = function(ev)
		local h = ev.data ---@type hook.ImgChanged|hook_cfg
		if not h.mode.gallery and not h.pattern.gallery then return end

		api.on_image_change(
			function()
				e.trigger {
					event = 'ImgChanged',
					mode = 'gallery',
					match = 'gallery',
					data = api.get_image() or U.dummy_image,
				}
			end
		)
	end,
}

require('sai.api.mode_base').new(M, 'gallery')

return M
