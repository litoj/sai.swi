---Tests for sai.mode.filter: the generic live-dataset filter.
---Over a recording api stack, driven through the public flow (enable + set text).
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/' or ''
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
dir = dir:gsub('/%./', '/'):gsub('/%.?$', '')
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local filter_mode = require 'sai.mode.filter'

local function new_filter(source, shown)
	return filter_mode.new {
		_path = 'sai.mode.test_filter',
		filter_source = function() return source end,
		filter_show = function(_, items)
			for i in ipairs(shown) do
				shown[i] = nil
			end
			for i, item in ipairs(items) do
				shown[i] = item
			end
		end,
	}
end

local T = {}

T.default_process_rates_best_first = with_env(function(h)
	local shown = {}
	local m = new_filter({ 'Pan left', 'Pan right', 'Zoom in', 'Exit application' }, shown)
	m.enabled = true
	m.text = 'Pan'
	h.eq('best matches first, stable', 'Pan left\nPan right', table.concat(shown, '\n'))
	m.text = ''
	h.eq('empty query keeps every item in order', 4, #shown)
	m.text = 'zzz'
	h.eq('no match drops every item', 0, #shown)
	m.enabled = false
end)

-- a nil process keeps the last view: the display hook never runs
T.nil_process_keeps_the_view = with_env(function(h)
	local shown = { 'kept' }
	local calls = 0
	local m = filter_mode.new {
		_path = 'sai.mode.test_filter',
		filter_process = function() return nil end,
		filter_show = function() calls = calls + 1 end,
	}
	m.enabled = true
	m.text = 'whatever'
	h.eq('the display never ran', 0, calls)
	h.eq('the last view stands', 'kept', shown[1])
	m.enabled = false
end)

-- dyntext items rate through their live rendering, not their address
T.dyntext_rates_by_rendering = with_env(function(h)
	local shown = {}
	local m = new_filter({ { callback = function() return 'live value' end }, 'other' }, shown)
	m.enabled = true
	m.text = 'live'
	h.eq('the rendered item matched', 1, #shown)
	h.ok('the match is the dyntext item', shown[1].callback ~= nil)
	m.enabled = false
end)

H.maybe_standalone(T)

return T
