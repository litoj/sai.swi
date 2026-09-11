---@diagnostic disable: inject-field
---@module 'sai.api.init'

local proxy = require 'sai.api.proxy'
local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'
local viewer = require 'sai.api.viewer'
local binds = require 'sai.binds'
local ffi = require 'ffi'
require 'sai.bridge.cdef'

---@class sai.api: sai
local M = {
	super = swayimg,
	_path = 'sai',
	initialized = false,

	_dnd_button = 'MouseRight',
	_overlay = true,
	_decoration = true,
	_antialiasing = true,
	_exif_orientation = true, ---automatically applied only to raw files

	_fullscreen = false, ---@deprecated proxy faking value, not actually used
	_mode = 'viewer', ---@deprecated proxy faking value, but we use swayimg.mode getter

	_old_winsize = false, ---@type {width:integer,height:integer}|boolean
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
	local viewer_proxy = viewer.new
	M.viewer = viewer_proxy 'viewer'
	M.slideshow = viewer_proxy 'slideshow'
end
M.gallery = require 'sai.api.gallery'

---Currently active modes: [1] the app mode, and custom modes stack order. See lib.remapper
M.modes = { M[swayimg.mode] }

function M.exit(code)
	local ev = { event = 'SwiLeavePre', match = tostring(code), data = code }
	e.trigger(ev)
	if not next(e.find_all(ev)) then swayimg.exit(code) end
end
local vars = require('sai.lib.registry').vars
---@type sai.lib.reconfigurer.text
local notify_layer = require('sai.lib.reconfigurer').new { super = M.text, _enabled = true }
-- one hider per location: a block's expiry must not cancel another block's
local hider_debounces = {}

---@param msg string
---@param timeout? number display seconds, negative for chars per second
---@param location? string text block to show on, the status by default
function M.notify(msg, timeout, location)
	msg = U.align_block(string.gsub(tostring(msg), '\t', '  '))
	location = location or 'status'
	local hider = hider_debounces[location] or U.debounce()
	hider_debounces[location] = hider

	-- the option printers must not echo our writes back as new messages
	local muted = e.ignore_opts
	e.ignore_opts = true

	if location == 'status' then
		-- register our change, but don't change the checked place (sai.text.st) so that others read the
		-- actual current setting and ignore this temporary change
		-- TODO: can we shorten this to ideally just using the sai override?
		-- TODO: move the msg-len-based timeout to be possible in sai.text directly
		local prev = M.text.status_timeout
		if timeout == nil then timeout = prev ~= 0 and prev or -10 end
		if timeout < 0 then timeout = math.max(1, math.floor(#msg / -timeout + 0.5)) end

		swayimg.text.status_timeout = 0
		vars[M.text].status_timeout:set(notify_layer, { new = prev, old = prev })
		notify_layer.status = msg

		hider(function()
			notify_layer.status = nil -- the special restores per the timeout
			local to_set = vars[M.text].status_timeout:set(notify_layer)
			if to_set then swayimg.text.status_timeout = to_set end
		end, timeout * 1000)
	else
		-- a corner block holds a table of lines, never a plain string
		local lines = {}
		for line in msg:gmatch '[^\n]+' do
			lines[#lines + 1] = line
		end
		if timeout == nil then timeout = -10 end
		if timeout < 0 then timeout = math.max(1, math.floor(#msg / -timeout + 0.5)) end

		notify_layer[location] = lines
		hider(function() notify_layer[location] = nil end, timeout * 1000)
	end
	e.ignore_opts = muted
end
function M.log(msg, file, location)
	if file then
		local f = io.open(file, 'a') or error('Could not append to file: ' .. file)
		f:write(tostring(msg))
		f:close()
	else
		M.notify(msg, nil, location)
		print(msg)
	end
end

local deferred_heap = require 'sai.bridge.deferred_heap'

-- api surface only: the scheduling machinery (arm, gen guard, error
-- isolation) lives in the heap bridge, like M.exec lives in the shell bridge
function M.defer_fn(cb, ms)
	if type(cb) == 'number' then
		cb, ms = ms, cb
	end
	deferred_heap:schedule(cb, ms)
end

--- for bw compatibility and ease of use
M.exec = require('sai.bridge.shell').exec

---@protected
function M:get_app_id() return swayimg.appid end

---@protected
---@type fun(self: sai.api, v: appmode_t):false
function M:set_mode(v)
	local m = self.super.mode
	---@diagnostic disable-next-line: cast-local-type
	m = { event = 'ModeChangedPre', mode = m, match = ('%s:%s'):format(m:sub(1, 1), v:sub(1, 1)), data = v }
	e.trigger(m)
	M.modes[1] = self[v]
	self.super.mode = v
	m.event = 'ModeChanged'
	m.data = m.mode
	m.mode = v
	e.trigger(m)
	return false
end

---@protected
function M:get_pid()
	rawset(self, 'pid', ffi.C.getpid())
	return self.pid
end

---@protected
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

proxy.new(M)
_G.sai = M

swayimg.on_window_resize(function()
	if type(M._old_winsize) == 'table' then -- handle as normal resize event
		local ws = swayimg.get_window_size()
		local ows = M._old_winsize
		if ows.width ~= ws.width or ows.height ~= ws.height then
			-- TODO: find a way to distinguish focus events from resizing (both can happen at once)
			e.trigger { event = 'WinResized', data = ws }
			M._old_winsize = ws
		end
	else -- handle as initialization
		-- deduplicate initial resizing
		if not M._old_winsize and not sai.overlay then
			M._old_winsize = true
			return
		elseif M._old_winsize and swayimg.mode ~= 'gallery' then
			---@diagnostic disable-next-line: assign-type-mismatch
			local x = M.modes[1] ---@type sai.api.viewer
			---@diagnostic disable-next-line: invisible
			x.scale = x._original_default_scale -- fix incorrect initial size with overlay disabled
		end

		M.initialized = true
		M._old_winsize = swayimg.get_window_size()

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

		binds.default()
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
