---Tests for sai.mode.text_adjust: the F2 takeover, block discovery and the
---live sizing, follow-margin and swap controls.
---Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.text_adjust' }
local sai = env.sai
local text_adjust = env.mods['sai.mode.text_adjust']
local raw_binds, with_env = env.raw_binds, env.with_env

local pager = require 'sai.lib.pager'
local selector = require 'sai.mode.selector'

-- the help display lists one line per section bind, so its longest line
-- decides how far left its block reaches: the stub window stays wide
-- enough that the bottom-left block and the status stay hoverable
env.swayimg.get_window_size = function() return { width = 2400, height = 600 } end

-- one shared closure: the api proxy caches the pointer getter on first read
local at = H.mouse_stub(env.swayimg)

-- a fresh five-line block at a corner; the lines make the block hoverable
local function block(path, loc)
	local p = pager.new { _path = path, _location = loc, _max_height = 5, title = '' }
	p.enabled = true
	p.lines = H.items(20)
	return p
end

local T = {}

-- F2 takes the block wheels over and gives them back on leave; the owner
-- lookup skips the mode's own takeover record and finds the pager below.
-- Stub 2400x600, linepx 42, padding 10.
T.f2_takes_and_releases_the_block_wheels = with_env(function(h)
	local p = block('sai.mode.host.pager', 'topleft')

	at(100, 10 + 42 + 21) -- the first content row of the topleft block
	raw_binds['viewer:ScrollDown']()
	h.eq('before the takeover: the wheel scrolled the window', 2, p._scroll)

	raw_binds['viewer:F2']()
	h.ok('the mode is on', text_adjust._enabled)
	h.eq('the owner lookup skips our own record', p, text_adjust:owner_at 'topleft')

	raw_binds['viewer:ScrollDown']()
	h.eq('the wheel resized the block instead', 2, p._scroll)
	h.eq('a top block grows on wheel down', 6, p.max_height)

	raw_binds['viewer:F2']()
	h.ok('the mode is off', not text_adjust._enabled)
	raw_binds['viewer:ScrollDown']()
	h.eq('the block wheel works again', 3, p._scroll)

	p.enabled = false
end)

-- Top blocks anchor at the top (wheel up shortens them), bottom ones at the
-- bottom edge (wheel up lengthens); two lines are the floor, the full
-- window only steps down into fractions.
T.wheel_resizes_by_anchor_side = with_env(function(h)
	local top = block('sai.mode.host.top', 'topleft')
	local bottom = block('sai.mode.host.bottom', 'bottomleft')
	text_adjust.enabled = true

	at(100, 10 + 42 + 21)
	raw_binds['viewer:ScrollUp']()
	h.eq('top block shortened', 4, top.max_height)
	raw_binds['viewer:ScrollDown']()
	h.eq('the top block lengthens back', 5, top.max_height)

	at(100, 600 - 10 - 21) -- the bottom-left block's last row
	raw_binds['viewer:ScrollUp']()
	h.eq('bottom block lengthened', 6, bottom.max_height)
	raw_binds['viewer:ScrollDown']()
	h.eq('the bottom block shortens back', 5, bottom.max_height)

	-- a re-seeded pointer for the top block: a full window covers the row
	-- the bottom checks clicked, and a shrunk one falls short of it
	top.max_height = 2
	at(100, 10 + 42 + 21)
	raw_binds['viewer:ScrollUp']()
	h.eq('the two-line floor holds', 2, top.max_height)
	top.max_height = 1
	raw_binds['viewer:ScrollUp']()
	h.eq('a full-window block goes fractional', 0.9, top.max_height)
	raw_binds['viewer:ScrollDown']()
	h.eq('a fraction tops out at the full window', 1, top.max_height)

	text_adjust.enabled = false
	top.enabled, bottom.enabled = false, false
end)

-- Shift+wheel steps the follow margin: up smaller, down larger, tenths
-- below one and whole lines above; two lines are the shared floor.
T.shift_wheel_steps_the_follow_margin = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.host.selector', _location = 'topleft', title = '' }
	s.enabled = true
	s.lines = H.items(20)
	h.eq('the selector default follow margin', 0.5, s.scroll_ahead)

	text_adjust.enabled = true
	at(100, 10 + 42 + 21)

	raw_binds['viewer:Shift+ScrollUp']()
	h.eq('the margin steps a tenth smaller', 0.4, s.scroll_ahead)
	raw_binds['viewer:Shift+ScrollDown']()
	h.eq('the margin steps back to half', 0.5, s.scroll_ahead)

	s.scroll_ahead = 2
	raw_binds['viewer:Shift+ScrollUp']()
	h.eq('the margin parks at two lines', 2, s.scroll_ahead)
	raw_binds['viewer:Shift+ScrollDown']()
	h.eq('the margin steps a whole line up', 3, s.scroll_ahead)

	text_adjust.enabled = false
	s.enabled = false

	local p = block('sai.mode.host.plain', 'topleft')
	text_adjust.enabled = true
	at(100, 10 + 42 + 21)
	raw_binds['viewer:Shift+ScrollDown']()
	h.eq('a plain pager keeps its height', 5, p.max_height)
	text_adjust.enabled = false
	p.enabled = false
end)

-- wasd trades the block under the pointer with the neighbor in the key's
-- direction; the bottom row reads BL, status, BR left to right, and the
-- top edge has nothing above it to trade with.
T.wasd_swaps_blocks = with_env(function(h)
	local sel = selector.new { _path = 'sai.mode.host.sel', _location = 'topleft', title = '' }
	local botl = block('sai.mode.host.botl', 'bottomleft')
	local stat = selector.new { _path = 'sai.mode.host.stat', _location = 'status', title = '' }
	sel.enabled = true
	sel.lines = H.items(20)
	stat.enabled = true
	stat.lines = H.items(20)
	text_adjust.enabled = true

	at(100, 10 + 42 + 21) -- over the topleft selector
	raw_binds['viewer:s']()
	h.eq('the selector moved down', 'bottomleft', sel._location)
	h.eq('the bottom-left block moved up in the trade', 'topleft', botl._location)

	at(100, 600 - 10 - 21) -- over the selector at its new corner
	raw_binds['viewer:d']()
	h.eq('the selector moved right into the status', 'status', sel._location)
	h.eq('the status box took the free bottom-left', 'bottomleft', stat._location)

	at(1200, 600 - 10 - 21) -- over the selector at the status line
	raw_binds['viewer:a']()
	h.eq('the selector moved back left', 'bottomleft', sel._location)
	h.eq('the status box traded back', 'status', stat._location)

	at(100, 600 - 10 - 21) -- back over the selector at bottom-left
	raw_binds['viewer:w']()
	h.eq('the selector moved up in the trade', 'topleft', sel._location)
	h.eq('the traded block took the free corner', 'bottomleft', botl._location)

	local recs = H.capture_notify(sai, function()
		at(100, 10 + 42 + 21) -- over the block now at topleft
		raw_binds['viewer:w']() -- the top edge has nothing above: no bind
	end)
	h.contains('a top block cannot trade up: the key went unassigned', recs[1].trace, 'api/mode_base.lua')
	h.eq('the top row stays put', 'bottomleft', botl._location)

	text_adjust.enabled = false
	sel.enabled, botl.enabled, stat.enabled = false, false, false
end)

-- A free spot takes the plain move: nothing swaps back, the content
-- follows the block.
T.wasd_plain_move_into_free_corner = with_env(function(h)
	local p = block('sai.mode.host.mover', 'bottomleft')
	text_adjust.enabled = true

	at(100, 600 - 10 - 21)
	raw_binds['viewer:d']() -- the status is empty
	h.eq('the block moved without a trade', 'status', p._location)
	h.ok('the content followed the block', (sai.text.status or ''):find '%S' ~= nil)

	text_adjust.enabled = false
	p.enabled = false
end)

-- The status counts as bottom center: 'a' trades it with bottom-left.
T.status_trades_as_bottom_center = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.host.status', _location = 'status', title = '' }
	local botl = block('sai.mode.host.botl', 'bottomleft')
	s.enabled = true
	s.lines = H.items(20)
	text_adjust.enabled = true

	at(1200, 600 - 10 - 21) -- over the status line
	raw_binds['viewer:a']()
	h.eq('the status box traded left', 'bottomleft', s._location)
	h.eq('the bottom-left block took the status', 'status', botl._location)

	text_adjust.enabled = false
	s.enabled, botl.enabled = false, false
end)

-- A notification owns the status line only visually: it registers no
-- binds, so the block owner stays the real status box.
T.notification_is_no_block_owner = with_env(function(h)
	local s = selector.new { _path = 'sai.mode.host.status', _location = 'status', title = '' }
	s.enabled = true
	s.lines = H.items(20)
	text_adjust.enabled = true
	h.eq('the status box owns the status block', s, text_adjust:owner_at 'status')

	H.capture_notify(sai, function() sai.notify 'a notice' end)
	h.eq('a notice does not take the block over', s, text_adjust:owner_at 'status')

	at(1200, 600 - 10 - 21)
	raw_binds['viewer:ScrollDown']() -- wheel down on a bottom block: shorter
	h.eq('the status box shrank under the notice', 0.9, s.max_height)

	text_adjust.enabled = false
	s.enabled = false
end)

-- A swap key only exists on the sections where it can trade: a left block
-- has nothing to its left, so 'TL+a' is no bind at all - the help display
-- cannot list a control that lies.
T.swap_keys_exist_only_where_they_trade = with_env(function(h)
	local m = text_adjust._mappings
	h.ok('a left block cannot trade left', m['TL+a'] == nil)
	h.ok('the bottom-left block cannot trade left', m['BL+a'] == nil)
	h.ok('a right block trades left', m['TR+a'] ~= nil)
	h.ok('the status trades left', m['ST+a'] ~= nil)
	h.ok('a top block cannot trade up', m['TL+w'] == nil)
	h.ok('a bottom block trades up', m['BL+w'] ~= nil)
	h.ok('a bottom block cannot trade down', m['BL+s'] == nil)
	h.ok('a top block trades down', m['TL+s'] ~= nil)
	h.ok('a right block cannot trade right', m['BR+d'] == nil)
	h.ok('a left block trades right', m['TL+d'] ~= nil)
	h.ok('the status trades right', m['ST+d'] ~= nil)
	h.ok('the bottom-right trades left into the status', m['BR+a'] ~= nil)
	h.ok('the status cannot trade up', m['ST+w'] == nil)
	h.ok('the status cannot trade down', m['ST+s'] == nil)
	h.ok('the wheel still covers the status', m['ST+ScrollUp'] ~= nil)
end)

-- The mode's state lives in its help display: the controls are listed
-- there, nothing is written into the status line.
T.help_display_lists_the_controls = with_env(function(h)
	text_adjust.enabled = true

	local lines = {}
	for _, line in ipairs(text_adjust.help_pager.lines) do
		lines[#lines + 1] = type(line) == 'string' and line or line.callback()
	end
	h.ok('the status line stays untouched', not (sai.text.status or ''):find '%S')

	text_adjust.enabled = false
end)

-- Off the blocks the swap and follow keys fall through to the unassigned
-- chain (the mode no longer pads them with quiet no-ops), and the help
-- display stays up for the mode's own controls.
T.off_block_keys_fall_through = with_env(function(h)
	text_adjust.enabled = true
	h.ok('the help display stays on', text_adjust.help_pager._enabled)

	local recs = H.capture_notify(sai, function()
		at() -- no pointer over a block: the section binds stay out of it
		raw_binds['viewer:w']()
		raw_binds['viewer:Shift+ScrollUp']()
	end)
	h.contains('the off-block keys go unassigned', recs[1].trace, 'api/mode_base.lua')

	-- the scroll box's viewer bind survives under the mode: the
	-- unqualified wheel never took a no-op (its raw pan stub over-indexes
	-- in this harness, so the mapping table is the probe)
	h.eq('the plain wheel keeps the viewer bind below', 'Pan up 20px', sai.viewer._mappings['ScrollUp'].desc)

	text_adjust.enabled = false
	h.eq('the viewer bind back where it was', 'Pan up 20px', sai.viewer._mappings['ScrollUp'].desc)
end)

H.maybe_standalone(T)

return T
