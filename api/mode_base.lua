---@module 'sai.api.mode_base'

local proxy = require 'sai.api.proxy'
local e = require 'sai.api.eventloop'
local kp = require 'sai.lib.keybind_processor'
local B = require 'sai.lib.bindmods'

---@class sai.api.mode_base: mode_base, sai.lib.keybind_processor
---@field super swayimg_appmode
---@field private _m_fam {[string]:{[string]:bindfam}} per event name: qualifier path -> bind family
---@field private _m_raw {[string]:boolean} event names with the dispatcher registered
---@field private _m_cnt {[string]:integer} burst counts of the running presses, per event and path
local M = { warn_on_duplicates = true, multiclick_delay = 175 }

---One family per qualifier path of an event: the burst-indexed actions
---and the tokens that formed the path.
---@class bindfam
---@field recs {[integer]:fun()} action per burst count
---@field max integer the highest registered count
---@field toks {[string]:string} the family's qualifier tokens, keyed by modifier name

---@protected
function M:set_on_unassigned(fn)
	self._on_unassigned = fn
	self.super.on_unassigned_key(fn)
	return false
end

local function fire(self, fam, ev, cnt, args, nargs)
	-- one burst per event: a fire on any path ends the pending waits of
	-- the event's other paths (the pointer left the block mid-burst)
	local pre = ev .. '@'
	for k in pairs(self._m_cnt) do
		if k:sub(1, #pre) == pre then self._m_cnt[k] = 0 end
	end
	local fn = fam.recs[cnt]
	if fn then fn(unpack(args, 1, nargs)) end
end

---One dispatcher per event name: resolves qualifier tokens and fires the matched family.
---Nothing matched: a key runs the unassigned path, a button stays silent.
---@param ev string
---@param key boolean the event registers with on_key, not on_mouse
---@return fun() the handler for the raw button
local function dispatch(self, ev, key)
	return function()
		local fams = self._m_fam[ev]
		if not fams then return end
		local path, args, nargs = B.resolve(fams)
		local fam = fams[path]
		if not fam then
			if key then self._on_unassigned(ev) end
			return
		end

		local ck = ev .. '@' .. path
		local cnt = (self._m_cnt[ck] or 0) + 1
		self._m_cnt[ck] = cnt
		if cnt < fam.max then -- a higher count is registered: the burst may grow
			local held = cnt
			sai.defer_fn(function()
				if self._m_cnt[ck] == held then fire(self, fam, ev, cnt, args, nargs) end
			end, self.multiclick_delay)
			return
		end
		fire(self, fam, ev, cnt, args, nargs)
	end
end

---Register a bind: any event carries modifier tokens the same way
---(sai.lib.bindmods), one dispatcher serves every form of an event.
function M:_rawmap(b, cfg, action)
	if type(action) == 'string' then action = function() sai.exec(cfg.cb) end end
	local toks, ev, count = B.split(b)
	local fams = self._m_fam[ev]
	local path = B.path(toks)
	local n = count or 1

	if not action then
		if not fams then
			-- nothing dispatched here: still claim the app slot, so a native bind
			-- falls to the unassigned path; a button keeps whatever the app does with it
			if not (ev:match 'Mouse' or ev:match 'Scroll') then
				self.super.on_key(ev, function() self._on_unassigned(ev) end)
			end
			return
		end
		local fam = fams[path]
		if fam then
			fam.recs[n] = nil -- in place: a deferred fire sees the removal
			fam.max = 0
			for k in pairs(fam.recs) do
				if k > fam.max then fam.max = k end
			end
			if not next(fam.recs) then fams[path] = nil end
		end
		if not next(fams) then
			self._m_fam[ev] = nil
			if self._m_raw[ev] then
				self._m_raw[ev] = nil
				if ev:match 'Mouse' or ev:match 'Scroll' then
					self.super.on_mouse(ev, function() sai.notify('Unhandled mouse: ' .. ev) end)
				else
					self.super.on_key(ev, function() self._on_unassigned(ev) end)
				end
			end
		end
		return
	end

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
	if not self._m_raw[ev] then
		self._m_raw[ev] = true
		local mouse = ev:match 'Mouse' or ev:match 'Scroll'
		local fn = mouse and self.super.on_mouse or self.super.on_key
		fn(ev, dispatch(self, ev, not mouse))
	end
end
M._rawunmap = M._rawmap

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
	self._m_raw = {}
	self._m_cnt = {}
	self.warn_on_duplicates = M.warn_on_duplicates
	kp.new(self)

	return proxy.new(self)
end

return M
