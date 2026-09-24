---@module 'sai.api.mode_base'

local proxy = require 'sai.api.proxy'
local e = require 'sai.api.eventloop'
local kp = require 'sai.lib.keybind_processor'
local B = require 'sai.lib.bindmods'
local dispatch = require 'sai.lib.dispatch'

---@class sai.api.mode_base: mode_base, sai.lib.keybind_processor
---@field super swayimg_appmode
---@field private _m_fam {[string]:{[string]:bindfam}} per event name: qualifier path -> bind family
---@field private _m_handlers {[string]:fun()} handler installed with the host per event: the plain callback or a dispatcher
---@field private _m_scroll {[string]:fun(...)} raw scroll handlers per xkb event, served by the single on_scroll handler
---@field private _m_scroll_acc {h:number,v:number} the sub-unit scroll deltas waiting to become a step
---@field private _m_claims {[string]:fun()} per-event retire handlers: unassigned (key) or unhandled (button)
---@field private _m_cnt {[string]:integer} burst counts of the running presses, per event and path
local M = { warn_on_duplicates = true, multiclick_delay = 175 }

---The event key under modifiers: swayimg's modifier string, '' for none.
---@param kmods string
---@param ev string
---@return string
local function qkey(kmods, ev) return kmods == '' and ev or (kmods .. '+' .. ev) end

---Whole steps of a delta with the sub-unit rest: the rest waits in the
---accumulator for the next frame.
---@param n number
---@return number steps whole units, the sign kept
---@return number rest the fraction below one unit
local function quantize(n)
	local s = n >= 0 and math.floor(n) or math.ceil(n)
	return s, n - s
end

---One family per qualifier path of an event: the burst-indexed actions
---and the tokens that formed the path.
---@class bindfam
---@field recs {[integer]:fun(...)} action per burst count, the resolved token payload rides along
---@field max integer the highest registered count
---@field toks {[string]:string} the family's qualifier tokens, keyed by modifier name

---@protected
function M:set_on_unassigned(fn)
	self._on_unassigned = fn
	self.super.on_unassigned_key(fn)
	return false
end

---Drop the event's running burst counters.
---A handler change must not let a pending wait fire through a slot that
---no longer owns it.
---@param ev string
function M:_clear_bursts(ev)
	local pre = ev .. '@'
	for k in pairs(self._m_cnt) do
		if k:sub(1, #pre) == pre then self._m_cnt[k] = 0 end
	end
end

---Register the event's handler with the host after a family change.
---The same handler does not register twice. A swap resets the burst
---counters: a pending wait must not fire through a lost slot.
---@param ev string
---@param hdl fun()
function M:_set_handler(ev, hdl)
	if self._m_handlers[ev] == hdl then return end
	self:_clear_bursts(ev)
	local fn = ev:match 'Mouse' and self.super.on_mouse or self.super.on_key
	fn(ev, hdl)
	self._m_handlers[ev] = hdl
end

---Store the event's raw scroll handler; nil retires it.
---The wheel has no host slot: the single on_scroll handler runs every
---`_m_scroll` entry, so there is nothing to register.
---@param ev string
---@param hdl fun()|nil
function M:_set_scroll(ev, hdl)
	if self._m_scroll[ev] == hdl then return end
	self:_clear_bursts(ev)
	self._m_scroll[ev] = hdl
end

---The default scroll handler swayimg calls for every wheel frame.
---Each axis resolves on its own: an axis claimed by a more specific
---bind does not stop the other axis from falling through.
---Resolution per axis, most specific first:
---1. a section-qualified direction under the pointer (a corner wheel);
---2. a raw axis bind (`ScrollVertical`/`ScrollHorizontal`) with the
---   frame's axis value; it outranks the plain directions;
---3. a plain direction in full accumulated steps (quantized);
---4. the raw `Scroll` bind with the unclaimed deltas;
---5. the unassigned chain with `Scroll` as the unhandled key.
---`v > 0` rolls down, per swayimg's sign.
---@param kmods string swayimg's modifier string, '' or 'Ctrl+Alt+Shift' order
---@param h number
---@param v number
function M:_on_scroll(kmods, h, v)
	kmods = kmods or ''
	h, v = h or 0, v or 0
	local acc = self._m_scroll_acc
	local stepH = not self:_has_axis(kmods, 'Horizontal')
		and (self:_has_dir(kmods, 'ScrollLeft') or self:_has_dir(kmods, 'ScrollRight'))
	local stepV = not self:_has_axis(kmods, 'Vertical')
		and (self:_has_dir(kmods, 'ScrollUp') or self:_has_dir(kmods, 'ScrollDown'))

	if stepV then
		local vs
		vs, acc.v = quantize(acc.v + v)
		for _ = 1, math.abs(vs) do
			local dir = vs > 0 and 'ScrollDown' or 'ScrollUp'
			if not self:_fire_dir(kmods, dir) then self:_scroll_raw(kmods, dir, h, v) end
		end
		v = 0 -- the axis is consumed: the steps own it, the fraction included
	else
		acc.v = 0
	end
	if stepH then
		local hs
		hs, acc.h = quantize(acc.h + h)
		for _ = 1, math.abs(hs) do
			local dir = hs > 0 and 'ScrollRight' or 'ScrollLeft'
			if not self:_fire_dir(kmods, dir) then self:_scroll_raw(kmods, dir, h, v) end
		end
		h = 0 -- the axis is consumed: the steps own it, the fraction included
	else
		acc.h = 0
	end

	-- the unclaimed axes resolve once - a section-owned direction (a
	-- corner wheel), then the raw binds, then the unassigned chain
	if h ~= 0 or v ~= 0 then
		local dir = v ~= 0 and (v > 0 and 'ScrollDown' or 'ScrollUp') or (h > 0 and 'ScrollRight' or 'ScrollLeft')
		if not self:_fire_section(kmods, dir) then self:_scroll_raw(kmods, dir, h, v) end
	end
end

---Whether the direction event carries an unqualified bind.
---Only a plain form quantizes its axis. A section-only form (a
---corner-owned wheel) falls to the per-frame resolution instead.
---@param kmods string
---@param dir string
---@return boolean
function M:_has_dir(kmods, dir)
	local fam = self._m_fam[qkey(kmods, dir)]
	return fam ~= nil and fam[''] ~= nil
end

---Whether a raw axis bind takes the axis under these modifiers.
---@param kmods string
---@param axis 'Vertical'|'Horizontal'
---@return boolean
function M:_has_axis(kmods, axis) return self._m_scroll[qkey(kmods, 'Scroll' .. axis)] ~= nil end

---Fire the direction's section forms under the pointer; the plain form
---stays out. A corner keeps its block even when a raw axis bind outranks
---the plain direction on the rest of the window.
---@param kmods string
---@param dir string
---@return boolean fired
function M:_fire_section(kmods, dir)
	local dk = qkey(kmods, dir)
	local fams = self._m_fam[dk]
	if not fams then return false end
	local hdl = self._m_scroll[dk]
	if not hdl then return false end
	if not fams[''] then return hdl() or false end -- section-only: the dispatcher checks the pointer
	if (B.resolve(fams)) == '' then return false end -- off every block: nothing fires
	hdl()
	return true
end

---Fire the direction's plain form unconditionally; a section-only form
---fires under its block. The caller falls to the raw binds on a miss.
---@param kmods string
---@param dir string
---@return boolean fired
function M:_fire_dir(kmods, dir)
	local dk = qkey(kmods, dir)
	local fams = self._m_fam[dk]
	if not fams then return false end
	local hdl = self._m_scroll[dk]
	if not hdl then return false end
	if fams[''] then
		hdl()
		return true
	end -- the plain form always fires
	return hdl() or false -- a section-only form fires only under its block
end

---The raw tail of a scroll resolution:
---1. a raw axis bind (ScrollVertical/ScrollHorizontal), carrying the
---   axis value;
---2. the raw `Scroll` bind, carrying both deltas;
---3. the unassigned chain.
---@param kmods string
---@param dir string the direction the deltas imply, naming the axis
---@param h number
---@param v number
---@return boolean consumed
function M:_scroll_raw(kmods, dir, h, v)
	local axis = (dir:match 'Left' or dir:match 'Right') and 'Horizontal' or 'Vertical'
	local a = self._m_scroll[qkey(kmods, 'Scroll' .. axis)]
	if a then
		a(axis == 'Horizontal' and h or v)
		return true
	end
	local gkey = qkey(kmods, 'Scroll')
	local g = self._m_scroll[gkey]
	if g then
		g(h, v)
		return true
	end
	self._on_unassigned(gkey)
	return false
end

---Re-apply the event's handler after its family set changed.
---Binds exist: the direct callback or a dispatcher. None does: the
---retire handler.
---@param ev string
function M:_install(ev)
	local fams = self._m_fam[ev]
	if fams then
		local hdl = dispatch.create(self, ev)
		if ev:match 'Scroll' then
			self:_set_scroll(ev, hdl)
		else
			self:_set_handler(ev, hdl)
		end
		return
	end

	-- the event retired:
	-- - a key claims the app slot, so a native default falls to the
	--   unassigned path;
	-- - a button keeps the unhandled notice;
	-- - a wheel keeps nothing: the on_scroll handler outlives its binds
	if ev:match 'Scroll' then
		self:_set_scroll(ev, nil)
		return
	end
	if ev:match 'Mouse' then
		if self._m_handlers[ev] then
			local hdl = self._m_claims[ev] or function() sai.notify('Unhandled mouse: ' .. ev) end
			self._m_claims[ev] = hdl
			self:_set_handler(ev, hdl)
		end
	else
		local hdl = self._m_claims[ev] or function() self._on_unassigned(ev) end
		self._m_claims[ev] = hdl
		self:_set_handler(ev, hdl)
	end
end

---Parse a bind for the family tables. The burst count is clamped to the
---event types that repeat (mouse, wheel); the caller warns on a clamp.
---@param b string
---@return {[string]:string} toks
---@return string ev
---@return string path
---@return integer n the count, clamped
---@return boolean clamped the count asked for a repeat on a plain event
local function parse_bind(b)
	local toks, ev, count = B.split(b)
	local n = count or 1
	local clamped = n > 1 and not (ev:match 'Mouse' or ev:match 'Scroll')
	if clamped then n = 1 end
	return toks, ev, B.path(toks), n, clamped
end

---Register a bind into the event's family set and install the handler
---the creator returns for that set.
function M:_rawmap(b, cfg, action)
	if type(action) == 'string' then action = function() sai.exec(cfg.cb) end end
	if action == nil then return self:_rawunmap(b) end

	local toks, ev, path, n, clamped = parse_bind(b)
	if clamped then sai.log(('sai: %s repeat binds are not supported yet, mapped as a single press'):format(b)) end

	local fams = self._m_fam[ev]
	if not fams then
		fams = {}
		self._m_fam[ev] = fams
	end
	local fam = fams[path]
	if not fam then
		fam = { recs = {}, max = 0, toks = toks }
		fams[path] = fam
	end
	if n > fam.max then fam.max = n end
	fam.recs[n] = action
	self:_install(ev)
end

---Remove a bind from the event's family set; the event retires to its
---fallback once the last form is gone.
function M:_rawunmap(b)
	local _, ev, path, n = parse_bind(b)

	local fams = self._m_fam[ev]
	if fams then
		local fam = fams[path]
		if fam then
			fam.recs[n] = nil -- in place: a deferred fire sees the removal
			fam.max = 0
			for k in pairs(fam.recs) do
				if k > fam.max then fam.max = k end
			end
			if not next(fam.recs) then fams[path] = nil end
		end
		if not next(fams) then self._m_fam[ev] = nil end
	end
	self:_install(ev)
end

---@generic O: sai.api.mode_base
---@param self `O`
---@param api_name appmode_t
---@return O
function M.new(self, api_name)
	local api = self.super ---@diagnostic disable-line: undefined-field
	---@diagnostic disable: inject-field
	self._path = 'sai.' .. api_name
	for k, v in pairs(M) do
		self[k] = v
	end
	self.new = nil

	--- https://github.com/artemsen/swayimg/blob/master/src/appmode.cpp#L11
	self._mark_color = 0xff808080
	if not self._pinch_factor then self._pinch_factor = 1.0 end

	for _, sig in ipairs { 'USR1', 'USR2' } do
		api.on_signal(sig, function() e.trigger { event = 'Signal', mode = api_name, match = sig } end)
	end

	self.reload = function(cb)
		if cb then e.subscribe {
			event = 'ImgChanged',
			once = true,
			callback = cb,
		} end
		self.super.reload()
	end

	-- the base fallback: KP_ downgrade, Shift-toggle for digits and
	-- lowercase, AltGr swallowed, the rest noticed
	self._on_unassigned = function(key)
		local sym = key:match '[^+]+$'
		local ok
		if #sym > 1 then
			if sym:sub(1, 3) == 'KP_' then
				local k = self._mappings[key:gsub('KP_', '')]
				if k then return k.cb() end
			else
				ok = sym:sub(1, 1):match '%l' -- allow ccaron/aacute, not Next/End
			end
		else
			ok = sym:match '%d'
		end

		if ok then
			local k = key:find('Shift', 1, true) and key:gsub('Shift%+', '') or key:gsub('([^+]+)$', 'Shift+%1')
			k = self._mappings[k]
			if k then return k.cb() end
		end

		if key == 'ISO_Level3_Shift' then return end -- AltGr
		sai.notify('Unhandled key: ' .. key)
	end
	api.on_unassigned_key(self._on_unassigned)
	self._m_fam = {}
	self._m_handlers = {}
	self._m_claims = {}
	self._m_scroll = {}
	self._m_scroll_acc = { h = 0, v = 0 }
	self._m_cnt = {}
	-- the single wheel handler serves every scroll bind through `_m_scroll`
	api.on_scroll(function(kmods, h, v) self:_on_scroll(kmods, h, v) end)
	self.warn_on_duplicates = M.warn_on_duplicates
	kp.new(self)

	return proxy.new(self)
end

return M
