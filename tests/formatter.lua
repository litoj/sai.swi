---Tests for sai.lib.formatter: set() overloads, splice(), touch(), cache reuse.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local F = require 'sai.lib.formatter'

local env = H.recording_stack()
local with_env = env.with_env

-- h.eq is identity-only: compare string buffers row by row
local function joined(t) return table.concat(t, '\n') end

-- a formatter whose paint hook counts calls per index and reads a live
-- state table, like the selector/editor flags ride their closures
local function engine(state)
	local calls = {}
	local f = F.new {
		format = function(idx, val)
			calls[idx] = (calls[idx] or 0) + 1
			return tostring(val) .. (state.mark == idx and '*' or '') .. ':' .. idx
		end,
	}
	return f, calls
end

local T = {}

-- the raw items read back like from any table
T.set_table_reads_raw = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	f:set { 'a', 'b', 'c' }
	h.eq('the length is the item count', 3, #f)
	h.eq('items read by index', 'b', f[2])
	local seen = {}
	for i, v in ipairs(f) do
		seen[i] = v
	end
	h.eq('ipairs walks in order', 'c', seen[3])
end)

T.set_one_line = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	f:set { 'a', 'b' }
	f:set(2, 'B')
	h.eq('set line is replaced', 'B', f[2])
	h.eq('other lines stay untouched', 'a', f[1])
end)

T.set_one_appends_at_the_end = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	f:set { 'a' }
	f:set(2, 'b')
	h.eq('the append lands at the end', 'b', f[2])
end)

T.set_nil_deletes_one_line = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	f:set { 'a', 'b', 'c' }
	f:set(2, nil)
	h.eq('the list shrinks', 2, #f)
	h.eq('the tail shifts down', 'c', f[2])
end)

T.set_integer_deletes_a_range = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	f:set { 'a', 'b', 'c', 'd' }
	f:set(2, 3)
	h.eq('the range head survives', 'a', f[1])
	h.eq('the range tail survives', 'd', f[2])
	h.eq('the list shrinks by the range', 2, #f)
end)

T.splice_paints_through_the_hook = with_env(function(h)
	local f = F.new { format = function(idx, val) return tostring(val) .. idx end }
	f:set { 'a', 'b' }
	local out = {}
	f:splice(out, 1, 2)
	h.eq('the first row lands painted', 'a1', out[1])
	h.eq('the second row follows', 'b2', out[2])
end)

T.splice_appends_into_a_started_buffer = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	f:set { 'x', 'y' }
	local out = { 'title' }
	f:splice(out, 1, 2)
	h.eq('the title keeps its slot', 'title', out[1])
	h.eq('the rows follow the existing content', 'x\ny', joined { out[2], out[3] })
end)

-- the whole point: a row formats once until invalidated
T.splice_reuses_cached_rows = with_env(function(h)
	local f, calls = engine {}
	f:set { 'a', 'b', 'c' }
	local out = {}
	f:splice(out, 1, 3)
	local again = {}
	f:splice(again, 2, 3)
	h.eq('row one painted exactly once', 1, calls[1])
	h.eq('row two painted exactly once', 1, calls[2])
	h.eq('row three painted exactly once', 1, calls[3])
	h.eq('the second splice serves the same rows', 'a:1\nb:2\nc:3', joined(out))
end)

T.touch_repaints_one_row = with_env(function(h)
	local state = {}
	local f, calls = engine(state)
	f:set { 'a', 'b', 'c' }
	local out = {}
	f:splice(out, 1, 3)
	state.mark = 2
	f:touch(2)
	local again = {}
	f:splice(again, 1, 3)
	h.eq('the touched row re-paints', 2, calls[2])
	h.eq('the first row paints once', 1, calls[1])
	h.eq('the third row paints once', 1, calls[3])
	h.eq('the repaint reads the new state', 'a:1\nb*:2\nc:3', joined(again))
end)

T.set_one_dirties_only_that_row = with_env(function(h)
	local f, calls = engine {}
	f:set { 'a', 'b', 'c' }
	local out = {}
	f:splice(out, 1, 3)
	f:set(2, 'B')
	local again = {}
	f:splice(again, 1, 3)
	h.eq('the changed row re-paints', 2, calls[2])
	h.eq('the first row paints once', 1, calls[1])
	h.eq('the third row paints once', 1, calls[3])
	h.eq('the buffer holds the new value', 'a:1\nB:2\nc:3', joined(again))
end)

-- the lockstep shift: a delete moves painted rows with their lines
T.delete_keeps_rendered_rows_aligned = with_env(function(h)
	local f, calls = engine {}
	f:set { 'a', 'b', 'c' }
	local out = {}
	f:splice(out, 1, 3)
	f:set(1, nil)
	local again = {}
	f:splice(again, 1, 2)
	h.eq('the shifted row keeps its paint', 1, calls[2])
	h.eq('the tail row keeps its paint', 1, calls[3])
	h.eq('the painted rows moved with their lines', 'b:2\nc:3', joined(again))
end)

T.set_table_dirties_all_rows = with_env(function(h)
	local f, calls = engine {}
	f:set { 'a', 'b' }
	local out = {}
	f:splice(out, 1, 2)
	f:set { 'a', 'b' }
	local again = {}
	f:splice(again, 1, 2)
	h.eq('the first row re-paints after a full replace', 2, calls[1])
	h.eq('the second row re-paints after a full replace', 2, calls[2])
	h.eq('the rendered rows stay correct', 'a:1\nb:2', joined(again))
end)

T.splice_skips_rows_never_painted = with_env(function(h)
	local f, calls = engine {}
	f:set { 'a', 'b', 'c', 'd' }
	local out = {}
	f:splice(out, 2, 3)
	h.eq('the skipped rows never paint', nil, calls[1])
	h.eq('the window head paints', 1, calls[2])
	h.eq('the window tail paints', 1, calls[3])
	h.eq('the row past the window never paints', nil, calls[4])
	h.eq('the buffer holds the window', 'b:2\nc:3', joined(out))
end)

T.range_deletes_keep_the_cache_aligned = with_env(function(h)
	local f, calls = engine {}
	f:set { 'a', 'b', 'c', 'd', 'e' }
	local out = {}
	f:splice(out, 1, 5)
	f:set(2, 4)
	local again = {}
	f:splice(again, 1, 2)
	h.eq('the head keeps its single paint', 1, calls[1])
	h.eq('the survivor keeps its single paint', 1, calls[5])
	h.eq('the buffer holds the survivors', 'a:1\ne:5', joined(again))
end)

T.out_of_range_writes_error = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	f:set { 'a', 'b' }
	h.ok('setting before the list errors', not pcall(function() f:set(0, 'x') end))
	h.ok('setting past the append slot errors', not pcall(function() f:set(4, 'x') end))
	h.ok('deleting past the end errors', not pcall(function()
		f:set(2, nil)
		f:set(3, nil)
	end))
	h.ok('a range ending before its start errors', not pcall(function() f:set(2, 1) end))
end)

T.empty_formatter_splices_nothing = with_env(function(h)
	local f = F.new { format = function(_, val) return val end }
	local out = { 'title' }
	f:splice(out, 1, 0)
	h.eq('nothing appends onto the buffer', 'title', out[1])
	h.eq('the buffer keeps its length', 1, #out)
end)

return T
