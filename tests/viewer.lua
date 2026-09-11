---Tests for sai.api.viewer: default-scale handling.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')

local swayimg = H.raw_swayimg()
local _, sai_proxy = H.fresh_api_stack(swayimg)
local e = require 'sai.api.eventloop'
local viewer_mod = require 'sai.api.viewer'

_G.swayimg, _G.sai = old_swi, old_sai

local function with_env(fn)
	return function(h)
		_G.swayimg, _G.sai = swayimg, sai_proxy
		local ran, err = pcall(fn, h)
		_G.swayimg, _G.sai = old_swi, old_sai
		if not ran then error(err, 0) end
	end
end

local T = {}

-- Re-setting the default scale replaces the keep_* pair instead of
-- stacking a new one per call
T.keep_scale_resubscribe_replaces_hooks = with_env(function(h)
	local viewer = viewer_mod.new 'viewer'
	local function keeps()
		local n = 0
		for hk in pairs(e.find_all { event = 'ImgChanged' }) do
			if hk.pattern['viewer'] then n = n + 1 end
		end
		for hk in pairs(e.find_all { event = 'ImgChangedPre' }) do
			if hk.pattern['viewer'] then n = n + 1 end
		end
		return n
	end
	local before = {}
	for hk in pairs(e.find_all { event = 'ImgChanged' }) do
		before[hk] = true
	end
	for hk in pairs(e.find_all { event = 'ImgChangedPre' }) do
		before[hk] = true
	end
	local base = 0
	for _ in pairs(before) do
		base = base + 1
	end

	viewer.default_scale = 'keep_width'
	viewer.default_scale = 'keep_width'
	viewer.default_scale = 'keep_width'
	h.eq('three sets leave one keep hook pair', base + 2, keeps())

	for hk in pairs(e.find_all { event = 'ImgChanged' }) do
		if hk.pattern['viewer'] and not before[hk] then e.unsubscribe { id = hk } end
	end
	for hk in pairs(e.find_all { event = 'ImgChangedPre' }) do
		if hk.pattern['viewer'] and not before[hk] then e.unsubscribe { id = hk } end
	end
	viewer.default_scale = 'optimal'
end)

H.maybe_standalone(T)

return T
