---Tests for sai.lib.backer: error restore and error paths.
---Runs over doubles, no app needed.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local T = {}

-- a throwing setter must not poison the event flag: the error rethrows
-- and the next set still fires its OptionSet event
function T.throwing_setter_restores_flag(h)
	H.drop_sai_stack()
	_G.swayimg = H.raw_swayimg()
	local e = require 'sai.api.eventloop'
	local backer = require 'sai.lib.backer'

	local obj = backer.new {
		_path = 'sai.fake',
		_foo = 'base',
		set_foo = function() error 'boom' end,
	}

	local seen = {}
	e.subscribe { event = 'OptionSet', pattern = 'sai.fake.foo', callback = function(ev) seen[#seen + 1] = ev end }

	local ran, err = pcall(function() obj.foo = 'next' end)
	h.ok('setter error rethrows', not ran)
	h.contains('original error text survives', tostring(err), 'boom')
	h.eq('event flag restores after throw', false, e.ignore_opts)

	rawset(obj, 'set_foo', function(self, val) rawset(self, '_foo', val) end)
	obj.foo = 'again'
	h.eq('next set still fires', 1, #seen)
	h.eq('fired event keeps the value', 'again', seen[1].data)
end

-- a missing setter must report the object path, not a nil concat error
function T.missing_setter_reports_path(h)
	H.drop_sai_stack()
	_G.swayimg = H.raw_swayimg()
	local backer = require 'sai.lib.backer'

	local obj = backer.new { _path = 'sai.fake' }
	local ran, err = pcall(function() obj.nosuch = 1 end)
	h.ok('missing setter throws', not ran)
	h.contains('error names the object path', tostring(err), 'sai.fake.nosuch')
end

H.maybe_standalone(T)

return T
