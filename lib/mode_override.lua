---@diagnostic disable: invisible
---@module 'swi.lib.mode_override'

local U = require 'swi.lib.utils'
local pager = require 'swi.lib.pager'

---@class swi.lib.mode_override: swi.lib.bind_override
--- Wrapper for auto-changing settings when the mode is active.
--- Supports also eventloop auto registration and deregistration +
--- - `get_subscribed` gets just your mode changes
--- - `unsubscribe` temporarily disables filtered events or permanently removes mode event by id
---
--- Changes are active only while the mode is enabled, then they're reverted.
---@field swi? swi
---@field help_pager? swi.lib.pager included to provide custom keybind help `_path` is defined
local M = {
	super = require 'swi.lib.bind_override',
	-- protected vars - readonly after initialization
	_persist_mode_change = false, ---@protected if disabled mode change disables the mode
	_help_bind_fmt = '%s\t%s', ---@protected

	-- runtime vars - may be changed by the user any time
	save_user_changes = false, --- update setting override values to currrent state before restoring
	auto_help = false, --- should help_pager be automatically enabled while mode is active
}
setmetatable(M, { __index = M.super })

local viewer_fb = {
	position = 'default_position',
	scale = 'default_scale',
}
local checked_mode_opts = {
	-- [swi.gallery] = { mode = 'gallery', fb = {} },
	[swi.viewer] = { mode = 'viewer', fb = viewer_fb },
	[swi.slideshow] = { mode = 'slideshow', fb = viewer_fb },
}

---@param mo swi.lib.mode_override
local function wrap(mo, api)
	local cfg = checked_mode_opts[api]
	local avail = cfg and function(idx) return cfg.fb[idx] == nil or cfg.mode == swi.mode end
		or function() return true end
	return setmetatable({ _vars = {} }, {
		__index = function(self, idx)
			local subapi = rawget(api, idx)
			if not getmetatable(subapi) then return self._vars[idx] end

			rawset(self, idx, wrap(mo, subapi))
			return self[idx]
		end,
		__newindex = function(self, idx, val)
			if val == nil then -- reset the var
				if mo._enabled and avail(idx) and self._vars[idx].old ~= nil then api[idx] = self._vars[idx].old end

				self._vars[idx] = nil
			else
				local x = self._vars[idx]
				if not x then
					x = {}

					self._vars[idx] = x
				end

				x.new = val
				if mo._enabled and avail(idx) then
					x.old = api[idx]
					api[idx] = val
				end
			end
		end,
		__call = function(self, enable)
			local ot = api._trigger
			api._trigger = false
			if enable then
				for k, v in pairs(self._vars) do
					if avail(k) then
						if v.old == nil then v.old = api[k] end
						api[k] = v.new
					end
				end
			else
				local update = mo.save_user_changes
				local fb = cfg and cfg.fb or ''
				for k, v in pairs(self._vars) do
					if avail(k) then
						if v.old ~= nil then
							if update then v.new = api[k] end
							api[k] = v.old
						else
							k = fb[k] -- name of the fallback key
							if k and avail(k) then
								if (self._vars[k] or {}).old ~= nil then
									api[k] = self._vars[k].old
								else
									api[k] = api[k]
								end
							end
						end
						v.old = nil
					end
				end
			end
			api._trigger = ot

			-- cascade updates
			for k, v in pairs(self) do
				if k:sub(1, 1) ~= '_' then v(enable) end
			end
		end,
	})
end

---@param mo swi.lib.mode_override
local function evloop_wrap(mo)
	local e = swi.eventloop
	---@type {[hook_cfg]:1}
	local new, old = {}, {}
	local filter = {}
	local self = {}

	self.subscribe = function(h)
		new[h] = 1
		if mo._enabled then e.subscribe(h) end
		return h
	end

	self.unsubscribe = function(f)
		if f.id then
			new[f.id] = nil
		else
			filter[f] = 1
		end
		if mo._enabled then e.unsubscribe(f) end
	end

	self.get_subscribed = function(f)
		local h = e._hooks
		---@diagnostic disable: inject-field
		e._hooks = new
		local ret = e.get_subscribed(f)
		e._hooks = h
		return ret
	end

	return setmetatable(self, {
		__index = e,
		__call = function(_, enable)
			if enable then
				for h, _ in pairs(new) do
					e.subscribe(h)
				end

				for f, _ in pairs(filter) do
					for h, _ in pairs(e.get_subscribed(f)) do
						old[h] = 1
					end
					e.unsubscribe(f)
				end
			else -- disable
				for h, _ in pairs(new) do
					e.unsubscribe { id = h }
				end

				for h, _ in pairs(old) do
					e.subscribe(h)
				end
				old = {}
			end
		end,
	})
end

---@return swi.lib.mode_override
function M:new()
	U.new_object(self, M)
	if self._path then
		local name = self._path:gsub('^swi%.', '')
		---@diagnostic disable-next-line: missing-fields
		self.help_pager = pager.new {
			_path = self._path .. '.help_pager',
			_title = name:sub(1, 1):upper() .. name:sub(2) .. ' binds:\t',
			_position = 'topright',
		}
	end
	self.swi = wrap(self, swi)
	rawset(self.swi, 'eventloop', evloop_wrap(self))
	self.swi.eventloop.subscribe {
		event = { 'ModeChangedPre', 'ModeChanged' },
		callback = function(e)
			if e.event == 'ModeChangedPre' and self._mode == e.mode and not self._persist_mode_change then
				self.enabled = false
				return
			end

			local vars = rawget(self.swi, e.mode)
			-- check if enabled because swi vars may get disabled before events -> avoid double update
			if vars and self._enabled then vars(e.event == 'ModeChanged') end
		end,
	}

	---@diagnostic disable-next-line: return-type-mismatch
	return M.super.new(self)
end

function M:set_mode(mode)
	self.help_pager.mode = mode
	M.super.set_mode(self, mode)
end

function M:set_enabled(val)
	if self._enabled == val then return false end
	M.super.set_enabled(self, val)

	-- cache the bind help, but don't display it automatically
	if val and rawget(self.help_pager, '_last_cnt') ~= #self._mappings then
		self.help_pager.lines = U.str_bindlist(self, self._help_bind_fmt)
		rawset(self.help_pager, '_last_cnt', #self._mappings)
	end
	self.swi(val)

	if self.auto_help then self.help_pager.enabled = val end

	return true
end

return M
