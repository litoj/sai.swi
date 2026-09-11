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

function T.printable_map_is_lazy(h)
	-- requiring the bridge must not load xkbcommon: printable chars
	-- resolve on first use through key_map.__index instead
	package.loaded['sai.bridge.xkb'] = nil
	local fresh = require 'sai.bridge.xkb'
	h.eq('no eager printable entry', nil, rawget(fresh.key_map, '!'))
	local resolved = fresh.key_map['!']
	h.ok('lazy resolve works', resolved ~= nil and resolved ~= false)
	h.eq('resolved value cached', resolved, rawget(fresh.key_map, '!'))
end

function T.short_key_name(h)
	-- a lone printable char stays bare; a resolved single char gets brackets to
	-- separate it from literal text; named keys keep their name without brackets
	h.eq('space renders as < >', '< >', M.short_key_name 'space')
	h.eq('Ctrl+space renders as <C- >', '<C- >', M.short_key_name 'Ctrl+space')
	h.eq('a stays bare', 'a', M.short_key_name 'a')
	h.eq('Ctrl-a renders as <C-a>', '<C-a>', M.short_key_name 'Ctrl-a')
	h.eq('0 stays bare', '0', M.short_key_name '0')
	h.eq('Ctrl+0 renders as <C-0>', '<C-0>', M.short_key_name 'Ctrl+0')
	h.eq('End keeps its name', 'End', M.short_key_name 'End')
	h.eq('Ctrl+End renders as C-End', 'C-End', M.short_key_name 'Ctrl+End')
	h.eq('F5 renders as <F5>', '<F5>', M.short_key_name 'F5')
	h.eq('Ctrl-F5 renders as <C-F5>', '<C-F5>', M.short_key_name 'Ctrl-F5')
	h.eq('BackSpace renders as <BS>', '<BS>', M.short_key_name 'BackSpace')
	h.eq('Ctrl-BackSpace renders as <C-BS>', '<C-BS>', M.short_key_name 'Ctrl-BackSpace')
end

function T.utf8_round_trip(h)
	h.eq('ascii keysym resolves', 'a', M.xkb_to_utf8 'a')
	h.eq('multibyte keysym resolves', 'é', M.xkb_to_utf8 'eacute')
	h.eq('unknown stays nil', nil, M.xkb_to_utf8 'sai-no-such-keysym')
	local back = M.utf8_to_xkb 'é'
	h.ok('utf8 back to keysym', back ~= false)
	h.eq('keysym back to utf8', 'é', M.xkb_to_utf8(back))
	h.eq('empty input gives false', false, M.utf8_to_xkb '')
	h.eq('multi-byte input refuses', false, M.utf8_to_xkb 'ab')
end

function T.process_next_input(h)
	local kind, text = M.process_next_input 'Ctrl+a'
	h.eq('ctrl is a command', 'command', kind)
	kind, text = M.process_next_input 'a'
	h.eq('printable is text', 'text', kind)
	h.eq('text carries the char', 'a', text)
end

H.maybe_standalone(T)

return T
