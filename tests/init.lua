---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Test runner: discovers and runs every test module in this directory.
---Development tool: not used during normal swayimg operation.
---
---Each module is a table of named test methods (see tests/harness.lua); a
---method may h.skip() itself when its environment is unavailable. The
---nvim_dap module for instance needs a Wayland session, nvim with nvim-dap +
---nvim-nio and images at ~/Pictures/*/*.jpg, and skips itself without them.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

_G._TEST_RUNNER = true

local H = require 'harness'

local modules = {}
local p = assert(io.popen('ls ' .. dir))
for name in p:read('*a'):gmatch '[^\r\n]+' do
	local mod = name:match '^([%w_]+)%.lua$'
	if mod and mod ~= 'init' and mod ~= 'harness' then modules[#modules + 1] = mod end
end
p:close()
table.sort(modules)

local args = { ... }
local function selected(mod, method)
	if #args == 0 then return true end
	local full = mod .. '.' .. method
	for _, pat in ipairs(args) do
		if mod == pat or full == pat or full:find(pat, 1, true) then return true end
	end
	return false
end

for _, mod in ipairs(modules) do
	local chunk, err = loadfile(dir .. '/' .. mod .. '.lua')
	if not chunk then
		H.fail(mod .. ' load error', err)
	else
		local T = chunk()
		if type(T) ~= 'table' then
			H.fail(mod .. ' load error', 'did not return a test module')
		else
			print('=== ' .. mod .. ' ===')
			H.run(T, function(name) return selected(mod, name) end)
		end
	end
end

H.summary()
os.exit(H.exit_code())
