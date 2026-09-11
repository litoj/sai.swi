---Tests for sai.lib.filter: line parsing, operators, matching.
---The image flow over it is covered in tests/image_filter.lua.
---Runs over a recording api stack (the `:` operator notifies via sai).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local flt = require 'sai.lib.filter'

local env = H.recording_stack()
local with_env = env.with_env

local function engine(df)
	return flt.new {
		get = function(img, tag) return img[tag] end,
		default_var = 'path',
		default_filter = df,
	}
end

local T = {}

-- `-` is escaped: without it the pattern quantifier eats the match
T.dash_matches_literally_in_equality = with_env(function(h)
	local F = engine(0)
	local cond = assert(F:parse 'path==foo-bar.png')
	h.ok('hyphenated value matches', F:apply(cond, { path = 'foo-bar.png' }))
	h.ok('dropping the dash breaks the match', not F:apply(cond, { path = 'foobar.png' }))
	local neg = assert(F:parse 'path!=foo-bar.png')
	h.ok('negation keeps hyphenated values out', not F:apply(neg, { path = 'foo-bar.png' }))
	h.ok('negation lets the rest through', F:apply(neg, { path = 'other.png' }))
end)

-- `==` stays a luapat in `^...$`: only `-` is escaped
T.equality_is_anchored_luapat = with_env(function(h)
	local F = engine(0)
	local cond = assert(F:parse 'name==bar')
	h.ok('exact value matches', F:apply(cond, { name = 'bar' }))
	h.ok('no prefix match', not F:apply(cond, { name = 'bars' }))
	h.ok('no substring match', not F:apply(cond, { name = 'xbar' }))
	local dot = assert(F:parse 'name==b.r')
	h.ok('dot stays wild', F:apply(dot, { name = 'bxr' }))
end)

-- `~` fuzzy-matches even when the default is plain substring
T.tilde_fuzzy_matches = with_env(function(h)
	local F = engine(0)
	local cond = assert(F:parse 'name~bana')
	h.ok('in-order fragment matches', F:apply(cond, { name = 'banana' }))
	h.ok('an unrelated value misses', not F:apply(cond, { name = 'xyz' }))
	h.ok('missing values miss', not F:apply(cond, {}))
	local gappy = assert(F:parse 'name~bnna')
	h.ok('two gaps exceed tolerance 1', not F:apply(gappy, { name = 'banana' }))
	local wide = engine(5)
	local wcond = assert(wide:parse 'name~bnna')
	h.ok('wider default tolerance allows the gaps', wide:apply(wcond, { name = 'banana' }))
end)

-- match-anywhere rating (rate_start false, like a filter): case follows the
-- input - an all-lowercase query folds, an uppercase one does not
T.rating_case_follows_the_input = with_env(function(h)
	h.ok('a mixed-case query matches in order', flt.rate('ETi', 'ExposureTime', false) ~= nil)
	h.ok('a single uppercase char matches anywhere', flt.rate('T', 'ExposureTime', false) ~= nil)
	h.ok('a leaf fragment matches mid-name', flt.rate('ake', 'Make', false) ~= nil)
	h.ok('all-lowercase input folds the candidate case', flt.rate('make', 'Make', false) ~= nil)
	h.eq('uppercase input stays case-sensitive', nil, flt.rate('PAT', 'path', false))
end)

T.empty_line_matches_nothing = with_env(function(h)
	local F = engine(0)
	h.eq('empty parses to nothing', nil, F:parse '')
	h.eq('blank parses to nothing', nil, F:parse '   ')
end)

T.negation_needs_no_value = with_env(function(h)
	local F = engine(0)
	local cond, err = F:parse 'mark!'
	h.ok('bare negation parses', cond ~= nil and err == nil)
	h.ok('missing counts as negated', F:apply(cond, {}))
	h.ok('a present value fails the negation', not F:apply(cond, { mark = true }))
end)

-- tags cannot be omitted except for code, values except for negation
T.omitted_sides_are_rejected = with_env(function(h)
	local F = engine(0)
	h.eq('tagless equality rejected', nil, F:parse '==x')
	h.eq('valueless equality rejected', nil, F:parse 'name==')
	h.ok('tagless code runs on the item', F:parse ':self' ~= nil)
end)

T.numeric_operators_coerce = with_env(function(h)
	local F = flt.new {
		get = function(img, tag) return img[tag] end,
		coerce = function(v) return tonumber(v) or v end,
		default_var = 'path',
		default_filter = 0,
	}
	local lt = assert(F:parse 'size<10')
	h.ok('smaller value matches', F:apply(lt, { size = 5 }))
	h.ok('larger value misses', not F:apply(lt, { size = 15 }))
	h.ok('missing value misses', not F:apply(lt, {}))
end)

T.code_operator_runs = with_env(function(h)
	local F = engine(0)
	local cond = assert(F:parse 'size:return self > 1')
	h.ok('true code matches', F:apply(cond, { size = 2 }))
	h.ok('false code misses', not F:apply(cond, { size = 1 }))
	local bad, err = F:parse 'size:return >'
	h.eq('broken code parses to nothing', nil, bad)
	h.contains('the parse error names its input chunk', err or '', 'input:1:')
end)

H.maybe_standalone(T)

return T
