---@module 'sai.lib.reconfigurer'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'

---@overload fun(apply:fun(self:sai.lib.reconfigurer)|boolean)
---@class sai.lib.reconfigurer: sai.api.proxy
---@field protected _special {[string]:sai.lib.reconfigurer.special} custom behaviour of the api's special fields
---@field protected _avail fun(idx:string):boolean
---@field protected _enabled boolean
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

---@param self sai.lib.reconfigurer.eventloop|sai.lib.reconfigurer?
---@return sai.lib.reconfigurer.eventloop
function M.new_evloop(self)
	---@type sai.lib.reconfigurer.eventloop
	---@diagnostic disable-next-line: missing-fields
	self = self or { _enabled = false }
	---@diagnostic disable: invisible
	self._new = {}
	self._old = {}
	self._filter = {}

	self.subscribe = function(h)
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

---State of one overridden field, stored in _vars by field name
---@class sai.lib.reconfigurer.override
---@field new any value the override wants to set
---@field old any? value captured when the override first took the field over; nil when it never got applied
---@field timeout? number restore decision of the sai.text.status special: the original status_timeout at takeover time

---Special field behaviour: some overrides cannot be expressed as a plain
---value swap, so a field can register functions around the swap.
---@class sai.lib.reconfigurer.special
---@field avail? fun(self:sai.lib.reconfigurer):boolean is the field settable in the current state
---@field restore_wanted? fun(self:sai.lib.reconfigurer, override:sai.lib.reconfigurer.override):boolean may the plain swap write the override's old value back (default: yes)
---@field apply? fun(self:sai.lib.reconfigurer, override:sai.lib.reconfigurer.override) runs after the override got applied
---@field restore? fun(self:sai.lib.reconfigurer, override:sai.lib.reconfigurer.override, old:any) runs after the override got restored; old is nil when there was nothing to restore

---Restore the default a view field derives from: our own default override
---when we have one, else re-set the current value so the api re-derives from it
---@param self sai.lib.reconfigurer
---@param field string name of the default_* field
local function restore_default(self, field)
	local default_override = self._vars[field]
	if default_override and default_override.old ~= nil then
		self.super[field] = default_override.old
	else
		self.super[field] = self.super[field]
	end
end

local function view_field(mode, default)
	return {
		-- the current view can only be changed while in its mode
		avail = function() return sai.mode == mode end,
		-- nothing of ours to restore: re-derive the view from its default
		restore = function(self, _, old)
			if old == nil then restore_default(self, default) end
		end,
	}
end

-- the text layer is one shared flag: the trees holding it on must keep it on
-- even when one of them restores its own off state
---@type {[sai.lib.reconfigurer]:boolean}
local layer_holders = setmetatable({}, { __mode = 'k' })

---A block var of ours is either our own content, or an emptier: an empty value
---put over a stale block when taking the layer over. The emptier may only undo
---its own blank - content another owner rendered into the block since must
---survive us.
---@param location block_position_t
---@return sai.lib.reconfigurer.special
local function block_field(location)
	return {
		restore_wanted = function(self, override)
			return next(override.new or {}) ~= nil or not next(self.super[location] or {})
		end,
	}
end

---Custom field behaviour per api, see sai.lib.reconfigurer.special
local special_fields = {
	['sai.viewer'] = {
		position = view_field('viewer', 'default_position'),
		scale = view_field('viewer', 'default_scale'),
	},
	['sai.slideshow'] = {
		position = view_field('slideshow', 'default_position'),
		scale = view_field('slideshow', 'default_scale'),
	},
	['sai.text'] = {
		status = {
			-- decide on the restore at takeover time: a later status_timeout
			-- change must not reclassify an already borrowed status
			apply = function(self, override)
				local timeout_var = self._vars.status_timeout
				override.timeout = timeout_var and timeout_var.old or self.super.status_timeout
			end,
			-- a timed status expires on its own: restoring its text would
			-- re-display an already gone message, so only a permanent one survives
			restore = function(self, override, old)
				if old == nil or override.timeout == 0 then return end
				self.super.status = ''
			end,
		},
		enabled = {
			-- taking the layer over from a disabled one: the blocks nobody
			-- overrides hold stale text that would flash once it turns on
			apply = function(self, override)
				-- we hold the layer on from now on, see the restore below
				if override.new == true then layer_holders[self] = true end
				if override.old ~= false or override.new ~= true then return end

				for _, location in ipairs(U.block_positions) do
					local var = self._vars[location]
					if
						not (var and next(var.new or {})) -- our own content: keep it
						and next(self.super[location] or {})
					then -- non-empty: stale
						self[location] = {} -- emptier: restore() removes it again
					end
				end
			end,
			-- remove the emptiers so they cannot re-apply on a later enable:
			-- the user may have enabled the text layer themselves in the meantime
			restore = function(self, override, old)
				layer_holders[self] = nil
				-- we turned the layer on but other holders still need it: the
				-- plain swap above already restored it to off, bring it back up
				if old == false and next(layer_holders) then self.super.enabled = true end
				if old ~= false then return end -- nothing was emptied

				for _, location in ipairs(U.block_positions) do
					local emptier = self._vars[location]
					-- only the emptiers: our own content vars must survive
					if emptier and not next(emptier.new or {}) then
						-- undo our blank, but never over content another owner
						-- rendered into the block since
						if not next(self.super[location] or {}) and emptier.old ~= nil then
							self.super[location] = emptier.old
						end
						self._vars[location] = nil
					end
				end
			end,
		},
	},
}

for _, location in ipairs(U.block_positions) do
	special_fields['sai.text'][location] = block_field(location)
end

-- TODO: make a separate global setting for custom mode name and obj to allow F1 be generic and work
-- for truly every mode + also show only settings for that mode -> no more tabs
---Requires .super (faked api)
---@param self {super:sai.lib.backer}
---@return self
function M:new()
	self._enabled = self._enabled or false
	if self.super._path == 'sai.eventloop' then return M.new_evloop(self) end

	---@cast self sai.lib.reconfigurer
	for name, method in pairs(M) do
		if name:sub(1, 2) ~= '__' and name:sub(1, 3) ~= 'new' then self[name] = method end
	end
	self._vars = {}
	self._special = special_fields[self.super._path] or {}
	self._avail = function(field)
		local special = self._special[field]
		return not special or not special.avail or special.avail(self)
	end

	if self.super._path == 'sai' then
		self.eventloop = M.new_evloop()
		self.eventloop.subscribe {
			event = { 'ModeChangedPre', 'ModeChanged' },
			callback = function(ev)
				local mode_cfg = rawget(self, ev.mode)
				-- enable/disable the vars in the active mode
				-- because some vars may not be changeable while in other modes (viewer.scale, position...)
				-- FIXME: enabling is now for all modes, meaning scale etc won't get written when in gallery
				if mode_cfg and self._enabled then mode_cfg(ev.event == 'ModeChanged') end
			end,
		}
	end

	return setmetatable(self, M)
end

function M:__index(field)
	local subapi = rawget(self.super, field)
	if not getmetatable(subapi) then return self._vars[field] end

	rawset(self, field, M.new { super = subapi, _enabled = self._enabled })
	return self[field]
end
function M:__newindex(field, value)
	if value == nil then -- reset the var
		local override = self._vars[field]
		if override and self._enabled and self._avail(field) and override.old ~= nil then
			local special = self._special[field]
			if not special or not special.restore_wanted or special.restore_wanted(self, override) then
				self.super[field] = override.old
			end

			if special and special.restore then special.restore(self, override, override.old) end
		end

		self._vars[field] = nil
	else
		local override = self._vars[field]
		if not override then
			override = {}
			self._vars[field] = override
		end

		override.new = value
		if self._enabled and self._avail(field) then
			-- capture only on the first write: later value updates must not
			-- overwrite the original we have to restore to
			if override.old == nil then override.old = self.super[field] end
			self.super[field] = value

			local special = self._special[field]
			if special and special.apply then special.apply(self, override) end
		end
	end
end
function M:__call(enable)
	if type(enable) == 'function' then return enable(self) end

	if enable == self._enabled then return false end
	self._enabled = enable

	if enable then
		for field, override in pairs(self._vars) do
			if self._avail(field) then
				if override.old == nil then override.old = self.super[field] end
				self.super[field] = override.new

				local special = self._special[field]
				if special and special.apply then special.apply(self, override) end
			end
		end
	else
		local update = self.save_user_changes
		for field, override in pairs(self._vars) do
			if self._avail(field) then
				local special = self._special[field]
				if
					override.old ~= nil
					and (not special or not special.restore_wanted or special.restore_wanted(self, override))
				then
					if update then override.new = self.super[field] end
					self.super[field] = override.old
				end

				if special and special.restore then special.restore(self, override, override.old) end
				override.old = nil
			end
		end
	end

	-- cascade updates
	-- TODO: what if sai.formats gets changed?
	for name, sub_config in pairs(self) do
		if name:sub(1, 1) ~= '_' and type(sub_config) == 'table' and name ~= 'super' then sub_config(enable) end
	end
end

function M:__tostring()
	---@type {[string]:any}
	local dump = {}
	for field, override in pairs(self._vars) do
		dump[field] = override.new
	end
	-- same traversal as __call: the nested sub-configs, not the internal state
	for name, sub_config in pairs(self) do
		if name:sub(1, 1) ~= '_' and type(sub_config) == 'table' and name ~= 'super' then dump[name] = sub_config end
	end
	return U.tbl_to_str(dump)
end

return M
