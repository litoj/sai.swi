---@diagnostic disable: redefined-local
---@module 'sai.api.eventloop'

local U = require 'sai.lib.utils'
local tabled = U.tabled

---@private
---@class hook_cfg: hook.base
---@field pattern {[string]:boolean}|string[]
---@field mode {[appmode_t]:integer}|appmode_t[]

---@type sai.eventloop
local M = {
	---@type {[event_name_t]:{[string]:hook_cfg[]}}
	_hooks = {}, ---@private
	debug_trigger = false,
	debug_subscribe = false,
} -- TODO: could improve deleting perf by having a {[hook_id]:counter}

local modes = { 'viewer', 'gallery', 'slideshow' }

local function print_debug(name, t)
	if t.event == 'Subscribed' and name == 'trigger' then return end
	local tbl = { event = t.event, mode = t.mode, match = t.match or t.pattern, data = t.data }
	print(U.pretty_trace(name, debug.traceback()), name, U.tbl_to_str(tbl, ''))
end

local function mk_modes(mode)
	if not mode then return modes end
	mode = U.tabled(mode)
	for i, v in ipairs(mode) do
		mode[v] = i
	end
	return mode
end
mk_modes(modes)

---@param tbl string|string[]|{[string]:boolean}
---@return string[]|{[string]:boolean}
local function mk_ptn_tbl(tbl)
	local t = tabled(tbl) ---@type string[]|{[string]:boolean}
	local i = #t
	while i > 0 do
		local p = t[i]
		if p and not p:match '[*+?%%^$%[%]()]' then
			--- make direct matches into indexes
			if p:sub(1, 1) == '!' then
				t[p:sub(2)] = false
			else
				t[p] = true
			end
			table.remove(t, i)
		end
		i = i - 1
	end
	return t
end

---@param cfg sai.eventloop.hook
---@return hook_cfg
local function mk_hook(cfg)
	if cfg.match then
		if cfg.pattern then
			for k, v in pairs(cfg.match) do
				cfg.pattern[k] = v
			end
		else
			cfg.pattern = cfg.match
		end
		---@diagnostic disable-next-line: inject-field
		cfg.match = nil
	end
	-- using '^' and not '' to be valid against all ev.match values (not just '')
	cfg.pattern = mk_ptn_tbl(cfg.pattern or { '^' }) ---@cast cfg hook_cfg
	cfg.mode = mk_modes(cfg.mode)
	return cfg
end

---@param hook sai.eventloop.hook
---@return hook_cfg
function M.subscribe(hook)
	if not hook.callback then error('missing callback in: ' .. tostring(hook)) end
	if M.debug_subscribe then print_debug('subscribe', hook) end
	hook = mk_hook(hook)
	for _, ev in ipairs(tabled(hook.event or error('missing event in: ' .. tostring(hook)))) do
		local ev_hooks = M._hooks[ev]
		if not ev_hooks then
			ev_hooks = {}
			M._hooks[ev] = ev_hooks
		end

		for k, v in pairs(hook.pattern) do -- register by match
			if v then
				k = type(k) == 'string' and k or '*' -- determine match group ('*' for luapat)
				local hooks = ev_hooks[k]
				if not hooks then
					hooks = {}
					ev_hooks[k] = hooks
				end
				hooks[#hooks + 1] = hook
			end
		end

		M.trigger { event = 'Subscribed', mode = hook.mode, match = ev, data = hook }
	end

	return hook
end

---Determines which hooks match the given event pattern/match.
---@param ev sai.eventloop.filter.opts
---@param ptn_map {[string]:hook_cfg[]}
---@return fun():(hook:hook_cfg?,ptn:string,i:integer)
local function matcher(ev, ptn_map)
	return coroutine.wrap(function()
		if ev.match then
			local match = ev.match ---@cast match string
			local hooks = ptn_map[match]
			if hooks then
				for i, h in ipairs(hooks) do
					coroutine.yield(h, match, i)
				end
			end

			hooks = ptn_map['*']
			if hooks then
				for i, h in ipairs(hooks) do
					if h.pattern[match] == nil then -- `true` was already processed, `false` is to skip it
						-- TODO: could also support negation here, but it'd be really slow
						for _, ptn in ipairs(h.pattern) do
							if match:find(ptn) then
								coroutine.yield(h, '*', i)
								break
							end
						end
					end
				end
			end
			return
		end

		local ptns = mk_ptn_tbl(ev.pattern or '^') -- defaults to match everything
		for match, hooks in pairs(ptn_map) do -- test all fixed-text matches
			if match ~= '*' then
				local ok = ptns[match]
				if ok == nil then -- find a match
					for _, ptn in ipairs(ptns) do -- test against all ev patterns
						if match:find(ptn) then
							ok = true
							break
						end
					end
				end

				if ok then
					for i, h in ipairs(hooks) do
						coroutine.yield(h, match, i)
					end
				end
			end
		end

		for i, h in ipairs(ptn_map['*'] or {}) do
			for _, p in ipairs(h.pattern) do
				for _, v in ipairs(ptns) do -- test against all ev patterns
					if p:find(v) then
						coroutine.yield(h, '*', i)
						p = nil ---@diagnostic disable-line: cast-local-type
						break
					end
				end
				if p == nil then break end
			end
		end
	end)
end

---@alias sai.eventloop.applicator fun(h:hook_cfg,ev:event_name_t, pnt:string,i:integer)

---@private
---@param f sai.eventloop.filter.opts
---@param on_match sai.eventloop.applicator
---@diagnostic disable-next-line: inject-field
function M.apply_filtered(f, on_match)
	---@type (fun(h:hook_cfg):boolean?)[]
	local checks = {}
	if f.id then checks[#checks + 1] = function(h) return f.id == h end end
	if f.group then checks[#checks + 1] = function(h) return f.group == h.group end end
	if f.mode and #f.mode ~= 3 then -- if there are only some modes
		local modes = tabled(f.mode)
		checks[#checks + 1] = function(h)
			if not h.mode then return true end
			for _, m in ipairs(modes) do
				if h.mode[m] then return true end
			end
		end
	end

	for _, ev in pairs(tabled(f.event or U.rev_idx(M._hooks))) do
		local ev_hooks = M._hooks[ev]
		if ev_hooks then
			for hook, ptn, i in matcher(f, ev_hooks) do
				local ok = true
				for _, check in ipairs(checks) do
					if not check(hook) then
						ok = false
						break
					end
				end
				if ok then on_match(hook, ev, ptn, i) end
			end
		end
	end
end

function M.unsubscribe(f)
	M.apply_filtered(f, function(_, ev, ptn, i)
		local ev_hooks = M._hooks[ev]
		local ptn_hooks = ev_hooks[ptn]

		table.remove(ptn_hooks, i)
		if not next(ptn_hooks) then
			ev_hooks[ptn] = nil
			if not next(ev_hooks) then M._hooks[ev] = nil end
		end
	end)
end

function M.find_all(f)
	local t = {}
	M.apply_filtered(f or {}, function(h) t[h] = h end)
	return t
end

function M.trigger(ev)
	---@cast ev sai.eventloop.filter.opts
	ev.mode = ev.mode or swayimg.mode
	if not ev.match and not ev.pattern then ev.match = '' end
	if M.debug_trigger then print_debug('trigger', ev) end

	-- first collect them to ensure they cannot cause a self-removal and mangle indexes (indirectly)
	-- i.e. if a hook disables a custom mode that unsubs that hook then the next hook would be skipped
	local found = {}
	M.apply_filtered(ev, function(hook) found[#found + 1] = hook end)

	for _, hook in ipairs(found) do
		local ok, ret = xpcall(hook.callback, debug.traceback, ev)
		---@diagnostic disable-next-line: param-type-mismatch
		if not ok then sai.log(ret) end

		if hook.once or (ok and ret) then
			M.unsubscribe { id = hook } -- unsub from all places, not just where it matched
		end
	end
end

function M.takeover_subscribe(cfg)
	---@diagnostic disable-next-line: param-type-mismatch
	local old = M.find_all(cfg)
	if not next(old) then
		M.subscribe(cfg)
		return
	end

	---@diagnostic disable-next-line: param-type-mismatch
	M.unsubscribe(cfg)
	local cb = cfg.callback
	cfg = U.soft_copy(cfg)
	cfg.callback = function(ev)
		local ret = cb(ev)
		if cfg.once or ret then
			for _, h in pairs(old) do
				M.subscribe(h)
			end
		end
		return ret
	end
	M.subscribe(cfg)
end

return M
