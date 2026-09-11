---Tests for sai.mode.completion: candidate contract, rendering, rating,
---ordering and insertion. Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local completion = require 'sai.mode.completion'

local T = {}

-- the menu shows the candidate text, never the raw item tables
T.items_render_their_text = with_env(function(h)
	local completion = require 'sai.mode.completion'
	local m = completion.new { _path = 'sai.mode.completion' }
	m.source = function() return { { text = 'Exif.Image.Make' } } end
	h.eq('update finds one match', 1, m:update 'Exif')

	local line = m:line_fmt(m.lines[1], 1)
	h.ok('the line shows the tag name', line:find('Exif.Image.Make', 1, true) ~= nil)
	h.ok('no table dump in the menu', not line:find('table: 0x', 1, true))
	m.enabled = false
end)

-- candidates rate against their short name, not the full path
T.items_match_the_short_name = with_env(function(h)
	local m = completion.new { _path = 'sai.mode.completion' }
	m.source = function() return { { text = 'Exif.Photo.ExposureTime', rate = 'ExposureTime' } } end
	h.eq('the exact short name matches', 1, m:update 'ExposureTime')
	h.eq('a fuzzy short name matches', 1, m:update 'ETime')
	h.eq('a lowercase fragment matches anywhere', 1, m:update 'osure')
	h.eq('an all-lowercase fragment folds the case', 1, m:update 'osuretime')
	m.enabled = false
end)

-- repeated updates must not accumulate counts in the title: the count
-- rides title_fmt, the stored title stays the base (the base text itself
-- is volatile, so the test reads it live instead of pinning it)
T.title_keeps_single_count = with_env(function(h)
	local m = completion.new { _path = 'sai.mode.completion' }
	m.source = function() return { { text = 'ba' }, { text = 'bar' }, { text = 'banana' } } end
	local base = m.title
	local shown = base:gsub('\t$', '')
	h.eq('update finds three matches', 3, m:update 'ba')
	h.eq('stored title stays base', base, m.title)
	h.eq('shown header carries the live count', shown .. ' 3', m:title_fmt(m.title, nil))
	h.eq('update finds three matches again', 3, m:update 'ba')
	h.eq('stored title still base', base, m.title)
	h.eq('shown header still carries one count', shown .. ' 3', m:title_fmt(m.title, nil))
	m.enabled = false
end)

T.update = with_env(function(h)
	local c = completion.new { _path = 'sai.mode.completion' }
	h.ok('the menu starts closed', not c.enabled)

	c.source = function()
		return {
			{ text = 'ba' },
			{ text = 'bar' },
			{ text = 'baz' },
			{ text = 'banana' },
			{ text = 'xx' },
		}
	end
	c.enabled = true -- the host owns the lifecycle
	h.eq('update returns the match count', 4, c:update 'ba')
	local texts = {}
	for _, it in ipairs(c.lines) do
		texts[#texts + 1] = it.text
	end
	h.eq('tight first, then short, full ties alphabetical', 'ba\nbar\nbaz\nbanana', table.concat(texts, '\n'))

	h.eq('update returns zero matches', 0, c:update 'zz')
	h.ok('no matches keep the menu up', c.enabled)
	h.eq('the list clears to none', 0, #c.lines)
	h.eq('a single-char base matches nothing', 0, c:update 'b')
	h.eq('an empty base matches nothing', 0, c:update '')

	c.ignore_case = true
	h.eq('case-insensitive rating matches', 4, c:update 'BA')
	c.ignore_case = false
	h.eq('case-sensitive rating misses', 0, c:update 'BA')

	c.source = false
	h.eq('no source: no matches', 0, c:update 'ba')
	h.ok('the menu still stands', c.enabled)
end)

T.accept = with_env(function(h)
	local editor = require 'sai.mode.editor'
	local target = editor.new { _path = 'sai.mode.editor' }
	target.enabled = true
	target:insert 'foo bar'

	local c = completion.new { _path = 'sai.mode.completion' }
	c.target = target
	c.enabled = true
	c.source = function()
		return {
			{ text = 'ba', insert = 'bar' },
			{ text = 'baz' },
		}
	end
	c:update 'ba'
	c:confirm()
	h.eq('accept replaces the current line with the insert text', 'bar', target.text)
	h.eq('the cursor lands after the insert', 4, target.col)
	h.ok('the menu stays up after the accept', c.enabled)

	-- without insert, the displayed text goes in; explicit item accepted
	c:update 'ba'
	c:confirm { text = 'baz' }
	h.eq('plain items insert their text', 'baz', target.text)

	-- multi-line target: only the current line is replaced (the cursor
	-- sits at the start of the second line)
	target.text = 'one\ntwo\nthree'
	target.line = 2
	target.col = 1
	c:update 'tw'
	c:confirm { text = '2', insert = '2' }
	h.eq('only the current line is replaced', 'one\n2\nthree', target.text)
	c.enabled = false
end)

T.abort_report = with_env(function(h)
	local editor = require 'sai.mode.editor'
	local target = editor.new { _path = 'sai.mode.editor' }
	target.enabled = true

	local seen = {}
	local c = completion.new {
		_path = 'sai.mode.completion',
		on_confirm = function(self, item)
			seen[#seen + 1] = item
			return require('sai.mode.completion').on_confirm(self, item)
		end,
	}
	c.target = target
	c.enabled = true
	c.source = function() return { { text = 'bar' } } end
	c:update 'ba'
	c:confirm()
	h.eq('accept reaches the hook', 1, #seen)
	h.ok('the menu stays up after the accept', c.enabled)

	c:update 'ba'
	c:confirm(false)
	h.eq('abort reaches on_confirm as false', false, seen[#seen])
	h.ok('the menu stays up after the abort', c.enabled)
	target.enabled = false
end)

-- The menu owns only its own keys: the input actions (confirm, abort,
-- hide) are the target's - unbound here, they flow through to it
T.menu_owns_only_menu_keys = with_env(function(h)
	local editor = require 'sai.mode.editor'
	local target = editor.new { _path = 'sai.mode.editor' }
	target.enabled = true

	local c = completion.new { _path = 'sai.mode.completion' }
	c.target = target
	c.source = function() return { { text = 'bar' } } end
	c.enabled = true -- the host put the menu up
	c:update 'ba'

	h.ok('Return unclaimed by the menu', c._mappings['Return'] == nil)
	h.ok('Escape unclaimed by the menu', c._mappings['Escape'] == nil)
	h.ok('Ctrl+Escape unclaimed by the menu', c._mappings['Ctrl+Escape'] == nil)
	h.ok('the menu keeps its own accept key', c._mappings['Tab'] ~= nil)

	-- the live claim stays the target's while the menu layer sits on top
	h.eq('Return belongs to the target', 'Confirm', sai.viewer._mappings['Return'].desc)
	h.eq('Escape belongs to the target', 'Abort', sai.viewer._mappings['Escape'].desc)
	h.eq('Ctrl+Escape belongs to the target', 'Hide mode', sai.viewer._mappings['Ctrl+Escape'].desc)

	-- and it still reaches the target through the flow-through
	env.raw_binds['viewer:Return']()
	h.eq('Return confirms the target over the menu', 1, target._verdict)

	c.enabled = false
	target.enabled = false
end)

-- without a target (or with an abort) confirm is a no-op reporting false
T.confirm_without_target = with_env(function(h)
	local m = completion.new { _path = 'sai.mode.completion' }
	h.eq('confirm without a target reports false', false, m:on_confirm { text = 'x' })
	h.eq('confirm with abort reports false', false, m:on_confirm(false))
	m.enabled = false
end)

-- min_chars 0 lists every candidate on an empty base; update(nil)
-- defaults the base to '' and clears below the engage length
T.empty_base_lists_all_at_zero = with_env(function(h)
	local m = completion.new { _path = 'sai.mode.completion' }
	m.source = function() return { { text = 'b' }, { text = 'a' } } end
	m.min_chars = 0
	h.eq('empty base lists all', 2, m:update '')
	h.eq('nil base defaults to empty', 2, m:update(nil))
	m.min_chars = 2
	h.eq('engage length clears the short base', 0, m:update '')
	h.eq('nil base clears too', 0, m:update(nil))
	m.enabled = false
end)

H.maybe_standalone(T)

return T
