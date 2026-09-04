---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for the reconfigurer __tostring representations: the default version
---shows the overrides, the eventloop preset maps _new to 'hooks' and _filter
---to 'filters'.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local R = require 'sai.lib.reconfigurer'

local T = {}

T.tostring_default = function(h)
	local r = R.new { super = { _path = 'sai.fake', size = 10 } }
	r.size = 20
	r.position = 'center'
	local s = tostring(r)
	h.contains('override values shown', s, 'size=20')
	h.contains('string overrides quoted', s, 'position="center"')
end

T.tostring_eventloop = function(h)
	local el = R.new_evloop()
	el.subscribe { event = 'User', match = 'ModePush', callback = function() end }
	el.unsubscribe { event = 'OptionSet', match = 'sai.text.size' }
	local s = tostring(el)
	h.contains('hooks mapped from _new', s, 'hooks={ [1]="User=ModePush" }')
	h.contains('filters mapped from _filter', s, 'filters={ [1]="OptionSet=sai.text.size" }')
end

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
