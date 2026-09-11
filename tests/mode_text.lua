---Tests for sai.api.mode_text: per-mode schemes, takeover blanking, and
---visibility gating (no hooks or callbacks unless on screen).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack { 'sai.mode.editor' }
local with_env = env.with_env

local T = {}

-- Write counter as an instrument: the writes are real, final state cannot
-- express their number (one catch-up write vs none). Returns the counter
-- and a restore (the shared env outlives the test).
local function watch_writes(env)
	local writes = 0
	local viewer = env.swayimg.viewer
	local orig_mt = getmetatable(viewer)
	setmetatable(viewer, {
		__index = orig_mt.__index,
		__newindex = function(t, k, v)
			rawset(t, k, v)
			if k == 'text' then
				writes = writes + 1
				rawset(t, k, nil) -- force every write through the hook
			end
		end,
	})
	return function() return writes end, function() setmetatable(viewer, orig_mt) end
end

T.cmd_enable_keeps_the_corners_blank = with_env(function(h)
	env.sai.text.enabled = false -- the user setup: no text overlay

	local editor = env.mods['sai.mode.editor'].new { _path = 'sai.mode.editor' }
	editor.enabled = true

	-- placements as the app holds them (blanked corners land empty)
	local text = env.swayimg.viewer.text or {}
	local function lines(loc)
		local n = 0
		for _ in pairs(text[loc] or {}) do
			n = n + 1
		end
		return n
	end

	h.ok('the auto help shows its corner', lines 'topright' > 0)
	h.eq('topleft blanked by the takeover', 0, lines 'topleft')
	h.eq('bottomleft blanked by the takeover', 0, lines 'bottomleft')
	-- no app default on bottomright: no write (or a blank) is the right outcome
	h.eq('bottomright holds no content', 0, lines 'bottomright')

	editor.enabled = false -- release the takeover: its emptier vars retire with the pager
end)

-- The takeover must retire the dynamic schemes: a surviving hook would
-- re-write its lines on the next image, over the takeover's emptier
T.takeover_retires_the_dynamic_schemes = with_env(function(h)
	env.sai.text.enabled = false -- the user setup: no text overlay
	env.sai.viewer.text.topleft = { 'File:\t{name}', 'EXIF:\t{ExposureTime}' }

	local editor = env.mods['sai.mode.editor'].new { _path = 'sai.mode.editor' }
	editor.enabled = true
	local text = env.swayimg.viewer.text or {}
	local function snapshot()
		local out = {}
		for _, line in ipairs(text.topleft or {}) do
			out[#out + 1] = tostring(line)
		end
		return table.concat(out, '\n')
	end
	local blanked = snapshot() -- baseline before the event

	-- the app moves to another image
	require('sai.api.eventloop').trigger {
		event = 'ImgChanged',
		match = 'viewer',
		data = { meta = {} },
	}

	h.eq('the blanked location stays blank over image changes', blanked, snapshot())
end)

-- The off layer makes mode_text fully passive; enabling it catches the
-- blocks up in one pass, disabling restores the passivity.
T.disabled_layer_processes_nothing = with_env(function(h)
	env.sai.text.enabled = false -- the user setup: no text overlay

	-- drop any block content other tests (arbitrary order) left tracked
	for _, p in ipairs { 'topleft', 'topright', 'bottomleft', 'bottomright' } do
		env.sai.viewer.text[p] = {}
	end

	-- every processing kind (static, fn, dyntext) must stay silent off,
	-- run exactly once per update on
	local calls = 0
	env.sai.viewer.text.topleft = {
		'static',
		function()
			calls = calls + 1
			return 'fn'
		end,
		{
			event = 'OptionSet',
			match = 'sai.viewer.scale',
			callback = function()
				calls = calls + 10
				return 'dyn'
			end,
		},
	}

	-- counts need the instrument
	local writes, restore_writes = watch_writes(env)

	local trigger = require('sai.api.eventloop').trigger

	-- while off: neither image changes nor variable updates may process
	trigger { event = 'ImgChanged', match = 'viewer', data = {} }
	trigger { event = 'OptionSet', match = 'sai.viewer.scale', data = 2 }
	h.eq('no processing while disabled', 0, calls)
	h.eq('no raw writes while disabled', 0, writes())

	-- enabling: exactly one catch-up pass (dyntext load + fn render)
	env.sai.text.enabled = true
	h.eq('the catch-up pass runs once', 11, calls)
	h.eq('the catch-up write lands', 1, writes())

	-- live again: one write per update
	trigger { event = 'OptionSet', match = 'sai.viewer.scale', data = 3 }
	h.eq('the dyntext hook is live again', 21, calls)
	h.eq('the dyntext write landed', 2, writes())

	-- disabling: passive again
	env.sai.text.enabled = false
	trigger { event = 'OptionSet', match = 'sai.viewer.scale', data = 4 }
	trigger { event = 'ImgChanged', match = 'viewer', data = {} }
	h.eq('the layer stays passive after the disable', 21, calls)
	h.eq('no writes after the disable', 2, writes())
	restore_writes()
end)

-- A mode change also silences the updates: the app fires events under the
-- new mode's name, so the old mode's hooks stay untouched
T.foreign_mode_stays_passive = with_env(function(h)
	env.sai.text.enabled = true -- only the mode gates the updates here

	for _, p in ipairs { 'topleft', 'topright', 'bottomleft', 'bottomright' } do
		env.sai.viewer.text[p] = {}
	end

	local calls = 0
	env.sai.viewer.text.topleft = {
		function()
			calls = calls + 1
			return 'fn'
		end,
		{
			event = 'OptionSet',
			match = 'sai.viewer.scale',
			callback = function()
				calls = calls + 10
				return 'dyn'
			end,
		},
	}
	local base = calls -- the config-time pass over the block

	-- counts need the instrument
	local writes, restore_writes = watch_writes(env)

	local trigger = require('sai.api.eventloop').trigger

	-- enter another mode: the viewer's blocks must not process anything
	env.swayimg.mode = 'gallery'
	trigger { event = 'ImgChanged', match = 'gallery', data = {} }
	trigger { event = 'OptionSet', match = 'sai.viewer.scale', data = 2 }
	h.eq('no processing in a foreign mode', base, calls)
	h.eq('no raw writes in a foreign mode', 0, writes())

	-- back in the viewer: the updates flow again
	env.swayimg.mode = 'viewer'
	trigger { event = 'ImgChanged', match = 'viewer', data = {} }
	h.eq('the updates resume on return', base + 1, calls)
	h.eq('the render landed', 1, writes())

	-- leave the stack clean for the other tests (arbitrary order)
	env.sai.text.enabled = false
	restore_writes()
end)

-- Visibility gating over private uninitialized stacks (no shared state).
local function fresh_env()
	local resize_cb
	local swayimg_stub = H.raw_swayimg()
	swayimg_stub.on_window_resize = function(fn) resize_cb = fn end
	local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')
	local stack, sai_proxy = H.fresh_api_stack(swayimg_stub)
	_G.swayimg, _G.sai = old_swi, old_sai

	local env = { sai = stack, sai_proxy = sai_proxy, swayimg = swayimg_stub }
	function env.init() resize_cb() end
	return env
end

-- lend a private stack for the duration of the body
local function with_fresh(fn)
	return function(h)
		local env = fresh_env()
		local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')
		_G.swayimg, _G.sai = env.swayimg, env.sai_proxy
		local ran, err = pcall(fn, h, env)
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

local function vis_el() return require 'sai.api.eventloop' end

local function count_hooks(f)
	local n = 0
	for _ in pairs(vis_el().find_all(f)) do
		n = n + 1
	end
	return n
end

local VG = 'viewer.dyntext.topleft'
local GG = 'gallery.dyntext.topleft'

local function viewer_block(calls)
	return {
		'static',
		function()
			calls.fn = calls.fn + 1
			return 'fn'
		end,
		{
			event = 'OptionSet',
			match = 'sai.viewer.scale',
			callback = function()
				calls.dyn = calls.dyn + 1
				return 'dyn'
			end,
		},
	}
end

local function gallery_block(calls)
	return {
		function()
			calls.fn = calls.fn + 1
			return 'gfn'
		end,
		{
			event = 'OptionSet',
			match = 'sai.text.size',
			callback = function()
				calls.dyn = calls.dyn + 1
				return 'gdyn'
			end,
		},
	}
end

local function fire_viewer_events()
	vis_el().trigger { event = 'ImgChanged', match = 'viewer', data = { meta = {} } }
	vis_el().trigger { event = 'OptionSet', match = 'sai.viewer.scale', data = 2 }
end

T.vis_no_hooks_no_work_before_init = with_fresh(function(h, env)
	env.sai.text.enabled = true
	local writes = watch_writes(env)
	local calls = { fn = 0, dyn = 0 }
	env.sai.viewer.text.topleft = viewer_block(calls)

	h.eq('no placement hooks before SwiEnter', 0, count_hooks { group = VG })
	fire_viewer_events()
	h.eq('no fn work before SwiEnter', 0, calls.fn)
	h.eq('no dyn work before SwiEnter', 0, calls.dyn)
	h.eq('no raw writes before SwiEnter', 0, writes())
end)

T.vis_init_arms_current_mode_once = with_fresh(function(h, env)
	env.sai.text.enabled = true
	local writes = watch_writes(env)
	local calls = { fn = 0, dyn = 0 }
	env.sai.viewer.text.topleft = viewer_block(calls)

	env.init() -- window opens: SwiEnter fires

	h.eq('fn flushed once on init', 1, calls.fn)
	h.eq('dyn flushed once on init', 1, calls.dyn)
	h.eq('one raw write on init', 1, writes())
	h.eq('placement hooks armed (ImgChanged + dyntext)', 2, count_hooks { group = VG })
end)

T.vis_disable_removes_hooks = with_fresh(function(h, env)
	env.sai.text.enabled = true
	local writes = watch_writes(env)
	local calls = { fn = 0, dyn = 0 }
	env.sai.viewer.text.topleft = viewer_block(calls)
	env.init()

	local base_fn, base_dyn, base_writes = calls.fn, calls.dyn, writes()
	env.sai.text.enabled = false

	h.eq('hooks removed on disable', 0, count_hooks { group = VG })
	fire_viewer_events()
	h.eq('no fn work while disabled', base_fn, calls.fn)
	h.eq('no dyn work while disabled', base_dyn, calls.dyn)
	h.eq('no raw writes while disabled', base_writes, writes())
end)

T.vis_enable_catches_up_once = with_fresh(function(h, env)
	env.sai.text.enabled = true
	local writes = watch_writes(env)
	local calls = { fn = 0, dyn = 0 }
	env.sai.viewer.text.topleft = viewer_block(calls)
	env.init()
	env.sai.text.enabled = false

	local base_fn, base_dyn, base_writes = calls.fn, calls.dyn, writes()
	env.sai.text.enabled = true

	h.eq('hooks back on enable', 2, count_hooks { group = VG })
	h.eq('fn caught up once', base_fn + 1, calls.fn)
	h.eq('dyn caught up once', base_dyn + 1, calls.dyn)
	h.eq('one catch-up write', base_writes + 1, writes())
end)

T.vis_mode_switch_moves_hooks = with_fresh(function(h, env)
	env.sai.text.enabled = true
	local writes = watch_writes(env)
	local vcalls = { fn = 0, dyn = 0 }
	local gcalls = { fn = 0, dyn = 0 }
	env.sai.viewer.text.topleft = viewer_block(vcalls)
	env.init()
	env.sai.gallery.text.topleft = gallery_block(gcalls)

	h.eq('foreign block parks without hooks', 0, count_hooks { group = GG })

	env.sai.mode = 'gallery'
	h.eq('old mode hooks retired', 0, count_hooks { group = VG })
	h.eq('new mode hooks armed', 2, count_hooks { group = GG })

	local base_fn, base_dyn = vcalls.fn, vcalls.dyn
	env.sai.mode = 'viewer'
	h.eq('returning re-arms the hooks', 2, count_hooks { group = VG })
	h.eq('returning re-renders the fns', base_fn + 1, vcalls.fn)
	h.eq('returning reloads the dyntext', base_dyn + 1, vcalls.dyn)
	h.ok('returning writes the block', writes() > 0)
end)

-- The app switches its C mode only between ModeChangedPre and ModeChanged:
-- arming the incoming mode on Pre would call its api while inactive.
T.vis_pre_change_keeps_the_incoming_mode_parked = with_fresh(function(h, env)
	env.sai.text.enabled = true

	-- model the C api: get_image refuses to work before the switch lands
	local get_calls = 0
	local gallery = env.swayimg.gallery
	gallery.get_image = function()
		get_calls = get_calls + 1
		if env.swayimg.mode ~= 'gallery' then error('mode not active', 2) end
		return H.stub_image()
	end

	env.sai.gallery.text.topleft = { function(img) return tostring(img.width) end }
	env.init() -- SwiEnter: the current mode (viewer) arms, gallery stays parked

	h.eq('the incoming block parks without hooks', 0, count_hooks { group = GG })

	-- the Pre half of the switch, exactly as set_mode fires it
	vis_el().trigger { event = 'ModeChangedPre', mode = 'viewer', data = 'gallery' }
	h.eq('no api reads before the switch lands', 0, get_calls)
	h.eq('no hooks armed before the switch lands', 0, count_hooks { group = GG })

	-- the switch itself: set_mode updates the C mode and the modes[1] head
	env.sai.mode = 'gallery'
	h.eq('the switch arms the block', 1, count_hooks { group = GG })
	h.eq('the catch-up render reads the active api', 1, get_calls)
	local text = env.swayimg.gallery.text or {}
	h.eq('the catch-up line landed', '500', (text.topleft or {})[1])
end)

-- Scroll baseline; armed-state rendering is out of scope.
T.vis_scroll_cost_per_image_baseline = with_fresh(function(h, env)
	env.sai.text.enabled = true
	local writes = watch_writes(env)
	local calls = { fn = 0, dyn = 0 }
	env.sai.viewer.text.topleft = viewer_block(calls)
	env.init()

	local base_fn, base_writes = calls.fn, writes()
	for _ = 1, 20 do
		vis_el().trigger { event = 'ImgChanged', match = 'viewer', data = { meta = {} } }
	end
	h.eq('one fn render per image', base_fn + 20, calls.fn)
	h.eq('one raw write per image', base_writes + 20, writes())
end)

-- The construction seeds never pass __newindex: new() measures them once.
T.seeds_get_measured = with_fresh(function(h, env)
	local mt = env.sai.viewer.text
	-- the tab splits the columns: the key width plus the value width, no cell for the delimiter
	h.eq('the topright seed measured', #'Frame:' + #'{frame.index} of {frame.total}', mt._metrics.topright.cells)
	h.eq('the seed line is a key/value layout', true, mt._metrics.topright.kv)
end)

-- The longest rendered line per placement, kept up to date on every
-- flush: the mouse box matches pointer positions against it.
T.metrics_track_the_longest_line = with_env(function(h)
	env.sai.text.enabled = true

	local mt = env.sai.viewer.text
	for _, p in ipairs { 'topleft', 'topright', 'bottomleft', 'bottomright' } do
		mt[p] = {}
	end

	mt.topleft = { 'short', 'a much longer line' }
	h.eq('the static write measures the longest line', 18, mt._metrics.topleft.cells)

	-- the event answers a longer line than the catch-up pass
	mt.topleft = {
		'static',
		{
			event = 'OptionSet',
			match = 'sai.viewer.scale',
			callback = function(ev) return ev and 'a much longer dyn line' or 'dyn' end,
		},
	}
	h.eq('the catch-up render measures the lines', 6, mt._metrics.topleft.cells)

	require('sai.api.eventloop').trigger { event = 'OptionSet', match = 'sai.viewer.scale', data = 2 }
	h.eq('the event update re-measures the lines', 22, mt._metrics.topleft.cells)

	mt.topleft = {}
	h.eq('a cleared block has no span', 0, mt._metrics.topleft.cells)

	env.sai.text.enabled = false
end)

-- template compilers: one hole per line for exif, any lowercase holes
-- for image data, sai paths through the event or a full render
T.template_compilers = with_env(function(h)
	local mt = require 'sai.api.mode_text'
	local img = {
		meta = { ['Exif.Photo.ExposureTime'] = '1/250' },
		name = 'p.png',
		width = 500,
		height = 400,
	}
	h.eq('exif hole fills', 'Exposure: 1/250', mt.generate_exif_updater 'Exposure: {ExposureTime}'(img))
	h.eq('missing exif blanks the line', '', mt.generate_exif_updater 'Exposure: {Nope}' { meta = {} })
	h.eq(
		'image holes fill repeatedly',
		'File p.png (500x400)',
		mt.generate_img_data_updater 'File {name} ({width}x{height})'(img)
	)

	env.sai.text.size = 42
	local vu = mt.generate_var_updater('Size {sai.text.size}', { 'sai.text.size' })
	h.eq('full render reads sai', 'Size 42', vu.callback(nil))
	h.eq('event takes the fast path', 'Size 99', vu.callback { data = 99, match = 'sai.text.size' })
end)

H.maybe_standalone(T)

return T
