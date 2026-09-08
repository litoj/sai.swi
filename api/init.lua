---@diagnostic disable: invisible,inject-field
---@module 'sai.api.init'

local proxy = require 'sai.api.proxy'
local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'
require 'sai.bridge.cdef'

---@type sai
---@diagnostic disable-next-line: missing-fields
local M = {
	super = swayimg,
	_path = 'sai',
	initialized = false,

	_dnd_button = 'MouseRight',
	_overlay = true, -- enabled by default in sway and disabled otherwise
	_decoration = true,
	_antialiasing = true,
	_exif_orientation = true, -- automatically applied only to raw files
}

M._formats, M.set_formats = U.deep_backer({
	raw = { camera_wb = true },
	video = {
		size = 300,
		columns = 3,
		rows = 3,
		padding = 5,
		label = 0x0affffff,
	},
}, function(_, tbl) ---@param tbl FormatCfg all modified options
	swayimg.format_conf = tbl
	e.trigger { event = 'OptionSet', match = 'sai.formats', data = tbl }
end)

M.eventloop = e
M.imagelist = require 'sai.api.imagelist'
M.text = require 'sai.api.text'
do
	local viewer_proxy = require('sai.api.viewer').new
	M.viewer = viewer_proxy 'viewer'
	M.slideshow = viewer_proxy 'slideshow'
end
M.gallery = require 'sai.api.gallery'

function M.exit(code)
	local ev = { event = 'SwiLeavePre', match = tostring(code), data = code }
	e.trigger(ev)
	if not next(e.find_all(ev)) then swayimg.exit(code) end
end
local vars = require('sai.lib.registry').vars
-- the message layer: the status record holds the restore, the timeout is
-- never written through - the raw stays 0 for the display so the app's
-- expiry (its repaint is the flicker) never fires
---@diagnostic disable-next-line: assign-type-mismatch
local notify_layer = require('sai.lib.reconfigurer').new { super = M.text }
notify_layer(true)

-- only the latest notify may release: a superseded message leaves its
-- records to the successor
local generation = 0

function M.notify(msg, timeout)
	msg = string.gsub(tostring(msg), '\t', '  ')
	-- the option printers must not echo our writes back as new messages
	local muted = e.ignore_opts
	e.ignore_opts = true

	local prev = M.text.status_timeout
	if timeout == nil then timeout = prev ~= 0 and prev or -10 end
	if timeout < 0 then timeout = math.max(1, math.floor(#msg / -timeout + 0.5)) end

	generation = generation + 1
	local mine = generation

	-- the raw stays 0 for the display: the app's expiry (its repaint is
	-- the flicker) never fires, and the publicly known value stays
	swayimg.text.status_timeout = 0
	vars[M.text].status_timeout:set(notify_layer, { new = prev, old = prev })
	notify_layer.status = msg

	sai.defer_fn(function()
		if mine ~= generation then return end
		-- TODO: the timed restore's empty status write does not repaint
		-- (a forgotten redraw?): the message frame stays on screen until
		-- the next one - needs a proper look someday
		notify_layer.status = nil -- the special restores per the timeout
		swayimg.text.status_timeout = M.text.status_timeout
	end, timeout * 1000)
	e.ignore_opts = muted
end
function M.log(msg, file)
	if file then
		local f = io.open(file, 'a') or error('Could not append to file: ' .. file)
		f:write(tostring(msg))
		f:close()
	else
		M.notify(msg)
		print(msg)
	end
end

local deferred_heap = require 'sai.bridge.deferred_heap'
-- one armed swayimg.defer serves the whole heap: each fire pops the earliest
-- entry and re-arms. The flag keeps a push from arming a second fire - a
-- surplus fire pops past the heap's end, and the error inside the app's
-- callback kills every timer the app runs on
local pop_scheduled = false

local function schedule_pop()
	if pop_scheduled then return end
	local next_delay = deferred_heap:time_to_next() -- what is the earliest next cb to run
	if next_delay == nil then return end

	pop_scheduled = true
	swayimg.defer(math.max(next_delay, 1) / 1000, function()
		-- released before the cb: a defer_fn called inside it re-arms the
		-- chain, this fire only finishes its own pop
		pop_scheduled = false
		local cb = deferred_heap:pop()
		if cb then
			-- one bad callback must not kill the chain for the rest
			local ran, err = pcall(cb)
			if not ran then print('sai deferred callback error: ' .. tostring(err)) end
		end
		schedule_pop()
	end)
end

function M.defer_fn(cb, ms)
	if type(cb) == 'integer' then
		cb, ms = ms, cb
	end
	ms = ms or 1
	deferred_heap:push(ms, cb)
	schedule_pop()
end

--- for bw compatibility and ease of use
M.exec = require('sai.bridge.shell').exec

function M:get_app_id() return swayimg.appid end

---@param v appmode_t
function M:set_mode(v)
	local m = self.super.mode
	---@diagnostic disable-next-line: cast-local-type
	m = { event = 'ModeChangedPre', mode = m, match = ('%s:%s'):format(m:sub(1, 1), v:sub(1, 1)), data = v }
	e.trigger(m)
	self.super.mode = v
	m.event = 'ModeChanged'
	m.data = m.mode
	m.mode = v
	e.trigger(m)
	return false
end

function M:get_pid()
	rawset(self, 'pid', require('ffi').C.getpid())
	return self.pid
end

function M:get_cmdline()
	local args = {}
	local f = io.open(('/proc/%d/cmdline'):format(self.pid), 'rb') ---@type file*
	if f then
		for arg in (f:read '*a'):gmatch '[^%z]+' do
			args[#args + 1] = arg
		end
		f:close()
	end
	rawset(self, 'cmdline', args)
	return self.cmdline
end

function M.set_title(x) swayimg.title = x end

-- ensure even the default keymappings trigger our events by redefining the defaults
_G.sai = proxy.new(M)

local x
swayimg.on_window_resize(function()
	if x then -- handle as normal resize event
		local ws = swayimg.get_window_size()
		local ows = M._old_winsize
		if ows.width ~= ws.width or ows.height ~= ws.height then
			-- TODO: find a way to distinguish focus events from resizing (both can happen at once)
			e.trigger { event = 'WinResized', data = ws }
			M._old_winsize = ws
		end
	else -- handle as initialization
		-- deduplicate initial resizing
		if x == nil and not sai.overlay then
			x = false
			return
		elseif x == false and sai.mode ~= 'gallery' then
			x = sai[sai.mode]
			---@diagnostic disable-next-line: undefined-field
			x.scale = x._original_default_scale -- fix incorrect initial size with overlay disabled
		end

		x = true
		sai.initialized = true
		rawset(M, '_old_winsize', swayimg.get_window_size())

		-- resolve initial event
		local ev = { event = 'SwiEnter', data = false }
		e.trigger(ev)
		if e._hooks.SwiEnter then
			e._hooks.SwiEnter = nil

			-- easteregg
			local p = io.popen 'date +%d%m' or {}
			local o = p:read '*a'
			p:close()
			if o == '1003\n' then print [[Naughty, naughty! Didn't clean those hookers today...]] end
		end

		-- resolve lazy initiators
		ev.data = true
		e.subscribe {
			event = 'Subscribed',
			match = 'SwiEnter',
			-- ensure all hooks expecting initialization get loaded
			-- (especially the lazy ones not checking sai.initialized)
			callback = function(h)
				h.data.callback(ev)
				e._hooks.SwiEnter = nil
			end,
		}

		require('sai.binds').default()
		-- eager: key_help's eventloop hook powers the auto help display
		require 'sai.mode.key_help'
	end
end)

e.subscribe {
	event = 'Subscribed',
	match = 'Redraw',
	callback = function()
		swayimg.on_redrawn(function()
			e.trigger { event = 'Redraw' }
			if not e._hooks.Redraw then swayimg.on_redrawn(function() end) end
		end)
	end,
}

return M
