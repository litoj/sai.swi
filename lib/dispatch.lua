---@module 'sai.lib.dispatch'

local B = require 'sai.lib.bindmods'

---The mode's dispatch machinery split out of mode_base.
---It reads the mode's private families and burst counters directly.
---@diagnostic disable: invisible

---The per-event handler creator.
---`_rawmap`/`_rawunmap` update the event's family set, then register the
---handler this module returns:
--- - a lone plain bind: the callback itself;
--- - any variant form (a qualifier token, a mouse repeat, a future
---   sub-map): a dispatcher that resolves the live qualifiers at press
---   time.
---@class sai.lib.dispatch
local M = {}

---One burst per event: a fire on any path ends the pending waits of the
---event's other paths (the pointer left the block mid-burst).
---@param self sai.api.mode_base
---@param fam bindfam
---@param ev string
---@param cnt integer
---@param args any[] the payload of the resolved tokens
---@param nargs integer
local function fire(self, fam, ev, cnt, args, nargs)
	local pre = ev .. '@'
	for k in pairs(self._m_cnt) do
		if k:sub(1, #pre) == pre then self._m_cnt[k] = 0 end
	end
	local fn = fam.recs[cnt]
	if fn then fn(unpack(args, 1, nargs)) end
end

---One dispatcher per event: resolves the qualifier tokens against the
---live state, counts the mouse bursts, and fires the matched family.
---Nothing matched: a key runs the unassigned path; a button stays
---silent.
---@param self sai.api.mode_base
---@param ev string
---@return fun():boolean the raw handler, truthy when a family fired
local function make_dispatcher(self, ev)
	return function()
		local fams = self._m_fam[ev]
		if not fams then return false end
		local path, args, nargs = B.resolve(fams)
		local fam = fams[path]
		if not fam then
			if not (ev:match 'Mouse' or ev:match 'Scroll') then self._on_unassigned(ev) end
			return false
		end

		local ck = ev .. '@' .. path
		local cnt = (self._m_cnt[ck] or 0) + 1
		self._m_cnt[ck] = cnt
		if cnt < fam.max then -- a higher count is registered: the burst may grow
			local held = cnt
			sai.defer_fn(function()
				if self._m_cnt[ck] == held then fire(self, fam, ev, cnt, args, nargs) end
			end, self.multiclick_delay)
			return true
		end
		fire(self, fam, ev, cnt, args, nargs)
		return true
	end
end

---The handler for an event:
--- - a single unqualified single-count bind: the plain callback;
--- - any variant form: a dispatcher.
---The plain callback passes its arguments through - the scroll handler
---calls it with the axis magnitude.
---@param self sai.api.mode_base
---@param ev string
---@return fun(...)
function M.create(self, ev)
	local fams = self._m_fam[ev]
	assert(fams, 'dispatch.create: no families for ' .. ev)

	-- a single plain bind: the C slot holds the action itself
	local key = next(fams)
	if key == '' and next(fams, key) == nil and fams[''].max == 1 then return fams[''].recs[1] end
	return make_dispatcher(self, ev)
end

return M
