---@module 'sai.api.mode_base'

local proxy = require 'sai.api.proxy'
local e = require 'sai.api.eventloop'
local kp = require 'sai.lib.keybind_processor'
local B = require 'sai.lib.bindmods'

---@class sai.api.mode_base: mode_base, sai.lib.keybind_processor
---@field super swayimg_appmode
---@field private _m_wheel {v:number, h:number} the pending wheel fractions per axis
---@field private _m_burst {id:string, cnt:integer}|false the pending multi-click burst, false when none
local M = { warn_on_duplicates = true, multiclick_delay = 175 }

---@param kmods string swayimg's modifier string, '' for none
---@param name string the event name
---@return string the bind key
local function qkey(kmods, name) return kmods == '' and name or (kmods .. '+' .. name) end

---One family per qualifier path of an event: the burst-indexed actions
---and the tokens that formed the path.
---@class sai.api.mode_base.bind_family
---@field actions {[integer]:fun(...)} action per burst count, the resolved token payload rides along
---@field max_count integer the highest registered count
---@field tokens {[string]:string} the family's qualifier tokens, keyed by modifier name

---Set the unassigned-key fallback.
---@protected
---@param fn fun(key:string)
---@return false
function M:set_on_unassigned(fn)
	self._on_unassigned = fn
	return false
end

---Run the bind that claims a key, most specific live path first.
---@param key string the bind's key: event name with modifiers ('Ctrl+j', 'MouseLeft', 'ScrollDown')
---@param allow_plain? boolean default true: false keeps the unqualified path out
---@param times? integer default 1: one run per whole wheel unit through the multi-click burst
---@return boolean ran false when nothing claims the key
function M:_run_bind(key, allow_plain, times)
	if allow_plain == nil then allow_plain = true end
	local fams = self:_collect(key)
	if not fams then return false end
	local path
	for _, p in ipairs(B.candidates(fams)) do
		if (p ~= '' or allow_plain) and B.validate(p, fams) then
			path = p
			break
		end
	end
	if not path then return false end
	-- the payload of the found path: its tokens are live
	local args, nargs = B.validate(path, fams)
	local fam = fams[path]
	local ck = key .. '@' .. path
	for _ = 1, times or 1 do
		-- one press at a time: a new press replaces the pending burst
		local prev = self._m_burst
		local burst = { id = ck, cnt = prev and prev.id == ck and prev.cnt + 1 or 1 }
		self._m_burst = burst
		local fn = fam.actions[burst.cnt]
		local run = function()
			self._m_burst = false
			if fn then fn(unpack(args, 1, nargs)) end
		end
		if burst.cnt >= fam.max_count then
			run()
		else
			sai.defer_fn(function()
				if self._m_burst == burst then run() end
			end, self.multiclick_delay)
		end
	end
	return true
end

---The universal input handler: run the bind that claims a key, else
---the unassigned chain takes it.
---@param key string the bind's key: event name with modifiers ('Ctrl+j', 'MouseLeft')
function M:_handle(key)
	if not self:_run_bind(key) then self._on_unassigned(key) end
end

---The possible keys of a wheel frame, from the clumped accumulated deltas.
---@param v number accumulated vertical delta, positive down
---@param h number accumulated horizontal delta, positive right
---@return {[string]:{pos:string, neg:string, axis:string, units:integer, frac:number}} keys per axis ('v','h'): the two direction keys, the raw axis key, the whole units (their sign names the direction) and the fraction below a unit
function M:_wheel_keys(v, h)
	local fv, fh = math.fmod(v, 1), math.fmod(h, 1)
	return {
		v = {
			pos = 'ScrollDown',
			neg = 'ScrollUp',
			axis = 'ScrollVertical',
			units = v - fv,
			frac = fv,
		},
		h = {
			pos = 'ScrollRight',
			neg = 'ScrollLeft',
			axis = 'ScrollHorizontal',
			units = h - fh,
			frac = fh,
		},
	}
end

---The wheel handler: the universal handler's twin over the possible
---keys the clumped frame generates. Nothing claims the tail: the
---unassigned chain.
---@param kmods string swayimg's modifier string, '' or 'Ctrl+Alt+Shift' order
---@param h number the frame's horizontal delta, positive right
---@param v number the frame's vertical delta, positive down
function M:_on_scroll(kmods, h, v)
	local w = self._m_wheel
	if h == 0 and v == 0 then return end

	-- the clumped frame: the units feed the direction forms, the
	-- fractions stay in the accumulators
	local keys = self:_wheel_keys(w.v + v, w.h + h)
	w.v, w.h = keys.v.frac, keys.h.frac
	local left = { v = v, h = h }

	-- the direction forms run once per unit; a miss rides to the axis value
	local fired, miss = { v = false, h = false }, { v = 0, h = 0 }
	for _, a in ipairs { 'v', 'h' } do
		local f = keys[a]
		if f.units ~= 0 then
			local key = qkey(kmods, f.units > 0 and f.pos or f.neg)
			-- the plain direction form stays out while a raw axis bind owns the axis
			local plain = self:_collect(qkey(kmods, f.axis)) == nil
			fired[a] = self:_run_bind(key, plain, math.abs(f.units))
		end
		if fired[a] then
			-- a fired step resets the other axis's fraction and claims its own frame delta
			w[a == 'v' and 'h' or 'v'] = 0
			left[a] = 0
		else
			miss[a] = f.units
		end
	end

	-- the axis forms take the missed units plus the fraction; a
	-- numeric return becomes the new accumulator
	for _, a in ipairs { 'v', 'h' } do
		if not fired[a] then
			local fams = self:_collect(qkey(kmods, keys[a].axis))
			local fam = fams and fams[''] or nil
			if w[a] + miss[a] ~= 0 and fam and fam.max_count == 1 and fam.actions[1] then
				local ret = fam.actions[1](w[a] + miss[a])
				w[a] = (type(ret) == 'number') and ret or 0
				left[a] = 0
			end
		end
	end

	-- the plain `Scroll` takes what no form claimed; a live direction
	-- form or an opposite plain form can hold its axis back
	local function unclaimed(d, pos, neg)
		local fams = self:_collect(qkey(kmods, d > 0 and pos or neg))
		if fams and B.live(fams) then return 0 end
		local of = self:_collect(qkey(kmods, d > 0 and neg or pos))
		if of and of[''] and math.abs(d) < 1 then return 0 end
		return d
	end
	for _, a in ipairs { 'v', 'h' } do
		if left[a] ~= 0 then left[a] = unclaimed(left[a], keys[a].pos, keys[a].neg) end
	end
	if left.v == 0 and left.h == 0 then return end

	local sk = qkey(kmods, 'Scroll')
	local fams = self:_collect(sk)
	if not fams then
		self._on_unassigned(sk)
		return
	end
	local first = next(fams)
	if first == '' and next(fams, first) == nil and fams[''].max_count == 1 then
		-- the plain single form gets the raw deltas, not a token payload
		local fn = fams[''].actions[1]
		if fn then fn(left.h, left.v) end
	else
		self:_run_bind(sk)
	end
	-- an axis that rode to the plain tail leaves no fraction behind
	for _, a in ipairs { 'v', 'h' } do
		if left[a] ~= 0 then w[a] = 0 end
	end
end

---Group the key's mappings by qualifier path, on the spot: enable and
---disable never leave a stale table behind.
---@param key string the bind's key: event name with modifiers
---@return {[string]:sai.api.mode_base.bind_family}? families keyed by qualifier path; nil when nothing maps the key
function M:_collect(key)
	local fams = nil
	for b, cfg in pairs(self._mappings or {}) do
		local tokens, event, count = B.split(b)
		if event == key and cfg and cfg.cb then
			local n = count or 1
			local path = B.path(tokens)
			fams = fams or {}
			local fam = fams[path]
			if not fam then
				fam = { actions = {}, max_count = 0, tokens = tokens }
				fams[path] = fam
			end
			if n > fam.max_count then fam.max_count = n end
			local fn = cfg.cb
			if type(fn) == 'string' then fn = function() sai.exec(cfg.cb) end end
			fam.actions[n] = fn
		end
	end
	return fams
end

-- Push and pop need no mode-side work: every input already routes
-- through the universal handlers, and whatever no bind claims falls
-- to the unassigned chain.
function M:_rawmap() end

function M:_rawunmap() end

---@generic O: sai.api.mode_base
---@param self `O`
---@param api_name appmode_t the host mode the instance serves
---@return O the mode instance
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

	-- clear every host bind so the universal handlers below own the
	-- mode alone; bind_reset clears the signals too, so they follow it
	api.bind_reset()
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

	-- the base fallback: KP_ downgrade, Shift-toggle for digits and lowercase
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

		if sym == 'ISO_Level3_Shift' then return end
		sai.notify('Unhandled key: ' .. key)
	end
	self._m_wheel = { v = 0, h = 0 }
	self._m_burst = false
	-- the host wraps: pure wraps of the handlers
	api.on_unassigned_key(function(key) self:_handle(key) end)
	for _, btn in ipairs { 'MouseLeft', 'MouseMiddle', 'MouseRight' } do
		api.on_mouse(btn, function() self:_handle(btn) end)
	end
	api.on_scroll(function(kmods, h, v) self:_on_scroll(kmods, h, v) end)
	self.warn_on_duplicates = M.warn_on_duplicates
	kp.new(self)

	return proxy.new(self)
end

return M
