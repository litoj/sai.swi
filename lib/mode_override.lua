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
	_help_bind_fmt = '%s\t%s',
	---@type boolean should help_pager be automatically enabled while mode is active
	_auto_help = false,
}
setmetatable(M, { __index = M.super })

local viewer_fb = {
	position = 'default_position',
	scale = 'default_scale',
}
local modes = {
	[swi.gallery] = { mode = 'gallery', fb = {} },
	[swi.viewer] = { mode = 'viewer', fb = viewer_fb },
	[swi.slideshow] = { mode = 'slideshow', fb = viewer_fb },
}

--[[ local var_meta = { -- slow, but this would allow lazy variable loading with dynamicity
	__index = function(t, x)
		if x == 'new' then
			t = rawget(t, '_new')
			if type(t) == 'function' then
				return t()
			else
				return t
			end
		else
			return rawget(t, x)
		end
	end,
	__newindex = function(t, x, v)
		if x == 'new' then x = '_new' end
		rawset(t, x, v)
	end,
} ]]

local function wrap(mo, api)
	local vars = {}
	local cfg = modes[api]
	local checked_set = cfg
			and function(idx, val)
				if cfg.mode == swi.mode then
					if val ~= nil then api[idx] = val end
					return true
				end
			end
		or function(idx, val)
			if val ~= nil then api[idx] = val end
			return true
		end
	return setmetatable({}, {
		__index = function(self, idx)
			rawset(self, idx, wrap(mo, api[idx]))
			return self[idx]
		end,
		__newindex = function(_, idx, val)
			if val == nil then -- reset the var
				if mo._enabled then checked_set(idx, vars[idx].old) end

				vars[idx] = nil
			else
				local x = vars[idx]
				if not x then
					x = {}

					if mo._enabled and checked_set(idx) then x.old = api[idx] end
					vars[idx] = x
				end

				x.new = val
				if mo._enabled then checked_set(idx, val) end
			end
		end,
		__call = function(self, enable)
			if not cfg or cfg.mode == swi.mode then
				local ot = api._trigger
				api._trigger = false
				if enable then
					for k, v in pairs(vars) do
						v.old = api[k]
						api[k] = v.new
					end
				else
					local fb = cfg and cfg.fallback or ''
					for k, v in pairs(vars) do
						if v.old ~= nil then
							api[k] = v.old
						else
							k = fb[k]
							if k then -- name of the fallback key
								if (vars[k] or {}).old ~= nil then
									api[k] = vars[k].old
								else
									api[k] = api[k]
								end
							end
						end
					end
				end
				api._trigger = ot
			end

			-- cascade updates
			for k, v in pairs(self) do
				if k:sub(1, 1) ~= '_' then v(enable) end
			end
		end,
	})
end

local function evloop_wrap(mo)
	local e = swi.eventloop
	local new, filter, old = {}, {}, {}
	local self = {}

	self.subscribe = function(h)
		new[h] = 1
		if mo._enabled then e.subscribe(h) end
		return h
	end

	self.unsubscribe = function(f)
		if f.id or f.callback then
			new[f.id or f.callback] = nil
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
					e.unsubscribe(h)
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
		event = 'ModeChangedPre',
		callback = function(e)
			e = rawget(self.swi, e.mode)
			if e then e(false) end
		end,
	}
	self.swi.eventloop.subscribe {
		event = 'ModeChanged',
		callback = function(e)
			e = rawget(self.swi, e.mode)
			if e and self._enabled then e(true) end
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

	if self._auto_help then self.help_pager.enabled = val end

	return true
end

return M
