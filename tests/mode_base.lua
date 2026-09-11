---Tests for sai.api.mode_base: the shared mode behaviour.
---Runs over doubles, no app needed.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local T = {}

-- mode_base never pre-defined `_on_unassigned`: the setter's inner write
-- then fell through `__newindex` into super plus a spurious option event
function T.on_unassigned_needs_no_private_path(h)
	H.drop_sai_stack()
	_G.swayimg = H.raw_swayimg()
	local mode_base = require 'sai.api.mode_base'

	local obj = { super = H.raw_mode() }
	mode_base.new(obj, 'viewer')
	obj.on_unassigned = function() end
	h.eq('the setter stores the backing field', 'function', type(obj._on_unassigned))
	-- rawget: the stub answers any read with a noop, only a write shows here
	h.eq('no private write to super', nil, rawget(obj.super, '_on_unassigned'))
	h.eq('no mangled backing key', nil, rawget(obj, '__on_unassigned'))
end

H.maybe_standalone(T)

return T
