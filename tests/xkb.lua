---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for sai.bridge.xkb.short_key_name: the compact bind form shown by the
---key help mode. Input is already in xkb form (the stored mapping keys). Runs in
---plain luajit; needs libxkbcommon to load the bridge, skips itself otherwise.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local ran, M = pcall(require, 'sai.bridge.xkb')

local T = {}

if not ran then
	-- no libxkbcommon: nothing to check
	function T.unavailable(h) h.skip('module not loadable', M) end
	return T
end

function T.short_key_name(h)
	-- a lone printable char stays bare; a resolved single char gets brackets to
	-- separate it from literal text; named keys keep their name without brackets
	h.eq('space', '< >', M.short_key_name 'space')
	h.eq('Ctrl+space', '<C- >', M.short_key_name 'Ctrl+space')
	h.eq('a', 'a', M.short_key_name 'a')
	h.eq('Ctrl-a', '<C-a>', M.short_key_name 'Ctrl-a')
	h.eq('0', '0', M.short_key_name '0')
	h.eq('Ctrl+0', '<C-0>', M.short_key_name 'Ctrl+0')
	h.eq('End', 'End', M.short_key_name 'End')
	h.eq('Ctrl+End', 'C-End', M.short_key_name 'Ctrl+End')
	h.eq('F5', '<F5>', M.short_key_name 'F5')
	h.eq('Ctrl-F5', '<C-F5>', M.short_key_name 'Ctrl-F5')
	h.eq('BackSpace', '<BS>', M.short_key_name 'BackSpace')
	h.eq('Ctrl-BackSpace', '<C-BS>', M.short_key_name 'Ctrl-BackSpace')
end

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
