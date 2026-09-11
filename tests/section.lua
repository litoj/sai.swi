---Tests for sai.api.section: the location qualifier tokens, the block
---code lookup and the qualified bind key. Pure unit tests, no api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/' or ''
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
dir = dir:gsub('/%./', '/'):gsub('/%.?$', '')
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local section = require 'sai.api.section'

local T = {}

-- the qualified bind key: any unprefixed bind gains the block's
-- code, a prefixed one passes unchanged
T.section_key = function(h)
	h.eq('the ordered tokens name the blocks', 'TL,TR,BL,BR,ST', table.concat(section.mod.tokens, ','))
	h.eq('a click gains the block code', 'TL+MouseLeft', section.key('topleft', 'MouseLeft'))
	h.eq('a wheel gains the block code', 'ST+ScrollUp', section.key('status', 'ScrollUp'))
	h.eq('a keyboard key gains the block code', 'TL+a', section.key('topleft', 'a'))
	h.eq('a prefixed bind passes unchanged', 'TR+MouseLeft', section.key('topleft', 'TR+MouseLeft'))
end

H.maybe_standalone(T)

return T
