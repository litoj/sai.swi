---@diagnostic disable: invisible
---@module 'sai.lib.reconfigurer'

local e = require 'sai.api.eventloop'
local U = require 'sai.lib.utils'
local evloop = require 'sai.lib.reconfigurer_evloop'

---@overload fun(enable:boolean|fun(self:sai.lib.reconfigurer))
---@class sai.lib.reconfigurer: sai.api.proxy
---@field _handlers {[string]:sai.lib.reconfigurer.special}
---@field _deferred {[string]:true} applied display vars, released first on disable
---@field _enabled boolean
---@field _parked {[string]:unknown} wanted values, parked until they can apply
local M = {
	save_user_changes = false, --- capture live values on release so re-enable replays user edits
}

---@class sai.lib.reconfigurer.sai: sai.lib.reconfigurer,sai
---@field eventloop sai.lib.reconfigurer.eventloop
---@field text sai.lib.reconfigurer.text
---@field imagelist sai.imagelist|fun(apply:fun(l:sai.imagelist))
---@field viewer sai.viewer|fun(apply:fun(v:sai.viewer))
---@field slideshow sai.slideshow|fun(apply:fun(s:sai.slideshow))
---@field gallery sai.gallery|fun(apply:fun(g:sai.gallery))

local stacks = require('sai.lib.registry').vars

---A deferred display var (layer flag, status): applied last, released first.
---@param self sai.lib.reconfigurer
---@param field string
---@return boolean
local function is_deferred(self, field)
	local special = self._handlers[field]
	return special and special.defer_last == true
end

---@param self sai.lib.reconfigurer
local function apply_parked(self)
	---@type {[string]:sai.lib.registry.record}
	local deferred = {}
	-- a block apply may arm the layer and remarry fields out of `_parked`
	-- while we iterate: snapshot the keys so the walk itself stays stable
	local parked_fields = {}
	for field in pairs(self._parked) do
		parked_fields[#parked_fields + 1] = field
	end
	for _, field in ipairs(parked_fields) do
		local parked = self._parked[field]
		if parked ~= nil and self:_can_apply(field) then
			self._parked[field] = nil
			---@type sai.lib.registry.record
			local rec = { new = parked, old = self.super[field] }
			if is_deferred(self, field) then
				deferred[field] = rec
			else
				self:_apply_record(field, rec)
			end
		end
	end
	self._deferred = {}
	for field, rec in pairs(deferred) do
		self._deferred[field] = true
		self:_apply_record(field, rec)
	end
end

---@param self sai.lib.reconfigurer
local function release_all(self)
	local deferred = self._deferred
	for field in pairs(deferred) do
		if self:_can_apply(field) then M._release(self, field) end
	end
	for field, stack in pairs(stacks[self.super]) do
		if stack[self] and self:_can_apply(field) then M._release(self, field) end
	end
	-- parked overrides too: their specials run restore on disable
	local parked_fields = {}
	for field in pairs(self._parked) do
		parked_fields[#parked_fields + 1] = field
	end
	for _, field in ipairs(parked_fields) do
		if self:_can_apply(field) then M._release(self, field) end
	end
end

---Special fields: overrides that need more than a plain value swap.
---@class sai.lib.reconfigurer.special
---@field can_apply? fun(self:sai.lib.reconfigurer):boolean
---@field apply? fun(self:sai.lib.reconfigurer, override:sai.lib.registry.record) own the write
---@field restore? fun(self:sai.lib.reconfigurer, override:sai.lib.registry.record, prior:unknown, field:string, is_top:boolean) only the top record may write the field
---@field defer_last? boolean apply last on enable, release first on disable

---@param self sai.lib.reconfigurer
---@param field string
---@return sai.lib.registry.record?
local function peek_record(self, field)
	local parked = self._parked[field]
	if parked ~= nil then return { new = parked } end
	return stacks[self.super][field][self]
end

---Gate a field on the active mode, refreshing the fallback field on release.
---@param active_mode string the sai.mode this field only applies in
---@param fallback_field string the default field to refresh when nothing was applied
---@return sai.lib.reconfigurer.special
local function viewer_state_field(active_mode, fallback_field)
	return {
		can_apply = function() return sai.mode == active_mode end,
		restore = function(self, _, prior, field, is_top)
			if not is_top then return end
			if prior == nil then
				-- no prior value: refresh the fallback unless it has an override;
				local fallback_override = peek_record(self, fallback_field)
				local value = fallback_override and fallback_override.old or self.super[fallback_field]
				if value ~= nil then self.super[fallback_field] = value end
			else
				self.super[field] = prior
			end
		end,
	}
end

---@type {[string]:{[string]:sai.lib.reconfigurer.special}}
local specials_by_path = {
	['sai.viewer'] = {
		position = viewer_state_field('viewer', 'default_position'),
		scale = viewer_state_field('viewer', 'default_scale'),
	},
	['sai.slideshow'] = {
		position = viewer_state_field('slideshow', 'default_position'),
		scale = viewer_state_field('slideshow', 'default_scale'),
	},
}

---@overload fun(enable:boolean|fun(self:sai.api.text))
---@class sai.lib.reconfigurer.text: sai.lib.reconfigurer,sai.api.text
---@field _user_pinned {[string]:true} user writes that outlive machinery defaults

specials_by_path['sai.text'] = {
	status = {
		defer_last = true,
		-- the centered status renders multiline as a block: hold the aligned value
		---@param self sai.lib.reconfigurer.text
		---@param override sai.lib.registry.record
		apply = function(self, override)
			local timeout_var = peek_record(self, 'status_timeout')
			if not (timeout_var and timeout_var.new ~= 0) then self:_set('status_timeout', 0, true) end
			local aligned = U.align_block(override.new)
			if aligned ~= override.new then -- the raw write: re-drive the aligned value
				self:_set('status', aligned)
				return -- the re-entered apply takes the no-diff branch and writes super
			end
			self.super.status = override.new
		end,
		-- a timed status is long gone; restore only a permanent one
		restore = function(self, _, prior, _, is_top)
			if prior ~= nil and is_top then
				local timeout_var = peek_record(self, 'status_timeout')
				local timeout = timeout_var and timeout_var.old or self.super.status_timeout
				-- ' ' repaints, '' does not
				self.super.status = timeout == 0 and prior or ' '
			end
			-- a re-set status keeps the pin
			local status_var = peek_record(self, 'status')
			if status_var and status_var.old ~= nil then return end
			-- release the pin once our status is gone
			local timeout_var = peek_record(self, 'status_timeout')
			if timeout_var and not self._user_pinned.status_timeout then self:_unset('status_timeout', true) end
		end,
	},
	status_timeout = {
		-- undo only our own value: a late direct write survives
		restore = function(self, override, prior, _, is_top)
			if prior == nil or not is_top then return end
			if self.super.status_timeout ~= override.new then return end
			-- a live status keeps the pin
			local status_var = peek_record(self, 'status')
			self.super.status_timeout = self._enabled and status_var and status_var.old ~= nil and 0 or prior
		end,
	},
	enabled = {
		defer_last = true,
		-- the layer went off: drop our blanks so they cannot re-apply
		restore = function(self, _, prior, _, is_top)
			if prior == false then
				-- keep the layer up while another live layer still needs it
				local held = false
				for _, entry in ipairs(stacks[self.super].enabled) do
					if entry.new == true then
						held = true
						break
					end
				end
				local own = false
				if self._enabled then
					for _, location in ipairs(U.block_positions) do
						local v = stacks[self.super][location][self]
						if v and v.old ~= nil and next(v.new or {}) then
							own = true
							break
						end
					end
				end
				if is_top then self.super.enabled = held or own end
				if not own then
					for _, location in ipairs(U.block_positions) do
						local emptier = peek_record(self, location)
						-- only drop blank emptiers; a location holding our content survives
						if emptier and not next(emptier.new or {}) then
							self:_unset(location, true) -- undo the blank without re-parking it
						end
					end
				end
			elseif is_top and prior ~= nil then
				-- we never armed the layer: plain-restore the prior value
				self.super.enabled = prior
			end
		end,
	},
}

---A block var: our content, or an emptier (a blank over a stale block).
---@param location block_position_t
---@return sai.lib.reconfigurer.special
local function block_field(location)
	return {
		-- arm the layer (unless we manage it); blank the stale corners
		apply = function(self, override)
			local enabled_var = peek_record(self, 'enabled')
			local from_off = enabled_var and enabled_var.old
			if from_off == nil then from_off = self.super.enabled end
			-- a mode flip re-applies the block into another mode's text
			-- layer: that move clears the new mode's stale corners even
			-- though another display may hold the layer on
			local moved = rawget(self, '_applied_mode') ~= nil and rawget(self, '_applied_mode') ~= sai.mode
			rawset(self, '_applied_mode', sai.mode)
			self.super[location] = override.new
			if not enabled_var then self:_set('enabled', true, true) end
			if from_off ~= false and not moved then return end -- live content: not ours to clear

			local emptiers = {}
			for _, other in ipairs(U.block_positions) do
				if
					other ~= location
					and not peek_record(self, other)
					and #stacks[self.super][other] == 0
					and next(self.super[other] or {})
				then
					-- park the blank first so the _set below does not re-enter
					self._parked[other] = {}
					emptiers[#emptiers + 1] = other
				end
			end
			for _, other in ipairs(emptiers) do
				self:_set(other, {}, true)
			end
		end,
		-- undo only our own content/blank; another owner's survives
		restore = function(self, override, prior, _, is_top)
			if prior ~= nil and is_top then
				if next(override.new or {}) or not next(self.super[location] or {}) then
					self.super[location] = prior
				end
			end
			local v = peek_record(self, location)
			if v and v.old ~= nil then return end
			-- release the armed layer flag once no location of ours shows
			local enabled_var = peek_record(self, 'enabled')
			if enabled_var and not self._user_pinned.enabled then
				for _, other in ipairs(U.block_positions) do
					local v = peek_record(self, other)
					if v and v.old ~= nil and next(v.new or {}) then return end
				end
				self:_unset('enabled', true)
			end
		end,
	}
end

for _, location in ipairs(U.block_positions) do
	specials_by_path['sai.text'][location] = block_field(location)
end

---Undo one override: on top the prior value goes back, below top the special is only notified.
---@param self sai.lib.reconfigurer
---@param field string
---@param drop_parked? boolean also remove the var (else it re-applies on enable)
function M._release(self, field, drop_parked)
	local override = stacks[self.super][field][self]
	if not override then
		-- never applied: only the special may act
		local parked = self._parked[field]
		if parked == nil then return end
		-- mute the OptionSet printers around the write
		local muted = e.ignore_opts
		e.ignore_opts = true
		local special = self._handlers[field]
		if special and special.restore then special.restore(self, { new = parked }, nil, field, true) end
		e.ignore_opts = muted
		if stacks[self.super][field][self] ~= nil then return end -- the restore re-applied the var
		if drop_parked then
			self._user_pinned[field] = nil
		else
			self._parked[field] = parked -- survives for a re-apply
		end
		return
	end

	local muted = e.ignore_opts
	e.ignore_opts = true

	local prior = stacks[self.super][field]:set(self)
	local special = self._handlers[field]
	if prior ~= nil then
		if special and special.restore then
			special.restore(self, override, prior, field, true)
		else
			if self.save_user_changes then override.new = self.super[field] end
			self.super[field] = prior
		end
	elseif override.old ~= nil then -- an upper layer took the restore target
		if special and special.restore then special.restore(self, override, override.old, field, false) end
	elseif special and special.restore then
		special.restore(self, override, nil, field, true)
	end

	e.ignore_opts = muted
	if stacks[self.super][field][self] ~= nil then return end -- the restore re-applied the var
	if drop_parked then
		self._user_pinned[field] = nil
	else
		self._parked[field] = override.new -- survives for a re-apply
	end
end

---Push onto the stack and apply: the special's `apply`, or a plain write.
---@param self sai.lib.reconfigurer
---@param field string
---@param override sai.lib.registry.record
function M:_apply_record(field, override)
	local stack = stacks[self.super][field]
	stack:set(self, override)
	local special = self._handlers[field]
	if special and special.apply then
		special.apply(self, override)
	else
		self.super[field] = override.new
	end
end

---Apply or park an override.
---@param self sai.lib.reconfigurer
---@param field string
---@param value unknown
---@param internal? boolean machinery side-effect, never user-pinned
function M:_set(field, value, internal)
	if not internal and (field == 'enabled' or field == 'status_timeout') then self._user_pinned[field] = true end
	if not (self._enabled and self:_can_apply(field)) then
		self._parked[field] = value -- not applicable yet: park the value
		return
	end

	local muted = e.ignore_opts
	e.ignore_opts = true
	self._parked[field] = nil
	local override = { new = value, old = self.super[field] }
	self:_apply_record(field, override)
	e.ignore_opts = muted
end

---@param self sai.lib.reconfigurer
---@param field string
---@param internal? boolean machinery undoing its own side-effect
function M:_unset(field, internal)
	local applied = stacks[self.super][field][self]
	if applied and applied.old ~= nil and (internal or (self._enabled and self:_can_apply(field))) then
		M._release(self, field, true)
	else
		self._parked[field] = nil -- parked or nothing: drop it
		stacks[self.super][field]:set(self) -- also clear the live record when the gate skipped the drop path
		if not internal then self._user_pinned[field] = nil end
	end
end

---Whether the var can apply now (a special may gate on mode).
---@param self sai.lib.reconfigurer
---@param field string
---@return boolean
function M:_can_apply(field)
	local special = self._handlers[field]
	return not special or not special.can_apply or special.can_apply(self)
end

---@param self {super:sai.lib.backer, _enabled?:boolean}
---@return self
function M:new()
	self._enabled = self._enabled or false
	if self.super._path == 'sai.eventloop' then return evloop.new(self) end

	---@cast self sai.lib.reconfigurer
	for name, method in pairs(M) do
		-- methods ride along; metamethods and constructors stay on M
		if name:sub(1, 2) ~= '__' and name:sub(1, 3) ~= 'new' then self[name] = method end
	end
	self._user_pinned = {}
	self._deferred = {}
	self._parked = {}
	self._handlers = specials_by_path[self.super._path] or {}

	if self.super._path == 'sai' then
		self.eventloop = evloop.new {}
		self.eventloop.subscribe {
			event = { 'ModeChangedPre', 'ModeChanged' },
			callback = function(ev)
				local mode_cfg = rawget(self, ev.mode)
				-- apply the mode's vars on mode change (some only apply in their mode)
				-- FIXME: enabling applies to all modes now
				if mode_cfg and self._enabled then mode_cfg(ev.event == 'ModeChanged') end
			end,
		}
	end

	return setmetatable(self, M)
end

function M:__index(field)
	local subapi = rawget(self.super, field)
	-- a metatable means a sub-api; plain values read the override
	if not getmetatable(subapi) then return peek_record(self, field) end

	rawset(self, field, M.new { super = subapi, _enabled = self._enabled })
	return self[field]
end
function M:__newindex(field, value)
	if value == nil then -- reset the var
		self:_unset(field)
	else
		self:_set(field, value)
	end
end
---@param enable boolean|fun(self:sai.lib.reconfigurer) apply or undo the tree, or run a function on it
---@return boolean? false on no-op
function M:__call(enable)
	if type(enable) == 'function' then return enable(self) end

	if enable == self._enabled then return false end
	self._enabled = enable

	local muted = e.ignore_opts
	e.ignore_opts = true

	if enable then
		apply_parked(self)
	else
		release_all(self)
	end

	e.ignore_opts = muted

	for name, sub_config in pairs(self) do
		-- TODO: sub-configs created after enable (e.g. sai.formats) never get the call
		if name:sub(1, 1) ~= '_' and type(sub_config) == 'table' and name ~= 'super' then sub_config(enable) end
	end
end

function M:__tostring()
	---@type {[string]:unknown}
	local dump = {}
	for field, stack in pairs(stacks[self.super]) do
		local override = stack[self]
		if override then dump[field] = override.new end
	end
	for field, parked in pairs(self._parked) do
		if dump[field] == nil then dump[field] = parked end
	end
	for name, sub_config in pairs(self) do
		if name:sub(1, 1) ~= '_' and type(sub_config) == 'table' and name ~= 'super' then dump[name] = sub_config end
	end
	return U.tbl_to_str(dump)
end

return M
