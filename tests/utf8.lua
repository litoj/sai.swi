---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for sai.bridge.utf8: system module preference, download, LuaJIT-compat
---patching, compilation and the utf8 C module behavior. Runs in plain luajit;
---the first fallback download needs network access. Development tool: not used
---during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local ran, M = pcall(require, 'sai.bridge.utf8')

local T = {}

if not ran then
	-- offline or no toolchain: nothing else can be tested
	function T.unavailable(h) h.skip('module not loadable', M) end
	return T
end

local s = 'héllo 釵 wörld' -- 13 characters, 17 bytes

function T.len(h)
	h.eq('char count', 13, M.len(s))
	h.eq('byte count', 17, #s)
	h.eq('char count in range', 2, M.len(s, 1, 3))
	h.eq('invalid utf8 gives nil', nil, M.len '\255\254')
end

function T.char(h)
	h.eq('char()', '☃', M.char(0x2603))
	h.eq('char() multiple', 'a☃é', M.char(97, 0x2603, 0xE9))
end

function T.codepoint(h)
	h.eq('codepoint()', 0xE9, M.codepoint(s, 2))
	h.eq('codepoint() range count', 2, select('#', M.codepoint('éé', 1, 4)))
end

function T.offset(h)
	h.eq('offset() forward', 4, M.offset(s, 3)) -- 3rd char starts at 4th byte
	h.eq('offset() negative', 17, M.offset(s, -1))
	h.eq('offset() from position', 13, M.offset(s, 1, 13))
	h.eq('offset() current char', 8, M.offset(s, 0, 9)) -- continuation byte -> lead
end

function T.codes(h)
	local n, chars = 0, {}
	for _, cp in M.codes(s) do
		n = n + 1
		chars[#chars + 1] = M.char(cp)
	end
	h.eq('codes() iterates all', 13, n)
	h.eq('codes() round-trip', s, table.concat(chars))
end

-- the char-aware equivalent of string.sub(): position, byte range
function T.sub(h)
	h.eq('sub()', 'éllo 釵 wörl', M.sub(s, 2, -2))
	h.eq('sub() to end', 'éllo 釵 wörld', M.sub(s, 2))
	h.eq('sub() middle', '釵 w', M.sub(s, 7, 9))
	h.eq('sub() single', 'l', M.sub(s, 3, 3))
	h.eq('sub() empty range', '', M.sub(s, 1, 0))
	h.eq('sub() past end', '', M.sub(s, 100))
	h.eq('sub() drop last', 'éllo 釵 wörl', M.sub(s, 2, -2))
end

-- the callable form coerces a string into a valid utf8 string
function T.call(h)
	h.ok('valid string passes through', M(s) == s)
	h.ok('empty string passes through', M '' == '')
	local cleaned = M '\255ok\254'
	h.ok('invalid string gets cleaned', M.isvalid(cleaned))
	h.contains('cleaned content kept', cleaned, 'ok')
	h.ok('non-strings pass through', M(42) == 42 and M(nil) == nil)
end

-- a system-provided module must take precedence over the compiled one
function T.system_preferred(h)
	local sys = package.loaded['lua-utf8']
	if not sys then
		h.skip 'no system module installed'
		return
	end
	h.ok('bridge returns the system module', M == sys)
end

-- with the system module hidden, the bridge must fall back to its own build
function T.fallback_build(h)
	local sys = package.loaded['lua-utf8']
	if not sys then
		h.skip 'no system module: fallback already tested above'
		return
	end

	-- LuaJIT caches 'lua-utf8' under the dash-suffix name 'utf8' too, and the
	-- 'utf8' probe can even pick up this very test file: both names must be hidden
	package.loaded['sai.bridge.utf8'], package.loaded['lua-utf8'], package.loaded['utf8'] = nil, nil, nil
	package.preload['lua-utf8'] = function() error 'hidden for test' end
	package.preload['utf8'] = function() error 'hidden for test' end
	local ok, built = pcall(require, 'sai.bridge.utf8')
	package.preload['lua-utf8'], package.preload['utf8'] = nil, nil
	package.loaded['lua-utf8'], package.loaded['utf8'] = sys, sys
	package.loaded['sai.bridge.utf8'] = M

	h.ok('fallback module loads', ok)
	h.ok('fallback differs from system module', built ~= sys)
	if ok then
		h.eq('fallback len()', 13, built.len(s))
		h.eq('fallback sub()', 'éllo 釵 wörl', built.sub(s, 2, -2))
		h.eq('fallback sub idiom', 'l', s:sub(built.offset(s, 3), built.offset(s, 4) - 1))
		h.ok('fallback callable cleans', built.isvalid(built '\255ok\254'))
	end
end

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
