---@diagnostic disable: invisible
---@module 'sai.api.text'
---@class sai.api.text: sai.text, sai.api.proxy
local M = {
	super = swayimg.text,
	_path = 'sai.text',

	--- https://github.com/artemsen/swayimg/blob/master/src/text.cpp#L22
	_enabled = true,
	_status = '',
	_status_timeout = 3,
	_font = 'monospace',
	_size = 24,
	_line_spacing = 1, -- uses a custom formula to achieve the standard meaning of the name
	_padding = 10,

	_foreground = 0xffcccccc,
	_background = 0x00000000,
	_shadow = 0xd0000000,
}

function M.is_visible() return swayimg.text.visible end

function M:set_enabled(val)
	if val == true then
		self.super.visible = true
		self.super.timeout = 0
	elseif val == false then
		self.super.visible = false
	else
		self.super.timeout = val
	end
end

-- transform scale factor into a pixel value
function M:set_line_spacing(val) self.super.spacing = math.floor((val - 1) * self._size) end

function M:set_size(val)
	self.super.size = val

	-- update line spacing
	self._size = val
	self:set_line_spacing(self._line_spacing)
	return true
end

function M:set_foreground(val) self.super.color = val end

local function set_location(_, val, location)
	sai[swayimg.mode].text[location] = val
	return false
end
local function get_location(_, location) return sai[swayimg.mode].text[location] end

-- the text blocks are per-mode in the app: purely redirect them to the
-- current mode's text api, never cache anything on this global layer
---@param v extended_text_template[]
for _, v in pairs { 'topleft', 'topright', 'bottomleft', 'bottomright' } do
	---@diagnostic disable-next-line: assign-type-mismatch
	M['set_' .. v] = set_location
	---@diagnostic disable-next-line: assign-type-mismatch
	M['get_' .. v] = get_location
end

return require('sai.api.proxy').new(M)
