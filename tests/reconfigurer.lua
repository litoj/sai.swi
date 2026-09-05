---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for the reconfigurer: the __tostring representations and the special
---field functions (view field fallbacks, sai.text.enabled block takeover,
---sai.text.status borrow/restore).
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

-- The special field functions read the global api at runtime: run them over
-- the real api stack with a stubbed raw swayimg (same approach as tests/help.lua)
local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')

local function new_raw_mode()
	return setmetatable({
		get_image = function() return { width = 500, height = 400, index = 1, path = 'stub', meta = {} } end,
	}, {
		__index = function()
			return function() end
		end,
	})
end

local swayimg_stub = {
	mode = 'viewer',
	viewer = new_raw_mode(),
	slideshow = new_raw_mode(),
	gallery = new_raw_mode(),
	imagelist = { size = 0 },
	text = {},
	defer = function() end,
	on_window_resize = function() end,
	get_window_size = function() return { width = 800, height = 600 } end,
}

local sai_stack
local function with_env(fn)
	return function(h)
		if not sai_stack then -- in the full suite tests/help.lua has bound it already
			_G.swayimg = swayimg_stub
			sai_stack = require 'sai.api.init'
		end
		_G.sai = sai_stack
		_G.swayimg = rawget(sai_stack, 'super') -- the raw api the stack is bound to
		sai_stack.mode = 'viewer' -- earlier tests may have left another mode active
		local ran, err = pcall(fn, h)
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

T.view_field_fallback = with_env(function(h)
	local writes = {}
	-- no raw fields: every assignment must go through the tracker, like the
	-- real api always routes writes through its proxy setters
	local api = setmetatable({ _path = 'sai.viewer' }, {
		__index = function(_, k) return k == 'default_position' and 'fit' end,
		__newindex = function(_, k, v) writes[k] = v end,
	})

	local r = R.new { super = api }
	sai_stack.mode = 'gallery'
	r.position = 'center'
	r(true)
	h.ok('view field not applied out of its mode', writes.position == nil)

	sai_stack.mode = 'viewer'
	r(false) -- never applied: the fallback re-derives the view from its default
	h.eq('fallback restores the default', 'fit', writes.default_position)
	h.ok('no direct restore of the never-applied field', writes.position == nil)
end)

T.text_routing = with_env(function(h)
	sai_stack.text.topleft = { 'viewer text' }
	h.eq('write routed to the current mode', 'viewer text', sai_stack.viewer.text.topleft[1])

	sai_stack.mode = 'gallery'
	sai_stack.text.topleft = { 'gallery text' }
	h.eq('write routed to the new mode', 'gallery text', sai_stack.gallery.text.topleft[1])
	h.eq('other mode untouched', 'viewer text', sai_stack.viewer.text.topleft[1])
	h.eq('read routed back', 'gallery text', sai_stack.text.topleft[1])
end)

T.text_blank_and_restore = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	mode_text.bottomright = { 'also stale' }
	sai_stack.text.enabled = false -- the layer was off before the override

	local r = R.new { super = sai_stack }
	r.text.enabled = true
	r(true)

	h.eq('layer turned on', true, sai_stack.text.enabled)
	h.ok('stale topleft emptied', not next(mode_text.topleft))
	h.ok('stale bottomright emptied', not next(mode_text.bottomright))

	r(false)
	h.eq('layer back off', false, sai_stack.text.enabled)
	h.eq('topleft restored', 'stale', mode_text.topleft[1])
	h.eq('bottomright restored', 'also stale', mode_text.bottomright[1])
end)

T.text_no_blank_when_layer_on = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'live' }
	sai_stack.text.enabled = true

	local r = R.new { super = sai_stack }
	r.text.enabled = true
	r(true) -- the layer was already on: no emptying

	h.eq('kept the location', 'live', mode_text.topleft[1])
	r(false)
end)

T.text_blank_skips_own_vars = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	mode_text.bottomright = { 'also stale' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.topleft = { 'own content' } -- the mode's own block: not stale
	r.text.enabled = true
	r(true)

	h.eq('own block kept', 'own content', mode_text.topleft[1])
	h.ok('unclaimed block emptied', not next(mode_text.bottomright))

	r(false)
	h.eq('own block base restored', 'stale', mode_text.topleft[1])
	h.eq('emptied block restored', 'also stale', mode_text.bottomright[1])
end)

T.text_reset_removes_emptiers = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.enabled = true
	r(true)
	h.ok('emptied', not next(mode_text.topleft))

	r.text.enabled = nil -- reset the override
	h.eq('emptiers removed on reset', 'stale', mode_text.topleft[1])
	h.eq('layer back off', false, sai_stack.text.enabled)

	r.text.enabled = true -- re-enable: a fresh blank covers mid-session writes
	h.ok('re-emptied', not next(mode_text.topleft))

	r.text.enabled = nil -- resetting a var that was never set must not error
end)

T.text_no_reblank_when_user_enabled = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'user content' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.enabled = true
	r(true) -- blanks
	r(false) -- restores and removes the emptiers

	sai_stack.text.enabled = true -- the user enabled the layer themselves
	r(true) -- re-enable: the layer was already on, nothing may re-blank
	h.eq('user content kept', 'user content', mode_text.topleft[1])

	r(false)
end)

T.text_mode_change_bracket = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	local gallery_text = sai_stack.gallery.text
	mode_text.topleft = { 'viewer stale' }
	gallery_text.bottomright = { 'gallery stale' }
	sai_stack.text.enabled = false

	-- a persist mode survives appmode changes: the remapper brackets its tree
	-- around the flip, which restores the blocks into the old mode and re-blanks
	-- them into the new one
	local mode = require('sai.lib.remapper').new { _path = 'test.persist', persist_mode_change = true }
	mode.sai.text.enabled = true
	mode.enabled = true
	h.ok('viewer block emptied', not next(mode_text.topleft))

	sai_stack.mode = 'gallery' -- fires ModeChangedPre, then ModeChanged

	h.eq('restored into the old mode', 'viewer stale', mode_text.topleft[1])
	h.eq('layer still on', true, sai_stack.text.enabled)
	h.ok('re-blanked in the new mode', not next(gallery_text.bottomright))

	mode.enabled = false
	h.eq('new mode block restored', 'gallery stale', gallery_text.bottomright[1])
end)

T.text_display_override = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.enabled = true -- stored only: the tree stays off (display shape)
	h.eq('not applied while the tree is off', 'stale', mode_text.topleft[1])

	r.text(true) -- the display takes the text node up directly
	h.eq('layer on', true, sai_stack.text.enabled)
	h.ok('emptied', not next(mode_text.topleft))

	r.text(false)
	h.eq('layer off', false, sai_stack.text.enabled)
	h.eq('restored', 'stale', mode_text.topleft[1])
end)

T.status_restore_permanent = with_env(function(h)
	sai_stack.text.status_timeout = 0
	sai_stack.text.status = 'my status'

	local r = R.new { super = sai_stack }
	r.text.status = 'override'
	r(true)
	h.eq('override shown', 'override', sai_stack.text.status)

	r(false)
	h.eq('permanent status restored', 'my status', sai_stack.text.status)
end)

T.status_clears_transient = with_env(function(h)
	sai_stack.text.status_timeout = 3
	sai_stack.text.status = 'my status'

	local r = R.new { super = sai_stack }
	r.text.status = 'override'
	r(true)
	r(false)
	h.eq('timed status cleared', '', sai_stack.text.status)
end)

T.status_restore_uses_overridden_timeout = with_env(function(h)
	local r = R.new { super = sai_stack }

	-- input's shape: permanent only for our session, timed before it
	sai_stack.text.status_timeout = 5
	sai_stack.text.status = 'transient'
	r.text.status = 'override'
	r.text.status_timeout = 0
	r(true)

	r.text.status = nil -- the timeout var is still live: its original must decide
	h.eq('timed original cleared', '', sai_stack.text.status)
	h.eq('timeout still overridden', 0, sai_stack.text.status_timeout)
	r.text.status_timeout = nil

	-- the other way around: permanent before us, timed for our session
	sai_stack.text.status_timeout = 0
	sai_stack.text.status = 'permanent'
	r.text.status = 'override' -- the tree is still on: applies right away
	r.text.status_timeout = 5

	r.text.status = nil
	h.eq('permanent original restored', 'permanent', sai_stack.text.status)
	r.text.status_timeout = nil
	h.eq('timeout restored again', 0, sai_stack.text.status_timeout)
end)

T.capture_once = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'original' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.enabled = true
	r(true)
	h.ok('stale block emptied', not next(mode_text.topleft))

	-- updating our content: the emptier upgrades into a content var, its
	-- captured original must survive the rewrites
	r.text.topleft = { 'page 1' }
	r.text.topleft = { 'page 2' }
	h.eq('latest content shown', 'page 2', mode_text.topleft[1])

	r(false)
	h.eq('the original restored, not an intermediate write', 'original', mode_text.topleft[1])
end)

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
