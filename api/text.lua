---@diagnostic disable: invisible
---@module 'swi.api.text'
---@class swi.api.text: swi.text
local M = {
	super = swayimg.text,
	_path = 'swi.text',

	-- settings that are not set directly in text.cpp
	_font = 'monospace',
	_size = 24,

	--- https://github.com/artemsen/swayimg/blob/master/src/text.cpp#L22
	_enabled = true,
	_status_timeout = 3,

	_line_spacing = 1, -- uses a custom formula to achieve the standard meaning of the name
	_padding = 10,

	_foreground = 0xffcccccc,
	_background = 0x00000000,
	_shadow = 0xd0000000,
}

M.is_visible = swayimg.text.visible

function M:set_enabled(val)
	if val == true then
		self.super.show()
		self.super.set_timeout(0)
	elseif val == false then
		self.super.hide()
	else
		self.super.set_timeout(val)
	end
end

-- transform scale factor into a pixel value
function M:set_line_spacing(val) self.super.set_spacing(math.floor((val - 1) * self._size)) end

function M:set_size(val)
	self.super.set_size(val)

	-- update line spacing
	self._size = val
	self:set_line_spacing(self._line_spacing)
	return true
end

function M.set_status(self_or_text, text_or_nil) M.super.set_status(text_or_nil or self_or_text) end

return require('swi.lib.proxy').new(M)
