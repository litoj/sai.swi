---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for sai.notify: the borrow/restore contract for a persistent status
---line and the guarantee that no C++ auto-hide timer gets armed while the
---deferred restore owns the message (an already-expired status timer fires its
---handler after the restore in the same event cycle and would wipe it).
---Loads a private copy of the api stack: the raw text table the proxies write
---through to is captured at module load time, so this file cannot reuse the
---stack the help tests bound to their own stub.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')

-- drop the api stack other test modules may have loaded: their super tables
-- point at their stubs, ours has to point at the one below
for name in pairs(package.loaded) do
	if name:sub(1, 4) == 'sai.' then package.loaded[name] = nil end
end

-- any method the api stack touches at load or during notify becomes a no-op
local function new_raw_mode()
	return setmetatable({}, {
		__index = function()
			return function() end
		end,
	})
end
-- faithful to the live app: the C++ text property getters return nil (reads
-- fall through to the api copies), writes land on the C++ side; raw_text
-- records what the app would have received
local raw_text = {}
local swayimg = {
	mode = 'viewer',
	viewer = new_raw_mode(),
	slideshow = new_raw_mode(),
	gallery = new_raw_mode(),
	imagelist = { size = 0 },
	text = setmetatable({}, {
		__index = function() return nil end,
		__newindex = function(_, k, v) raw_text[k] = v end,
	}),
	defer = function() end, -- deferred callbacks are pumped manually
	on_window_resize = function() end,
	get_window_size = function() return { width = 800, height = 600 } end,
}
_G.swayimg = swayimg

local sai = require 'sai.api.init'
local sai_proxy = _G.sai
local heap = require 'sai.bridge.deferred_heap'

_G.swayimg, _G.sai = old_swi, old_sai

local function with_env(fn)
	return function(h)
		_G.swayimg, _G.sai = swayimg, sai_proxy
		raw_text.status_timeout = nil
		raw_text.status = nil
		local ran, err = pcall(fn, h)
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

---Run every scheduled deferred callback, earliest first.
local function run_deferred()
	for _ = 1, 100 do
		local cb = heap:pop()
		if not cb then break end
		cb()
	end
end

local T = {}

T.persistent_status_borrow = with_env(function(h)
	sai.text.status_timeout = 0
	sai.text.status = 'my status'

	sai.notify 'test message'
	h.eq('message shown', 'test message', raw_text.status)
	h.eq('auto-hide not armed', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('status restored', 'my status', raw_text.status)
	h.eq('timeout restored', 0, raw_text.status_timeout)
end)

T.transient_status_no_restore = with_env(function(h)
	sai.text.status_timeout = 2
	sai.text.status = 'my status'

	sai.notify 'test message'
	h.eq('message shown', 'test message', raw_text.status)
	h.eq('no deferred restore scheduled', 0, #heap)

	run_deferred()
	h.eq('message left to the normal timer', 'test message', raw_text.status)
end)

T.restore_ignores_timeout_override = with_env(function(h)
	sai.text.status_timeout = 0
	sai.text.status = 'my status'

	sai.notify 'test message'
	sai.text.status_timeout = 7 -- a late timeout write does not cancel the restore

	run_deferred()
	h.eq('restored the borrowed status', 'my status', raw_text.status)
	h.eq('timeout override untouched', 7, raw_text.status_timeout)
end)

T.superseded_notify_keeps_newest = with_env(function(h)
	sai.text.status_timeout = 0
	sai.text.status = 'my status'

	sai.notify 'first message'
	sai.notify 'second message'
	h.eq('newest message shown', 'second message', raw_text.status)

	-- the first (superseded) restore must not touch the newer borrow
	heap:pop()()
	h.eq('superseded restore skipped', 'second message', raw_text.status)
	h.eq('auto-hide never armed', 0, raw_text.status_timeout)

	run_deferred()
	h.eq('status restored', 'my status', raw_text.status)
	h.eq('timeout restored', 0, raw_text.status_timeout)
end)

T.monotonic_ms_precision = function(h)
	-- whole-second clock truncation would record this due time up to 1s early
	heap:push(500, function() end)
	local remaining = heap:time_to_next()
	h.ok('sub-second precision', remaining > 250 and remaining <= 500)
	heap:pop()
end

return T
