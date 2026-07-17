---@diagnostic disable: invisible
---@module 'sai.api.gallery'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'

local api = swayimg.gallery

---@class sai.api.gallery: sai.gallery, sai.api.mode_base
---@diagnostic disable-next-line: missing-fields
local M = {
	super = api,

	-- settings that are not set directly in gallery.cpp, but in layout.cpp, appmode.cpp and other
	_embedded_thumb = true,
	_thumb_size = 200,
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
	_pstore_path = (os.getenv 'XDG_CACHE_HOME' or (os.getenv 'HOME' .. '/.cache')) .. '/swayimg',
	_preload = false,
	_cache_limit = 100,

	-- Custom settings
	_thumb_size_diff_reload = false,

	-- Private backing fields
	_cached_thumb_size = 200,
}

M.text = require('sai.api.mode_text').new {
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
			e.trigger {
				event = 'ImgChangedPre',
				mode = 'gallery',
				match = 'gallery',
				data = api.get_image() or U.dummy_image,
			}
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
function M:set_thumb_size(x)
	x = math.floor(x)
	self.super.set_thumb_size(x)
	-- reset cache if rendering would be really bad for old images
	if self._thumb_size_diff_reload and x / 2.2 - 25 > self._cached_thumb_size then
		if sai.mode == 'gallery' then self.super.reload() end
		self._cached_thumb_size = x
	elseif x < self._cached_thumb_size then
		self._cached_thumb_size = x
	end
	self._thumb_size = x
	return true
end
local function set_size(self, x, idx)
	x = math.floor(x)
	self.super['set_' .. idx](x)
	rawset(self, '_' .. idx, x)
	return true
end
M.set_padding_size = set_size
M.set_border_size = set_size

-- injecting function to also affect mode_text
local api_get_img = api.get_image
function api.get_image()
	local img = api_get_img()
	return img
			and setmetatable(img, {
				__index = function(self, idx)
					if idx == 'meta' then self.meta = require('sai.lib.exiv2').get_meta(self.path) end
					return rawget(self, idx)
				end,
			})
		or nil
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
