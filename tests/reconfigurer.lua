---Tests for reconfigurer: tostring, stacks, special fields. Over synthetic apis.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local R = require 'sai.lib.reconfigurer'

local T = {}

-- ---------------------------------------------------------------------------
-- Generic unit tests: the module mechanics on synthetic apis
-- ---------------------------------------------------------------------------

T.tostring_default = function(h)
	local r = R.new { super = { _path = 'sai.fake', size = 10 } }
	r.size = 20
	r.position = 'center'
	local s = tostring(r)
	h.contains('tostring shows the override values', s, 'size=20')
	h.contains('string overrides quoted', s, 'position="center"')
end

-- (the evloop tostring lives in tests/reconfigurer_evloop.lua)

-- The override stacks: layers enabled and disabled in differing orders. The
-- screen always shows the topmost override; a restore from below the top
-- hands its reset value up instead of writing it.
T.stack_out_of_order = function(h)
	local api = { _path = 'sai.fake', size = 'base' }
	local a, b, c = R.new { super = api }, R.new { super = api }, R.new { super = api }
	a(true)
	b(true)
	c(true)
	a.size = 'a'
	b.size = 'b'
	c.size = 'c'
	h.eq('the topmost write owns the field', 'c', api.size)

	b(false) -- the middle layer: the top keeps the screen, its restore target moves down
	h.eq('top value kept through the middle disable', 'c', api.size)

	a(false) -- the bottom layer: the value chain above it must not decay
	h.eq('top value kept through the bottom disable', 'c', api.size)

	b(true) -- a re-enable lands on top with a fresh capture
	h.eq('re-enabled layer is on top', 'b', api.size)

	c(false) -- now below b: hands its reset value up, no write
	h.eq('new top value kept', 'b', api.size)

	b(false)
	h.eq('unwinds straight to the baseline', 'base', api.size)
end

-- release() with save_user_changes captures the live value, so a re-enable
-- replays a direct edit made behind the override instead of the stale value.
T.release_replays_live_value_when_saving = function(h)
	local api = { _path = 'sai.fake', size = 'base' }
	local r = R.new { super = api }
	r.save_user_changes = true
	r(true)
	r.size = 'mine'
	api.size = 'user-edit' -- a direct write behind the override
	r(false)
	h.eq('unwinds to the baseline', 'base', api.size)
	r(true)
	h.eq('re-enable replays the live value', 'user-edit', api.size)

	local plain = R.new { super = api }
	plain(true)
	plain.size = 'mine'
	api.size = 'user-edit'
	plain(false)
	plain(true)
	h.eq('without saving the stale value re-applies', 'mine', api.size)
end

T.stack_update_from_below = function(h)
	local api = { _path = 'sai.fake', size = 'base' }
	local a, b = R.new { super = api }, R.new { super = api }
	a(true)
	b(true)
	a.size = 'a'
	b.size = 'b'

	a.size = 'a2' -- a write from below the top takes the field over
	h.eq('a write from below overrides the top', 'a2', api.size)

	b(false) -- now below a: hands its reset value up, no write
	h.eq('top value kept through the lower disable', 'a2', api.size)

	a(false)
	h.eq('unwinds straight to the baseline', 'base', api.size)
end

-- ---------------------------------------------------------------------------
-- Usability tests: the special fields over the real api stack, driven the
-- way the modes drive them
-- ---------------------------------------------------------------------------

-- The special field functions read the global api at runtime: run them over
-- the real api stack with a stubbed raw swayimg (same approach as tests/help.lua)

local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')

local swayimg_stub = H.raw_swayimg()

local sai_stack
local function with_env(fn)
	return function(h)
		if not sai_stack then
			-- rebind a pristine stack lazily: whichever module ran before
			-- this one (help.lua in the full suite) leaves its records on
			-- the shared registry, keyed by that stack's objects
			sai_stack = H.fresh_api_stack(swayimg_stub)
		end
		_G.sai = sai_stack
		_G.swayimg = rawget(sai_stack, 'super') -- the raw api the stack is bound to
		sai_stack.mode = 'viewer' -- earlier tests may have left another mode active
		local ran, err = pcall(fn, h)
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

T.derived_field_fallback = with_env(function(h)
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
	h.eq('read routes back to the mode', 'gallery text', sai_stack.text.topleft[1])
end)

T.text_blank_and_restore = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	mode_text.bottomright = { 'also stale' }
	sai_stack.text.enabled = false -- the layer was off before the override

	local r = R.new { super = sai_stack }
	r.text.bottomleft = { 'content' } -- a block write arms the layer itself
	r(true)

	h.eq('layer turned on by the write', true, sai_stack.text.enabled)
	h.eq('written content shown', 'content', mode_text.bottomleft[1])
	h.ok('stale topleft emptied', not next(mode_text.topleft))
	h.ok('stale bottomright emptied', not next(mode_text.bottomright))

	r(false)
	h.eq('layer turns back off', false, sai_stack.text.enabled)
	h.eq('topleft restored', 'stale', mode_text.topleft[1])
	h.eq('bottomright restored', 'also stale', mode_text.bottomright[1])
end)

T.text_no_blank_when_layer_on = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'live' }
	sai_stack.text.enabled = true

	local r = R.new { super = sai_stack }
	r.text.bottomright = { 'own' } -- a block write, but the layer was already on
	r(true)

	h.eq('live block keeps its content', 'live', mode_text.topleft[1])
	r(false)
end)

T.text_blank_skips_own_vars = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	mode_text.bottomright = { 'also stale' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.topleft = { 'own content' } -- the mode's own block: not stale
	r(true)

	h.eq('own block kept', 'own content', mode_text.topleft[1])
	h.ok('unclaimed block emptied', not next(mode_text.bottomright))

	r(false)
	h.eq('own block base restored', 'stale', mode_text.topleft[1])
	h.eq('emptied block restored', 'also stale', mode_text.bottomright[1])
end)

T.text_reset_keeps_layer_and_blanks = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	mode_text.bottomright = { 'base' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.bottomright = { 'own content' }
	r(true)
	h.ok('stale block emptied', not next(mode_text.topleft))

	r.text.enabled = nil -- the live content is the config default now
	h.eq('layer kept by the content', true, sai_stack.text.enabled)
	h.ok('the blank kept with the layer', not next(mode_text.topleft))
	h.eq('content still shown', 'own content', mode_text.bottomright[1])

	r.text.bottomright = { 'fresh' } -- a fresh write: the layer was never off
	h.ok('no re-blank needed', not next(mode_text.topleft))

	r.text.enabled = nil -- resetting the re-armed layer var must not error

	r(false) -- the reset was final: the layer's pre-state is gone with the var
	h.eq('stale block restored', 'stale', mode_text.topleft[1])
	h.eq('own block base restored', 'base', mode_text.bottomright[1])
	h.eq('layer stays at the default', true, sai_stack.text.enabled)
end)

T.location_reset_retires_system_layer = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.bottomright = { 'own content' }
	r(true)
	h.eq('layer armed by the write', true, sai_stack.text.enabled)

	r.text.bottomright = nil -- the last location: the system default retires
	h.eq('layer restored', false, sai_stack.text.enabled)
	h.eq('stale block restored', 'stale', mode_text.topleft[1])
end)

T.location_reset_keeps_enforced_layer = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r(true)
	r.text.enabled = true -- the user enforces the layer themselves
	r.text.bottomright = { 'own content' }

	r.text.bottomright = nil -- an enforced layer outlives the location
	h.eq('layer stays enforced', true, sai_stack.text.enabled)
	h.ok('the blank kept with the layer', not next(mode_text.topleft))

	r(false)
	h.eq('layer restored', false, sai_stack.text.enabled)
end)

T.status_reset_retires_system_pin = with_env(function(h)
	sai_stack.text.status_timeout = 5

	local r = R.new { super = sai_stack }
	r(true)
	r.text.status = 'prompt' -- the write pins the timeout
	h.eq('write pins the timeout', 0, sai_stack.text.status_timeout)

	r.text.status = nil -- the status is gone: the pin has nothing to serve
	h.eq('pin retires with the status', 5, sai_stack.text.status_timeout)
end)

T.status_reset_keeps_enforced_pin = with_env(function(h)
	local r = R.new { super = sai_stack }
	r(true)
	r.text.status_timeout = 2 -- the user manages the expiry themselves
	r.text.status = 'prompt'
	h.eq('user timeout kept', 2, sai_stack.text.status_timeout)

	r.text.status = nil -- an enforced timeout outlives the status
	h.eq('timeout stays enforced', 2, sai_stack.text.status_timeout)
end)

T.text_no_reblank_when_user_enabled = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'user content' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.bottomright = { 'own content' }
	r(true) -- blanks
	r(false) -- restores and removes the emptiers

	sai_stack.text.enabled = true -- the user enabled the layer themselves
	r(true) -- re-enable: the layer was already on, nothing may re-blank
	h.eq('user content kept', 'user content', mode_text.topleft[1])

	r(false)
end)

T.status_timeout_reset_keeps_pin_for_status = with_env(function(h)
	sai_stack.text.status_timeout = 5

	local r = R.new { super = sai_stack }
	r(true)
	r.text.status = 'prompt' -- the write pins the timeout
	h.eq('write pins the timeout', 0, sai_stack.text.status_timeout)

	r.text.status_timeout = nil -- the live status is the config default now
	h.eq('pin kept by the status', 0, sai_stack.text.status_timeout)

	r(false) -- the reset was final: the timeout's pre-state is gone with the var
	h.eq('pin stays at the default', 0, sai_stack.text.status_timeout)
end)

T.text_display_override = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.topleft = { 'stale' }
	sai_stack.text.enabled = false

	local r = R.new { super = sai_stack }
	r.text.bottomright = { 'own content' } -- stored only: the tree stays off (display shape)
	h.eq('stored write stays unapplied while the tree is off', 'stale', mode_text.topleft[1])

	r.text(true) -- the display takes the text node up directly
	h.eq('write turns the layer on', true, sai_stack.text.enabled)
	h.ok('stale block emptied', not next(mode_text.topleft))

	r.text(false)
	h.eq('layer turns off with the restore', false, sai_stack.text.enabled)
	h.eq('stale content restored', 'stale', mode_text.topleft[1])
end)

T.status_restore_permanent = with_env(function(h)
	sai_stack.text.status_timeout = 0
	sai_stack.text.status = 'my status'

	local r = R.new { super = sai_stack }
	r.text.status = 'override'
	r(true)
	h.eq('override status shows', 'override', sai_stack.text.status)

	r(false)
	h.eq('permanent status restored', 'my status', sai_stack.text.status)
end)

T.status_aligns_to_a_block = with_env(function(h)
	sai_stack.text.status_timeout = 0
	sai_stack.text.status = 'my status'

	local r = R.new { super = sai_stack }
	r.text.status = 'aa\nb'
	r(true)
	h.eq('the applied status pads its lines', 'aa\nb ', sai_stack.text.status)
	h.eq('the configurer stores the padded status', 'aa\nb ', r.text.status.new)

	r.text.status = 'multi\nline\nbook'
	h.eq('the re-set status pads its lines', 'multi\nline \nbook ', sai_stack.text.status)
	h.eq('the configurer stores the re-set padding', 'multi\nline \nbook ', r.text.status.new)

	r.text.status = 'plain' -- single line: no padding
	h.eq('single-line status stays untouched', 'plain', sai_stack.text.status)

	r(false)
	h.eq('permanent status restored', 'my status', sai_stack.text.status)
end)

T.status_clears_transient = with_env(function(h)
	sai_stack.text.status_timeout = 3
	sai_stack.text.status = 'my status'

	local r = R.new { super = sai_stack }
	r.text.status = 'override'
	r(true)
	h.eq('a configurer status is pinned permanent', 0, sai_stack.text.status_timeout)
	r(false)
	h.eq('timed status cleared', ' ', sai_stack.text.status)
	h.eq('the pin released with the status', 3, sai_stack.text.status_timeout)
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
	h.eq('the timed original status cleared', ' ', sai_stack.text.status)
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
	r.text.bottomright = { 'own content' } -- a block write arms the layer
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

-- The text layer must come up only after the tree's text blocks landed:
-- an `enabled` var applied before its blocks shows the stale content for a
-- frame. An inner var is applied last, so the blocks are in first.
T.text_layer_enables_after_its_blocks = with_env(function(h)
	local mode_text = sai_stack.viewer.text
	mode_text.bottomright = { 'base' } -- pre-existing content to restore
	sai_stack.text.enabled = false

	-- `visible` already sits on the double, so __newindex never fires -
	-- catch the layer-up in the setter instead
	local at_layer_on
	local text_api = require 'sai.api.text'
	local orig_set_enabled = text_api.set_enabled
	text_api.set_enabled = function(...)
		local res = orig_set_enabled(...)
		-- landed block content at layer-up, through the public block
		if select(2, ...) == true then at_layer_on = mode_text.bottomright and mode_text.bottomright[1] end
		return res
	end

	local r = R.new { super = sai_stack }
	r.text.enabled = true
	r.text.bottomright = { 'own' }
	r(true)

	h.eq('the layer comes up after the block landed', 'own', at_layer_on)
	h.eq('written block shows', 'own', mode_text.bottomright[1])

	text_api.set_enabled = orig_set_enabled
	r(false)
end)

-- A `scale` released from a parked state refreshes its fallback
-- `default_scale`; when that fallback only ever parked (its records hold no
-- `old`), the refresh must not write nil into the app field.
T.scale_special_never_nils_the_fallback = with_env(function(h)
	-- the real app answers no default_scale until its first write
	local store = { scale = 1.0 }
	local base = _G.swayimg.viewer
	local raw_mt = getmetatable(base)
	setmetatable(base, {
		__index = function(t, k)
			if k == 'default_scale' then return rawget(store, 'default_scale') end
			if k == 'scale' then return store.scale end
			return raw_mt.__index(t, k)
		end,
		__newindex = function(t, k, v)
			if k == 'default_scale' or k == 'scale' then
				rawset(store, k, v)
			else
				rawset(t, k, v)
			end
		end,
	})

	local r = R.new { super = sai_stack }
	sai_stack.mode = 'gallery' -- viewer scale cannot apply: stays parked
	r.viewer.scale = 0.23
	r.viewer.default_scale = 'keep_width' -- no gate: applies, capturing a nil old
	r(true)
	sai_stack.mode = 'viewer' -- the parked scale becomes applicable on release
	r(false)
	h.ok('the fallback is never nil-ed', rawget(store, 'default_scale') ~= nil)
end)

-- A timed status must be written only after its timeout is in effect, so
-- the app's native expiry governs the message: the status write must never
-- find the raw timeout still pinned to the pre-state.
T.status_set_after_its_timeout = with_env(function(h)
	sai_stack.text.status_timeout = 0 -- the pre-state: a permanent pin
	local r = R.new { super = sai_stack }
	r.text.status_timeout = 4 -- the message is timed
	r.text.status = 'hi'

	local order = {}
	local sub = r.text
	local orig = sub._apply_record
	sub._apply_record = function(selff, field, override)
		order[#order + 1] = field
		return orig(selff, field, override)
	end
	r(true)

	local i_timeout, i_status
	for i, f in ipairs(order) do
		if f == 'status_timeout' then i_timeout = i end
		if f == 'status' then i_status = i end
	end
	h.ok('the timeout applies before the status', i_timeout ~= nil and i_status ~= nil and i_timeout < i_status)

	r(false)
end)

H.maybe_standalone(T)

return T
