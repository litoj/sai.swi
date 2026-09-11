---Tests for sai.api.proxy backing writes: pre-defined fields assign
---directly (one public event, no super write), like viewer/text setters.
---Runs over doubles, no app needed.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local T = {}

-- fresh proxy env per test: the doubles carry no state between them
local function fresh()
	H.drop_sai_stack()
	_G.swayimg = H.raw_swayimg()
	return require 'sai.api.eventloop', require 'sai.api.proxy'
end

-- the viewer/text setter shape: super write to the public name, backing
-- field pre-defined, `true` reads the stored value back for the event
function T.predefined_backing_writes_cleanly(h)
	local _, proxy = fresh()

	local super = {}
	local obj = proxy.new {
		super = super,
		_path = 'sai.fake',
		_preload_size = 0,
		set_preload_size = function(self, x)
			x = math.floor(x)
			self.super.preload = x
			self._preload_size = x
			return true
		end,
	}

	local e = require 'sai.api.eventloop'
	local seen = {}
	e.subscribe {
		event = 'OptionSet',
		pattern = 'sai%.fake',
		group = 'test_proxy',
		callback = function(ev) seen[#seen + 1] = ev.match end,
	}
	obj.preload_size = 42
	h.eq('one public event fires', 'sai.fake.preload_size', table.concat(seen, ','))
	h.eq('backing field stores the value', 42, obj._preload_size)
	h.eq('super stores under the public name', 42, super.preload)
	h.eq('super got no private copy', nil, super._preload_size)
	e.unsubscribe { event = 'OptionSet', group = 'test_proxy' }
end

-- a nil-returning setter stores through the proxy (backing pre-defined,
-- like the real setters); a false one stays silent: no store, no event
function T.setter_return_shapes(h)
	local e, proxy = fresh()

	local seen = {}
	e.subscribe {
		event = 'OptionSet',
		pattern = 'sai%.fake',
		group = 'test_proxy',
		callback = function(ev) seen[#seen + 1] = ev.match .. '=' .. tostring(ev.data) end,
	}

	local o1 = proxy.new { super = {}, _path = 'sai.fake', _a = 0, set_a = function(_) end }
	o1.a = 1
	h.eq('nil-returning setter stores', 1, o1._a)

	local o2 = proxy.new { super = {}, _path = 'sai.fake', _b = 0, set_b = function() return false end }
	o2.b = 2
	h.eq('false setter stores nothing', 0, o2._b)
	h.eq('only the stored write fired', 'sai.fake.a=1', table.concat(seen, ','))
	e.unsubscribe { event = 'OptionSet', group = 'test_proxy' }
end

-- no setter: the write lands on super and the backing copy, then fires
function T.plain_write_forwards_and_fires(h)
	local e, proxy = fresh()

	local super = {}
	local obj = proxy.new { super = super, _path = 'sai.fake', _c = 0 }
	local seen = {}
	e.subscribe {
		event = 'OptionSet',
		pattern = 'sai%.fake',
		group = 'test_proxy',
		callback = function(ev) seen[#seen + 1] = ev.match .. '=' .. tostring(ev.data) end,
	}
	obj.c = 3
	h.eq('super got the write', 3, super.c)
	h.eq('backing got the copy', 3, obj._c)
	h.eq('write fires the event', 'sai.fake.c=3', table.concat(seen, ','))
	e.unsubscribe { event = 'OptionSet', group = 'test_proxy' }
end

-- reads, in priority order: get_ override, super fn (cached), super
-- value, super get_ idiom, local backing copy, else a loud error
function T.index_read_shapes(h)
	local _, proxy = fresh()

	local super = {
		run = function() return 1 end,
		n = 7,
		get_mode = function() return 'm' end,
	}
	local obj = proxy.new {
		super = super,
		_path = 'sai.fake',
		_memo = 'kept',
		get_thing = function(_, idx) return 'got-' .. idx end,
	}
	h.eq('get_ override serves the read', 'got-thing', obj.thing)
	h.eq('super function forwards the call', 1, obj.run())
	h.ok('super fn cached on first read', rawget(obj, 'run') ~= nil)
	h.eq('super value forwards the read', 7, obj.n)
	h.ok('super value not cached', rawget(obj, 'n') == nil)
	h.eq('super get_ idiom serves the read', 'm', obj.mode)
	h.eq('local backing copy serves the read', 'kept', obj.memo)

	local ran, err = pcall(function() return obj.nope end)
	h.ok('missing key errors', not ran)
	h.ok('the error names the missing key path', tostring(err):find('sai.fake.nope', 1, true) ~= nil)
end

H.maybe_standalone(T)

H.maybe_standalone(T)

return T
