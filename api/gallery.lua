---@diagnostic disable: invisible
---@module 'swi.api.gallery'

local e = require 'swi.api.eventloop'

local api = swayimg.gallery

---@class swi.api.gallery: swi.gallery, swi.api.mode_base
---@diagnostic disable-next-line: missing-fields
local M = {
	super = api,

	-- settings that are not set directly in gallery.cpp
	_embedded_thumb = true,
	_padding_size = 5,

	--- https://github.com/artemsen/swayimg/blob/master/src/gallery.cpp#L73
	_aspect = 'fill',
	_border_size = 5,
	_selected_scale = 1.15,
	_pinch_factor = 100.0,

	_window_color = 0xff000000,
	_background_color = 0xff202020,
	_selected_color = 0xff404040,
	_border_color = 0xffaaaaaa,

	_hover = true,
	_pstore = false,
	-- _pstore_path = (os.getenv 'XDG_CACHE_HOME' or (os.getenv 'HOME' .. '/.cache')) .. '/swayimg',
	_preload = false,
	_cache_limit = 100,
}

M.text = require('swi.api.mode_text').new {
	super = api,
	_api_name = 'gallery',
	_topleft = { 'File:\t{name}' },
	_topright = { '{list.index} of {list.total}' },
	_bottomleft = {},
	_bottomright = {},
}

M.go = setmetatable({}, {
	__index = function(tbl, idx)
		tbl[idx] = function()
			e.trigger { event = 'ImgChangedPre', mode = 'gallery', match = 'gallery', data = api.get_image() }
			api.switch_image(idx)
		end
		return tbl[idx]
	end,
})

function M:set_cache_limit(x)
	x = math.floor(x)
	self.super.limit_cache(x)
	self._cache_limit = x
	return true
end
local function set_size(self, x, idx)
	x = math.floor(x)
	self.super['set_' .. idx](x)
	rawset(self, '_' .. idx, x)
	return true
end
M.set_thumb_size = set_size
M.set_padding_size = set_size

e.subscribe { -- ad-hoc registering for when user wants to subscribe
	event = 'Subscribed',
	mode = 'gallery',
	pattern = 'ImgChanged',
	callback = function()
		api.on_image_change(
			function() e.trigger { event = 'ImgChanged', mode = 'gallery', match = 'gallery', data = api.get_image() } end
		)
		return true
	end,
}

require('swi.api.mode_base').new(M, 'gallery')

return M
