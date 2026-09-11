---Unit tests for the override registry: the stack's `set` contract
---(put/move/remove, the restore target flowing up) over a fresh registry.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'
local reg = require 'sai.lib.registry'

-- a private registry: never the shared vars/binds
local api = setmetatable({ _path = 'sai.fake' }, { __index = function() return nil end })

local T = {}

T.stack_apply_and_lookup = function(h)
	local s = reg.new()[api].size
	local l1 = {}
	s:set(l1, { new = 7 })
	h.eq('one applied record', 1, #s)
	h.eq('record found by layer', 7, s[l1].new)
	h.eq('layer stamped on the record', l1, s[l1].layer)
	h.eq('no restore target on a fresh apply', nil, s[l1].old)
end

T.stack_top_wins = function(h)
	local s = reg.new()[api].size
	local a, b = {}, {}
	s:set(a, { new = 'a', old = 'base' })
	s:set(b, { new = 'b', old = 'a' })
	h.eq('two applied records', 2, #s)
	h.eq('the last record is the top', 'b', s[#s].new)
	h.eq('both records findable by layer', 'a', s[a].new)
	h.eq('top stays findable', 'b', s[b].new)
end

T.stack_moves_existing_to_top = function(h)
	local s = reg.new()[api].size
	local a, b = {}, {}
	s:set(a, { new = 'a' })
	s:set(b, { new = 'b' })
	s:set(a, { new = 'a2' }) -- rewrite from below: lands on top
	h.eq('still two records', 2, #s)
	h.eq('rewritten layer is now the top', 'a2', s[#s].new)
	h.eq('both layers readable', 'a2', s[a].new)
	h.eq('the other layer still readable', 'b', s[b].new)
end

-- a layer can only register once: a re-set replaces, never duplicates
T.stack_set_twice_registers_once = function(h)
	local s = reg.new()[api].size
	local l1 = {}
	s:set(l1, { new = 'a' })
	s:set(l1, { new = 'b' })
	h.eq('still one record', 1, #s)
	h.eq('the latest value wins', 'b', s[l1].new)
end

-- a reset removes once; a second one finds nothing
T.stack_reset_twice_is_idempotent = function(h)
	local s = reg.new()[api].size
	local l1 = {}
	s:set(l1, { new = 'a', old = 'base' })
	h.eq('the first reset returns the restore value', 'base', s:set(l1))
	local second = s:set(l1) -- already gone
	h.eq('a second reset does nothing', nil, second)
	h.eq('the stack is empty', 0, #s)
end

T.stack_remove_top_returns_restore = function(h)
	local s = reg.new()[api].size
	local a, b = {}, {}
	s:set(a, { new = 'a', old = 'base' })
	s:set(b, { new = 'b', old = 'a' })
	local old = s:set(b, nil) -- remove the top
	h.eq('remove on top returns its restore value', 'a', old)
	h.eq('one record left', 1, #s)
	h.eq('the record below is on top now', 'a', s[#s].new)
end

T.stack_remove_below_hands_restore_up = function(h)
	local s = reg.new()[api].size
	local a, b = {}, {}
	s:set(a, { new = 'a', old = 'base' })
	s:set(b, { new = 'b', old = 'a' })
	local mid = s:set(a, nil) -- remove from below the top
	h.eq('no restore handed to the caller', nil, mid)
	h.eq('the top keeps the field', 'b', s[#s].new)
	h.eq('the top took over the restore target', 'base', s[#s].old)
	h.eq('one record left', 1, #s)
end

T.stack_rejects_direct_writes = function(h)
	local s = reg.new()[api].size
	local l1 = {}
	local ok = pcall(function() s[l1] = { new = 5 } end)
	h.ok('a direct write is rejected', not ok)
	local ok2 = pcall(function() s.x = 1 end)
	h.ok('a second direct write is rejected', not ok2)
	h.eq('the stack stays empty', 0, #s)
end

T.stack_plain_record = function(h)
	local s = reg.new()[api].size
	local l1 = {}
	s:set(l1, { new = 5 })
	h.eq('record counts as applied', 1, #s)
	h.eq('record found by layer', 5, s[l1].new)
	h.eq('no raw key left on the stack', nil, rawget(s, l1))
end

T.registry_lazy_stacks = function(h)
	local reg2 = reg.new()
	local s1 = reg2[api].size
	h.ok('the same stack comes back on repeat', s1 == reg2[api].size)
	h.ok('a different field has its own stack', s1 ~= reg2[api].mark)
	h.ok('a different api has its own registry', s1 ~= reg2[{}].size)
end

T.vars_and_binds_are_separate = function(h)
	h.ok('vars and binds are distinct registries', reg.vars ~= reg.binds)
	h.ok('a fresh registry is independent of them', reg.new() ~= reg.vars)
	h.ok('stack carries the set method', reg.vars[api].size.set ~= nil)
end

H.maybe_standalone(T)

return T
