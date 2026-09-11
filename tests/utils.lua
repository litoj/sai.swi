---Unit tests for sai.lib.utils: pure table, name and exif helpers plus
---U.debounce over stubbed app timers.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local U = require 'sai.lib.utils'

local env = H.recording_stack()
local with_env = env.with_env

local T = {}

-- queue the app timers instead of dropping them; the caller pumps the
-- returned fires in order and must restore the stub afterwards
---@return table queue armed fires
---@return fun() restore
local function stub_timers()
	local queue = {}
	local old_defer = _G.swayimg.defer
	---@diagnostic disable-next-line: duplicate-set-field
	_G.swayimg.defer = function(_, cb) queue[#queue + 1] = cb end
	return queue, function() _G.swayimg.defer = old_defer end
end

-- consecutive calls share one generation: only the latest scheduled run fires
T.debounce_latest_call_wins = with_env(function(h)
	local calls = 0
	local defer = U.debounce()
	local queue, restore_timers = stub_timers()
	local ran, err = pcall(function()
		defer(function() calls = calls + 1 end, 10)
		defer(function() calls = calls + 1 end, 10)

		table.remove(queue, 1)() -- the superseded run fires first: stays silent
		h.eq('the superseded run is dropped', 0, calls)
		while #queue > 0 do
			table.remove(queue, 1)()
		end
		h.eq('the latest run fires once', 1, calls)
	end)
	restore_timers()
	if not ran then error(err, 0) end
end)

-- a lone call fires normally, like sai.defer_fn
T.debounce_single_call_fires = with_env(function(h)
	local calls = 0
	local defer = U.debounce()
	local queue, restore_timers = stub_timers()
	local ran, err = pcall(function()
		defer(function() calls = calls + 1 end, 10)
		table.remove(queue, 1)()
		h.eq('a lone call fires', 1, calls)
	end)
	restore_timers()
	if not ran then error(err, 0) end
end)

-- single values wrap, tables pass through untouched
T.tabled = function(h)
	h.eq('tabled wraps a string', 'a', U.tabled('a')[1])
	local t = { 1 }
	h.ok('tabled passes a table through', U.tabled(t) == t)
end

-- copies are shallow and detached
T.soft_copy = function(h)
	local t = { a = 1, b = { 2 } }
	local c = U.soft_copy(t)
	h.ok('soft_copy returns a new table', c ~= t)
	h.eq('soft_copy copies the keys', 1, c.a)
	h.ok('shallow: subtables shared', c.b == t.b)
end

-- rev_idx flips keys and values; get_or_default fills nils only
T.rev_idx_and_get_or_default = function(h)
	local r = U.rev_idx { a = 1 }
	h.eq('rev_idx flips keys and values', 'a', r[1])
	h.eq('get_or_default fills a nil', 'd', U.get_or_default(nil, 'd'))
	h.eq('get_or_default keeps the value', 'v', U.get_or_default('v', 'd'))
end

-- mode paths read human, redundant parent prefixes strip
T.pretty_name = function(h)
	h.eq('mode path reads human', 'Key Help', U.pretty_name 'sai.mode.key_help')
	h.eq('plain api shortens', 'Text', U.pretty_name 'sai.text')
	h.eq('underscores space out', 'Image Filter', U.pretty_name 'sai.mode.image_filter')
	h.eq('parent prefix strips', 'Completion', U.pretty_name('sai.mode.sort.completion', 'sai.mode.sort'))
end

-- single lines pass through, blocks pad to the longest line
T.align_block = function(h)
	h.eq('align_block leaves a single line', 'ab', U.align_block 'ab')
	h.eq('align_block pads to the longest line', 'ab  \ncdef', U.align_block 'ab\ncdef')
end

-- rationals reduce, plain values pass, missing tags stay nil
T.format_exif = function(h)
	local meta = { ['Exif.Photo.ExposureTime'] = '1/250', ['Exif.Image.Make'] = 'Canon' }
	h.eq('rational reduces', '1/250', U.format_exif(meta, 'ExposureTime'))
	h.eq('dotted path reads direct', 'Canon', U.format_exif(meta, 'Exif.Image.Make'))
	h.eq('plain value passes', 'Canon', U.format_exif(meta, 'Make'))
	h.eq('missing tag stays nil', nil, U.format_exif(meta, 'Nope'))
	h.eq('no meta stays nil', nil, U.format_exif(nil, 'Make'))
end

-- rationals and numerics become numbers, the rest passes through
T.parse_exif_val = function(h)
	h.eq('rational divides', 0.004, U.parse_exif_val '1/250')
	h.eq('integer converts', 42, U.parse_exif_val '42')
	h.eq('text passes through', 'Canon', U.parse_exif_val 'Canon')
	h.eq('nil stays nil', nil, U.parse_exif_val(nil))
end

H.maybe_standalone(T)

return T
