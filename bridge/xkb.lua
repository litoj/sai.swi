---@module 'sai.bridge.xkb'

local U = require 'sai.lib.utils'

---@class sai.bridge.xkb
local M = {}

local ffi, xkb, composer_state
xkb = U.lazyload(function()
	ffi = require 'ffi'
	ffi.cdef [[
	typedef unsigned int xkb_keysym_t;
	xkb_keysym_t xkb_keysym_from_name(const char *name, int flags);
	uint32_t xkb_keysym_to_utf32(xkb_keysym_t keysym);
	xkb_keysym_t xkb_utf32_to_keysym(uint32_t utf32);
	int xkb_keysym_get_name(xkb_keysym_t keysym, char *buffer, size_t size);

	typedef struct xkb_context xkb_context;
	typedef struct xkb_compose_table xkb_compose_table;
	typedef struct xkb_compose_state xkb_compose_state;

	xkb_context *xkb_context_new(unsigned int flags);
	xkb_compose_table *xkb_compose_table_new_from_locale(xkb_context *context, const char *locale, unsigned int flags);
	xkb_compose_state *xkb_compose_state_new(xkb_compose_table *table, unsigned int flags);
	int xkb_compose_state_feed(xkb_compose_state *state, unsigned int keysym);
	int xkb_compose_state_get_status(xkb_compose_state *state);
	int xkb_compose_state_get_utf8(xkb_compose_state *state, char *buffer, size_t size);
	void xkb_compose_state_reset(xkb_compose_state *state);
	]]

	xkb = ffi.load 'xkbcommon'

	local locale = os.getenv 'LC_ALL' or os.getenv 'LC_CTYPE' or os.getenv 'LANG' or 'C.UTF-8'
	local table = xkb.xkb_compose_table_new_from_locale(xkb.xkb_context_new(0), locale, 0)
	assert(table ~= nil, 'could not create MKB compose table for locale: ' .. locale)
	composer_state = xkb.xkb_compose_state_new(table, 0)
	return xkb
end)

---@param k string|integer the xkb keystring
---@return string utf8_char
function M.xkb_to_utf8(k)
	local toi = math.floor
	local ch = string.char
	k = xkb.xkb_keysym_to_utf32(type(k) == 'string' and xkb.xkb_keysym_from_name(k, 0) or k)

	if k < 0x80 then
		return ch(k)
	elseif k < 0x800 then
		return ch(0xC0 + toi(k / 0x40), 0x80 + k % 0x40)
	elseif k < 0x10000 then
		return ch(0xE0 + toi(k / 0x1000), 0x80 + toi(k / 0x40) % 0x40, 0x80 + k % 0x40)
	else
		return ch(0xF0 + toi(k / 0x40000), 0x80 + toi(k / 0x1000) % 0x40, 0x80 + toi(k / 0x40) % 0x40, 0x80 + k % 0x40)
	end
end

---Reverse of `xkb_to_utf8`: convert a utf8 character into the xkb keystring.
---@param utf8_char string a single utf8 character
---@return string|false keysym the xkb keystring
function M.utf8_to_xkb(utf8_char)
	local byte = string.byte
	local k, b2, b3, b4 = byte(utf8_char, 1, 4)
	if not k or (k < 128 and b2) then return false end

	-- decode the utf8 char back into a codepoint
	if k >= 0xF0 then
		k = (k % 0x8) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + b4 % 0x40
	elseif k >= 0xE0 then
		k = (k % 0x10) * 0x1000 + (b2 % 0x40) * 0x40 + b3 % 0x40
	elseif k >= 0xC0 then
		k = (k % 0x20) * 0x40 + b2 % 0x40
	end

	k = xkb.xkb_utf32_to_keysym(k)
	local buf = ffi.new 'char[32]'
	xkb.xkb_keysym_get_name(k, buf, 32)
	return ffi.string(buf)
end

local COMPOSING = 1
local COMPOSED = 2
local CANCELLED = 3

---Feed one MKB keysym.
---Returns:
---    "text", text
---        A complete UTF-8 character/string was produced.
---    "waiting"
---        Compose is waiting for another keysym.
---    "command"
---        The keysym is not text and should be handled by the
---        application as a command.
---    "text", text
---        For a normal non-Compose keysym.
---@param keysym string user-pressed symbol - modifiers included
---@return 'text'|'waiting'|'command'
---@return nil|string
function M.process_next_input(keysym)
	if keysym:find('Ctrl', 1, true) or keysym:find('Alt', 1, true) then
		xkb.xkb_compose_state_reset(composer_state)
		return 'command'
	end
	keysym = xkb.xkb_keysym_from_name(keysym:match '[^+]+$', 0)

	if not keysym then
		xkb.xkb_compose_state_reset(composer_state)
		return 'waiting'
	end

	local result = xkb.xkb_compose_state_feed
	result = result(composer_state, keysym)

	-- MKB_COMPOSE_FEED_ACCEPTED == 1
	-- MKB_COMPOSE_FEED_IGNORED  == 0
	--
	-- We don't normally need to distinguish them here.
	if result == 0 then return 'command' end
	local status = xkb.xkb_compose_state_get_status(composer_state)
	if status == COMPOSING then return 'waiting' end
	if status == COMPOSED then
		local buffer = ffi.new('char[?]', 256)
		local length = xkb.xkb_compose_state_get_utf8(composer_state, buffer, 256)
		local text = ffi.string(buffer, length)
		xkb.xkb_compose_state_reset(composer_state)
		return 'text', text
	end

	if status == CANCELLED then xkb.xkb_compose_state_reset(composer_state) end

	-- normal text/sym - no compose sequence
	local text = M.xkb_to_utf8(keysym)
	if text ~= '\0' then return 'text', text end
	return 'command'
end

--- Key formatting ---

---A map of translations of key aliases to their xkb names
M.key_map = {
	BS = 'BackSpace',
	Del = 'Delete',
	Esc = 'Escape',
	CR = 'Return',
	Enter = 'Return',
	PgUp = 'Prior',
	PgDown = 'Next',
}
-- Add all of ascii
for i = 32, string.byte 'A' - 1 do
	local c = string.char(i)
	M.key_map[c] = M.utf8_to_xkb(c)
end
for i = string.byte 'Z' + 1, 126 do
	local c = string.char(i)
	M.key_map[c] = M.utf8_to_xkb(c)
end
M.key_map.LMB = 'MouseLeft'
M.key_map.MMB = 'MouseMiddle'
M.key_map.RMB = 'MouseRight'
M.key_map.LMS = 'ScrollLeft'
M.key_map.RMS = 'ScrollRight'
M.key_map.UMS = 'ScrollUp'
M.key_map.DMS = 'ScrollDown'

---A map of key combos to their printable chars
M.rev_key_map = U.rev_idx(M.key_map)

-- register keys that have multiple common names but we don't want to override the first ones
M.key_map.Space = 'space'
M.key_map.PageUp = 'Prior'
M.key_map.PageDown = 'Next'
M.key_map.SML = 'ScrollLeft'
M.key_map.SMR = 'ScrollRight'
M.key_map.SMU = 'ScrollUp'
M.key_map.SMD = 'ScrollDown'

for i = string.byte 'A', string.byte 'Z' do
	local lc = string.char(i + 32)
	local uc = string.char(i)
	M.rev_key_map['Shift+' .. lc] = uc -- Shift+a → A
	M.key_map[uc] = lc
end

setmetatable(M.key_map, {
	---@param idx string
	__index = function(self, idx)
		local k = M.utf8_to_xkb(idx)
		rawset(self, idx, k)
		if k and not M.rev_key_map[k] then rawset(M.rev_key_map, k, idx) end
		return k
	end,
	__newindex = function() error 'external writing not allowed to M.key_map' end,
})

---Parse vim-like shortcuts into xkb format.
---@param bind string keybind from the user (any of many options, see the main readme)
---@return string
function M.userbind_to_xkb(bind)
	if bind:match '^<.+>$' then bind = bind:sub(2, -2) end
	bind = bind:gsub('[AM][+-]', 'Alt+', 1):gsub('S[+-]', 'Shift+', 1):gsub('C[+-]', 'Ctrl+', 1)

	if bind:match 'Shift%+Tab$' then
		bind = bind:gsub('Shift%+Tab$', 'Shift+ISO_Left_Tab')
	else
		local key = bind:match '[^+-]*.$'
		bind = bind:sub(1, -#key - 1) .. (M.key_map[key] or key)
	end

	-- ensure order of modifiers - Ctrl, Alt, Shift
	bind = bind:gsub('Alt+(.*)Ctrl', '%1Ctrl+Alt'):gsub('Shift+(.*)Alt', '%1Alt+Shift')
	return bind
end

function M.short_key_name(bind)
	bind = bind:gsub('Alt[+-]', 'A-'):gsub('Shift[+-]', 'S-'):gsub('Ctrl[+-]', 'C-')
	if bind:match 'ISO_Left_Tab$' then
		bind = bind:gsub('S-(.*)ISO_Left_Tab', '%1')
	else
		local key = bind:match '[^+-]*.$'
		local found = M.rev_key_map[key] or M.xkb_to_utf8(key)
		bind = bind:sub(1, -#key - 1) .. (found or key)
		if found then return ('<%s>'):format(bind) end
	end
	if bind:match '-.' then bind = ('<%s>'):format(bind) end
	return bind
end

return M
