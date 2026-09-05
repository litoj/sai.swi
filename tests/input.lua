---@diagnostic disable: invisible, inject-field, undefined-field, missing-fields, need-check-nil
---Tests for sai.mode.input: char-based (utf8) cursor semantics and the
---invariant that the text state and the rendered output are always valid
---utf8, no matter the operation order. Runs in plain luajit with stubbed
---globals. Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local eq = H.eq

local utf8 = require 'sai.bridge.utf8'

-- the mode module (and its imports) read these globals at load time
local old_swi, old_sai = _G.swayimg, rawget(_G, 'sai')
_G.swayimg = { mode = 'viewer' }
_G.sai = { gallery = {}, viewer = {}, slideshow = {}, text = {}, imagelist = {}, log = function() end }
local ran, M = pcall(require, 'sai.mode.input')
_G.swayimg, _G.sai = old_swi, old_sai

local T = {}

if not ran then
	function T.unavailable(h) h.skip('mode not loadable', M) end
	return T
end

---Stub instance rendering into a captured display string.
---The metatable mimics the mode's public properties by routing them to setters.
local function new_input()
	local display
	local self = setmetatable({
		_enabled = true,
		_prompt = false,
		_location = 'status',
		_raw_update = function(d) display = d end,
		_text = '',
		_col = 1,
		_visual = false,
	}, {
		__index = M,
		__newindex = function(s, k, v)
			local setter = M['set_' .. k]
			if setter then return setter(s, v) end
			rawset(s, k, v)
		end,
	})
	return self, function() return display end
end

---The tested invariant: state, rendered output, cursor and selection must stay utf8-consistent.
---@return string? violation
local function violations(self, display)
	if not utf8.isvalid(self._text) then return 'text state is not valid utf8' end
	if display and not utf8.isvalid(display) then return 'rendered display is not valid utf8' end
	if self._col < 1 or self._col > utf8.len(self._text) + 1 then return 'cursor out of char bounds' end
	if self._visual and (self._visual < 1 or self._visual > utf8.len(self._text) + 1) then
		return 'selection marker out of char bounds'
	end
end

function T.insert_and_cursor(h)
	local self, get = new_input()
	self:insert 'héllo'
	eq('utf8 insert', 'héllo', self._text)
	eq('cursor after multibyte insert', 6, self._col)
	h.ok('state valid after insert', not violations(self, get()))

	self.col = 2 -- between h and é
	eq('cursor renders between characters', 'h▎éllo', get())
	self:insert 'X'
	eq('insert at char position', 'hXéllo', self._text)
	eq('cursor after mid-text insert', 3, self._col)
	h.ok('state valid after mid-text insert', not violations(self, get()))
end

function T.delete_and_selection(h)
	local self, get = new_input()
	self:insert 'hXéllo wörld'

	self._col, self._visual = 3, 9 -- selection 'éllo w'
	self:delete()
	eq('char-based selection delete', 'hXörld', self._text)
	eq('cursor after selection delete', 3, self._col)
	h.ok('state valid after selection delete', not violations(self, get()))

	self.visual = 2 -- selection before the cursor: icons swap sides
	eq('selection renders around multibyte chars', 'h|X▎örld', get())
	self:delete(2, 3)
	eq('char-based range delete', 'hrld', self._text)
	h.ok('state valid after range delete', not violations(self, get()))
end

function T.line_info()
	local self = new_input()
	self:insert 'aé\nbö'
	local lines = self:get_lines_info()
	eq('line count (trailing empty line)', 3, #lines)
	eq('line from positions are chars', 1, lines[1].from)
	eq('line to positions are chars', 3, lines[1].to)
	eq('second line from', 4, lines[2].from)
	eq('second line to', 6, lines[2].to)
end

function T.set_text_cursor_tracking(h)
	local self, get = new_input()
	self:insert 'héllo'

	self.col = 5 -- between 'hell' and 'o'
	self.text = 'xxhéllo' -- text inserted before the cursor
	eq('cursor stays relative to following text', 7, self._col)
	h.ok('state valid after prefix insert', not violations(self, get()))

	self.text = 'a' -- shorter than the cursor
	eq('cursor clamps to text end', 2, self._col)
	h.ok('state valid after shrink', not violations(self, get()))
end

function T.invalid_input_sanitized(h)
	local self, get = new_input()
	self:insert '\255ok\254'
	h.ok('invalid insert gets sanitized', utf8.isvalid(self._text))
	h.contains('valid content kept after sanitize', self._text, 'ok')
	h.ok('state valid after invalid insert', not violations(self, get()))

	self.text = '\xf0\x28\x8c\x28a\xffb'
	h.ok('invalid set_text gets sanitized', utf8.isvalid(self._text))
	h.ok('state valid after invalid set_text', not violations(self, get()))
end

---Random operation soup: whatever happens, the text field must stay valid utf8.
function T.utf8_invariant_fuzz(h)
	local self, get = new_input()
	local pool = {
		'',
		'a',
		'X',
		'héllo',
		'釵鐵尺',
		'wörld',
		'\n',
		'multi\nline',
		'☃',
		'😀😀',
		'a\né\n釵',
		-- invalid inputs: must get sanitized on the way in
		'\255',
		'\254x',
		'a\xffb',
		'é\xffé',
		'\xf0\x28\x8c\x28',
	}

	math.randomseed(0xC0FFEE)
	for i = 1, 1000 do
		local op = math.random(7)
		if op == 1 then
			self:insert(pool[math.random(#pool)])
		elseif op == 2 then
			self.col = math.random(0, 20)
		elseif op == 3 then
			self.visual = math.random(0, 20)
		elseif op == 4 and self._visual then
			self:delete()
		elseif op == 5 then
			local from = math.random(0, 15)
			self:delete(from, from == 0 and 0 or math.random(1, 15))
		elseif op == 6 then
			self.text = pool[math.random(#pool)]
		else
			self.line = math.random(-2, 5)
		end

		local v = violations(self, get())
		if v then
			h.fail('fuzz iteration ' .. i .. ' broke the invariant: ' .. v, self._text)
			return
		end
	end
	h.pass '1000 fuzz iterations keep the text field valid utf8'
end

if not _G._TEST_RUNNER then
	_G._TEST_RUNNER = true
	H.run(T)
	H.summary()
	os.exit(H.exit_code())
end

return T
