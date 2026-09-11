---Tests for sai.lib.keybind_processor: canonicalization, multi-bind mapping,
---duplicate warning and lazy trace filling.
---Doubles only; no app run.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local kp = require 'sai.lib.keybind_processor'

-- a concrete host: rawmap/rawunmap record instead of talking to the app
local function host(maps)
	local o = {
		_path = 'sai.mode.test',
		_mappings = maps,
		_raw = {},
		_rawmap = function(self, b, cfg) self._raw[b] = cfg end,
		_rawunmap = function(self, b) self._raw[b] = nil end,
	}
	kp.new(o)
	return o
end

local T = {}

T.new_canonicalizes_and_stamps = with_env(function(h)
	local o = host { ['C-x'] = { cb = function() end } }
	h.eq('short form gone', nil, rawget(o._mappings, 'C-x'))
	h.ok('canonical form present', o._mappings['Ctrl+x'] ~= nil)
	h.eq('default kind filled', 'default', o._mappings['Ctrl+x'].kind)
	h.ok('trace stamped', o._mappings['Ctrl+x']._traced == true)
end)

T.map_multi_binds_and_desc = with_env(function(h)
	local o = host()
	local fired = 0
	o.map({ 'a', 'b' }, function() fired = fired + 1 end, 'do the thing')
	h.ok('the first bind maps', o._mappings['a'] ~= nil)
	h.ok('the second bind maps', o._mappings['b'] ~= nil)
	h.eq('the desc carries over', 'do the thing', o._mappings['a'].desc)
	o._raw['a'].cb()
	h.eq('action runs through rawmap', 1, fired)
	o.unmap 'a'
	h.eq('unmapped entry dropped', nil, o._mappings['a'])
	h.eq('raw unmap fired', nil, o._raw['a'])
end)

T.duplicate_plain_bind_warns = with_env(function(h)
	local o = host()
	o.warn_on_duplicates = true
	local logged = {}
	local old_log = _G.sai.log
	_G.sai.log = function(msg) logged[#logged + 1] = msg end
	local ran, err = pcall(function()
		o.map('a', function() end)
		h.eq('first plain map stays quiet', 0, #logged)
		o.map('a', function() end)
		h.eq('second plain map warns', 1, #logged)
		h.ok('the warning names the bind', logged[1]:find('"a"', 1, true) ~= nil)
		-- a default-kind map must not warn: factory defaults are overridden all the time
		o.map('a', function() end, { kind = 'default' })
		h.eq('default-kind remap stays quiet', 1, #logged)
	end)
	_G.sai.log = old_log
	if not ran then error(err, 0) end
end)

T.get_mappings_fills_lazy_trace = with_env(function(h)
	local o = host()
	o._mappings['x'] = { cb = function() end, trace = debug.traceback() } -- planted without the pipeline
	h.eq('the planted mapping is untraced', nil, o._mappings['x']._traced)
	local m = o.get_mappings()
	h.ok('the read fills the trace', m['x']._traced == true)
end)

H.maybe_standalone(T)

return T
