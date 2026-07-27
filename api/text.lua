---@diagnostic disable: invisible
---@module 'sai.api.text'
---@class sai.api.text: sai.text
local M = {
	super = swayimg.text,
	_path = 'sai.text',

	--- https://github.com/artemsen/swayimg/blob/master/src/text.cpp#L22
	_enabled = true,
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

return require('sai.api.proxy').new(M)
