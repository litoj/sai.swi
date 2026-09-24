---@module 'sai.lib.remapper'

local U = require 'sai.lib.utils'
local kp = require 'sai.lib.keybind_processor'
local B = require 'sai.lib.bindmods'
local backer = require 'sai.lib.backer'
local reconfigurer = require 'sai.lib.reconfigurer'
local e = require 'sai.api.eventloop'

local binds = require('sai.lib.registry').binds
local var_reg = require('sai.lib.registry').vars

---Keybind override of the current mode, with eventloop hook tracking.
---@class sai.lib.remapper: sai.lib.keybind_processor, sai.lib.backer
---@field enabled? boolean
---@field help_pager? sai.lib.pager|false corner display of the layer's binds (topright), created at construction; `false` opts out: no display and no key help tab
---@field on_unassigned? fun(self:sai.lib.remapper, bind:string, fallback:fun(bind:string))|false
---@field sai? sai.lib.reconfigurer.sai settings overrides, applied while the mode is enabled
---@field persist_mode_change? boolean survive app mode changes
---@field component? boolean machinery: hosted below a mode, no ModePush/ModePop of its own
---@field map_filter? false|fun(bind:string,bindcfg:bindcfg):boolean filter for the binds to map on enable, true to remove
local M = {
	warn_on_duplicates = true, --- for keybind_process
	help_pager = false, --- the mode opted out of the corner display
	component = false, --- machinery: hosted below a mode, no ModePush/ModePop of its own

	-- map filter, true to remove
	---@type false|fun(bind:string,bindcfg:bindcfg):boolean
	map_filter = false,
	persist_mode_change = false,
	on_unassigned = false, --- plain field: direct assignment, no backer

	---@type sai.api.mode_base|false
	_mode_api = false, -- the app mode the layer is bound to
	_enabled = false,
}

---@return sai.lib.remapper
function M:new()
	-- a caller-provided tree is shared: never wrap it twice
	if not self.sai then self.sai = reconfigurer.new { super = sai } end
	self.sai.eventloop.subscribe {
		event = { 'ModeChangedPre', 'ModeChanged' },
		callback = function(ev)
			if not self.persist_mode_change then
				self.enabled = false
			else
				-- the text bracket: blocks restore into the leaving mode, re-apply in the arriving one;
				-- tree-scoped, so a shared tree flips exactly once with its owner
				self.sai.text(ev.event == 'ModeChanged')
				---@diagnostic disable-next-line: undefined-field
				self:_set_active(ev.event == 'ModeChanged')
			end
		end,
	}

	-- the corner display: its own tree (a shared one would release the
	-- layer's records whenever the display toggles alone)
	if self._path and self.help_pager == nil then
		-- lazy require + opt-out: the display is a pager, its own
		-- construction would recurse into this block
		self.help_pager = require('sai.lib.pager').new {
			_path = self._path .. '.help_pager',
			_location = 'topright',
			help_pager = false,
		}
	end

	return backer.new(kp.new(U.new_object(self, M)))
end

local fndbg = debug.getinfo

---Inject the mode instance into single-argument callbacks; the captured
---arguments ride along after it.
---@param b string
---@param cfg bindcfg?
---@param fn string|fun(...)? the action the cfg carries
function M:_rawmap(b, cfg, fn)
	-- one cfg per map() call, shared by all its binds: wrapping keys off
	-- the action, so a single wrap covers every bind mapped with it
	if cfg and not cfg._wrapped then
		---@diagnostic disable-next-line: inject-field -- internal wrap memo
		cfg._wrapped = true
		if type(fn) == 'function' and fndbg(fn, 'u').nparams == 1 then cfg.cb = function(...) fn(self, ...) end end
	end

	if not self._enabled then return end

	-- the registry record and the mode write must share the canonical key
	b = B.canonical(b)
	-- old=false: restore with unmap, not skip
	binds[self._mode_api][b]:set(self, { old = self._mode_api._mappings[b] or false, new = cfg })
	self._mode_api:_setmap(b, cfg)
end

function M:_rawunmap(b)
	if not self._enabled then return end
	b = B.canonical(b)
	local old = binds[self._mode_api][b]:set(self)
	if old ~= nil then self._mode_api:_setmap(b, old) end
end

---Fill the corner display with the mode's own bind tab; the layer owns it.
function M:render_help_pager()
	-- lazy require: key_help loads the pager, which loads this module
	local mode_tab = require('sai.mode.key_help').mode_tab
	if not self.help_pager then return end
	local tab = mode_tab(self)
	self.help_pager.title = tab.title
	self.help_pager.scroll = 1
	self.help_pager.lines = tab.lines
end

---Apply/undo the mode's binds (map_filter, own mappings, the unassigned chain) and the corner display.
---The sai tree lifecycle stays with set_enabled.
function M:_set_active(val)
	if val then
		self._mode_api = sai.modes[1]
		if self.map_filter then
			local fn = self.map_filter
			for b, cfg in pairs(self._mode_api._mappings) do
				---@diagnostic disable-next-line: need-check-nil
				if fn(b, cfg) then M._rawmap(self, b) end
			end
		end
		for b, cfg in pairs(self._mappings) do
			self:_rawmap(b, cfg, cfg.cb)
		end

		if self.on_unassigned then
			local api = self._mode_api
			-- resolve below live, so a popped layer is never called
			---@diagnostic disable-next-line: invisible, need-check-nil -- the mode's own raw field
			local override = { old = api._on_unassigned }
			override.new = function(key) self:on_unassigned(key, var_reg[api].on_unassigned[self].old) end
			var_reg[api].on_unassigned:set(self, override)
			api.on_unassigned = override.new
		end

		-- the display rides its own layer; up first, so the content
		-- generation sees its scroll binds under the mode's sub-header
		if self.help_pager then
			self.help_pager.enabled = true
			self:render_help_pager()
		end
	else
		if self.help_pager then self.help_pager.enabled = false end

		local oou = var_reg[self._mode_api].on_unassigned:set(self, nil)
		if oou then self._mode_api.on_unassigned = oou end

		for b, stack in pairs(binds[self._mode_api]) do
			local old = stack:set(self)
			if old ~= nil then self._mode_api:_setmap(b, old) end
		end
	end
end

---@protected
function M:set_enabled(val)
	if val == self._enabled then return false end
	self._enabled = val
	-- a component is machinery: its host owns the layer semantics, an
	-- event mid-host-teardown would clobber the help display hooks
	local layer = not self.component
	if val then
		table.insert(sai.modes, self)
		self.sai(val)
		self:_set_active(true)
		if layer then e.trigger { event = 'User', match = 'ModePush', data = self } end
	else
		self:_set_active(false)
		self.sai(val)
		for k, v in ipairs(sai.modes) do
			if v == self then
				table.remove(sai.modes, k)
				break
			end
		end
		if layer then e.trigger { event = 'User', match = 'ModePop', data = self } end
	end
	return true
end

return M
