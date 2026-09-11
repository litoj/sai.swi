---Tests for sai.binds: every listed bind describes itself.
---Over a recording api stack.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local env = H.recording_stack()
local with_env = env.with_env
local remapper = require 'sai.lib.remapper'

local T = {}

-- every bind the help would list must describe itself: a listed bind
-- without a description falls back to its source trace, which helps
-- nobody. Obvious keys (kind 'private'/'input', no description) stay
-- hidden instead
T.default_binds_carry_descs = with_env(function(h)
	local function check(inst, path)
		local missing = {}
		for b, cfg in pairs(inst._mappings) do
			if not cfg.desc and (cfg.kind == nil or cfg.kind == 'default') then missing[#missing + 1] = b end
		end
		h.eq(('every listed bind of %s describes itself'):format(path), '', table.concat(missing, ' '))
	end

	for _, mod in ipairs {
		require 'sai.mode.editor',
		require 'sai.mode.selector',
		require 'sai.mode.sort',
		require 'sai.mode.completion',
		require 'sai.mode.image_filter',
	} do
		check(mod.new { _path = mod._path }, mod._path)
	end
	check(require('sai.mode.help').new { _path = 'sai.mode.help' }, 'sai.mode.help')
	local plain = remapper.new { _path = 'sai.mode.test_layer' }
	check(plain.help_pager, "a mode's auto-created help_pager")
end)

H.maybe_standalone(T)

return T
