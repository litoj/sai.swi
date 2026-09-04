---@module 'sai.lib.reconfigurer'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'

---@overload fun(apply:fun(self:sai.lib.reconfigurer)|boolean)
---@class sai.lib.reconfigurer: sai.api.proxy
---@field protected _cfg {mode:string,fb:{[string]:string}} TODO: simplify
---@field protected _avail fun(idx:string):boolean
---@field protected _enabled boolean
---@field [string] sai.lib.reconfigurer|any
local M = {
	save_user_changes = false, --- update setting override values to currrent state before restoring
}

---@class sai.lib.reconfigurer.sai: sai.lib.reconfigurer,sai
---@field eventloop sai.lib.reconfigurer.eventloop
---@field text sai.text|fun(apply:fun(t:sai.text))
---@field imagelist sai.imagelist|fun(apply:fun(l:sai.imagelist))
---@field viewer sai.viewer|fun(apply:fun(v:sai.viewer))
---@field slideshow sai.slideshow|fun(apply:fun(s:sai.slideshow))
---@field gallery sai.gallery|fun(apply:fun(g:sai.gallery))

---@overload fun(suball:sai.eventloop.hook[])
---@class sai.lib.reconfigurer.eventloop: sai.lib.reconfigurer,sai.eventloop
---@field protected _new {[hook_cfg]:1} hooks to register
---@field protected _old {[hook_cfg]:1} removed hooks to put back when the override gets disabled
---@field protected _filter {[sai.eventloop.filter.opts]:1} params to unsub existing events by

---Compact one-line description of a hook or an unsubscribe filter entry.
local function hook_str(h)
	local ev = type(h.event) == 'table' and table.concat(h.event, ',') or h.event or '*'
	local sel = h.match or h.pattern or h.group or h.id
	return ('%s=%s'):format(ev, tostring(sel or ''))
end

local elmeta = {
	__index = function(_, idx) error('sai.lib.reconfigurer.eventloop does not support index: ' .. idx) end,
	---@diagnostic disable-next-line: redefined-local
	__call = function(self, enable)
		if type(enable) == 'table' then
			for _, v in ipairs(enable) do
				self.subscribe(v)
			end
			return
		end

		if enable == self._enabled then return false end
		self._enabled = enable

		if enable then
			for h, _ in pairs(self._new) do
				e.subscribe(h)
			end

			for f, _ in pairs(self._filter) do
				for h, _ in pairs(e.find_all(f)) do
					self._old[h] = 1
				end
				e.unsubscribe(f)
			end
		else -- disable
			for h, _ in pairs(self._new) do
				e.unsubscribe { id = h }
			end

			for h, _ in pairs(self._old) do
				e.subscribe(h)
			end
			self._old = {}
		end
	end,

	__tostring = function(self)
		local hooks, filters = {}, {}
		for h in pairs(self._new) do
			hooks[#hooks + 1] = hook_str(h)
		end
		for f in pairs(self._filter) do
			filters[#filters + 1] = hook_str(f)
		end
		return U.tbl_to_str { hooks = hooks, filters = filters }
	end,
}

---@return sai.lib.reconfigurer.eventloop
function M.new_evloop()
	---@type sai.lib.reconfigurer.eventloop
	---@diagnostic disable-next-line: missing-fields
	local self = { _enabled = false, _new = {}, _old = {}, _filter = {} }

	self.subscribe = function(h)
		---@diagnostic disable: invisible
		self._new[h] = 1
		if self._enabled then e.subscribe(h) end
		return h
	end

	self.unsubscribe = function(f)
		if f.id and self._new[f.id] then -- change the applied preset only if directly asking for it
			self._new[f.id] = nil
		else
			self._filter[f] = 1
		end
		if self._enabled then e.unsubscribe(f) end
	end

	self.find_all = function(f)
		local h = e._hooks
		-- the registry swap is the whole point: let find_all see only this
		-- preset's hooks, in a plain id-keyed table the typed registry is not
		---@diagnostic disable-next-line: inject-field, assign-type-mismatch
		e._hooks = self._new
		local ret = e.find_all(f)
		---@diagnostic disable-next-line: inject-field
		e._hooks = h
		return ret
	end
	---@diagnostic enable: invisible

	return setmetatable(self, elmeta)
end

local viewer_fb = {
	position = 'default_position',
	scale = 'default_scale',
}
local checked_mode_opts = {
	-- ['sai.gallery'] = { mode = 'gallery', fb = {} },
	['sai.viewer'] = { mode = 'viewer', fb = viewer_fb },
	['sai.slideshow'] = { mode = 'slideshow', fb = viewer_fb },
}

-- TODO: make a separate global setting for custom mode name and obj to allow F1 be generic and work
-- for truly every mode + also show only settings for that mode -> no more tabs
---Requires .super (faked api)
---@param self {super:sai.lib.backer}
---@return self
function M:new()
	---@cast self sai.lib.reconfigurer
	for k, v in pairs(M) do
		if k:sub(1, 2) ~= '__' then self[k] = v end
	end
	self.new = nil
	self.new_evloop = nil
	self._enabled = self._enabled or false
	self._vars = {}
	self._cfg = checked_mode_opts[self.super._path] or false
	self._avail = self._cfg --
			and function(idx) return self._cfg.fb[idx] == nil or self._cfg.mode == sai.mode end
		or function() return true end

	if self.super._path == 'sai' then
		self.eventloop = M.new_evloop()
		self.eventloop.subscribe {
			event = { 'ModeChangedPre', 'ModeChanged' },
			callback = function(ev)
				local vars = rawget(self, ev.mode)
				-- enable/disable the vars in the active mode
				-- because some vars may not be changeable while in other modes (viewer.scale, position...)
				-- FIXME: enabling is now for all modes, meaning scale etc won't get written when in gallery
				if vars and self._enabled then vars(ev.event == 'ModeChanged') end
			end,
		}
	end

	return setmetatable(self, M)
end

function M:__index(idx)
	local subapi = rawget(self.super, idx)
	if not getmetatable(subapi) then return self._vars[idx] end

	rawset(self, idx, M.new { super = subapi, _enabled = self._enabled })
	return self[idx]
end
function M:__newindex(idx, val)
	if val == nil then -- reset the var
		if self._enabled and self._avail(idx) and self._vars[idx].old ~= nil then
			self.super[idx] = self._vars[idx].old
		end

		self._vars[idx] = nil
	else
		local x = self._vars[idx]
		if not x then
			x = {}
			self._vars[idx] = x
		end

		x.new = val
		if self._enabled and self._avail(idx) then
			x.old = self.super[idx]
			self.super[idx] = val
		end
	end
end
function M:__call(enable)
	if type(enable) == 'function' then return enable(self) end

	if enable == self._enabled then return false end
	self._enabled = enable

	if enable then
		for k, v in pairs(self._vars) do
			if self._avail(k) then
				if v.old == nil then v.old = self.super[k] end
				self.super[k] = v.new
			end
		end
	else
		local update = self.save_user_changes
		local fb = self._cfg and self._cfg.fb or ''
		for k, v in pairs(self._vars) do
			if self._avail(k) then
				if v.old ~= nil then
					if update then v.new = self.super[k] end
					self.super[k] = v.old
				else
					k = fb[k] -- name of the fallback key
					if k and self._avail(k) then
						if (self._vars[k] or {}).old ~= nil then
							self.super[k] = self._vars[k].old
						else
							self.super[k] = self.super[k]
						end
					end
				end
				v.old = nil
			end
		end
	end

	-- cascade updates
	-- TODO: what if sai.formats gets changed?
	for k, v in pairs(self) do
		if k:sub(1, 1) ~= '_' and type(v) == 'table' and k ~= 'super' then v(enable) end
	end
end

function M:__tostring()
	---@type {[string]:any}
	local dump = {}
	for k, v in pairs(self._vars) do
		dump[k] = v.new
	end
	-- same traversal as __call: the nested sub-configs, not the internal state
	for k, v in pairs(self) do
		if k:sub(1, 1) ~= '_' and type(v) == 'table' and k ~= 'super' then dump[k] = v end
	end
	return U.tbl_to_str(dump)
end

return M
