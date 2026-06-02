---@module 'swi.snippets'
local M = {}

local e = require 'swi.api.eventloop'

function M.update()
	swi.exec 'cd ~/.config/swayimg/swi && git pull'
	-- recompile if sources have updated
	local path = debug.getinfo(1, 'S').source:match '(/.*/)' .. 'exiv2_to_lua.so'
	if os.execute(string.format('[ %s -nt %s ]', path:gsub('.so$', '.cpp'), path)) ~= 1 then
		local old = package.loaded['swi.lib.exiv2']
		if not old then return end
		for k, v in pairs(require('swi.lib.utils').compile_and_load(path)) do -- update old instance
			old[k] = v
		end
	end
end

function M.load_dir_if_single()
	local function check_n_load()
		local l = swi.imagelist
		if l.size() == 1 then l.add(l.get_current().path:match '.+/') end
	end

	if swi.initialized then
		check_n_load()
	else
		e.subscribe { event = 'SwiEnter', once = true, callback = check_n_load }
	end
end

function M.print_shell_output()
	e.subscribe {
		event = 'ShellCmdPost',
		callback = function(ev)
			if #ev.data then swi.text.set_status(ev.data) end
		end,
	}
end

---@param enable boolean? true by default
function M.print_option_changes(enable)
	if enable == false then
		e.unsubscribe { event = 'OptionSet', group = 'print_var_change' }
		return
	end

	local function register_printer()
		-- register after base config has been loaded
		e.subscribe { -- Print messages on option update
			event = 'OptionSet',
			pattern = { '!swi.imagelist.size', '!swi.text.status', '^' }, -- all main opts - not the subsubtables (text etc.)
			group = 'print_var_change',
			callback = function(ev)
				local v = ev.data
				if type(v) == 'number' then
					if math.floor(v * 100) == v * 100 then
						v = '' .. v
					else
						v = ('%.2f'):format(v)
					end
				elseif type(v) == 'table' then
					return -- ignore window size and position changes
				end

				local name = ev.match:match '([^.]+%.[^.]+)$'
				swi.text.set_status(
					('%s%s: %s'):format(
						name:sub(1, 1):upper(),
						name:sub(2):gsub('[_.](.)', function(x) return ' ' .. x:upper() end),
						v
					)
				)
			end,
		}
	end

	if swi.initialized then
		register_printer()
	else
		e.subscribe { event = 'SwiEnter', once = true, callback = register_printer }
	end
end

function M.resize_image_with_window()
	e.subscribe {
		event = 'WinResized',
		mode = { 'viewer', 'slideshow' },
		callback = function(ev)
			local v = swi[ev.mode]
			if type(v.scale) == 'string' then swayimg[ev.mode].set_fix_scale(v.scale) end
		end,
	}
end

function M.cycle_values(values, current)
	for i, mode in ipairs(values) do
		if mode == current then return values[i % #values + 1] end
	end
end

function M.cycle_scale()
	local api = swi[swi.mode] ---@type swi.api.viewer
	local modes = {
		'optimal',
		'width',
		'height',
		'fit',
		'fill',
		'real',
		'keep',
	}
	for k, _ in pairs(api.custom_scale_handlers) do
		if type(k) == 'string' then modes[#modes + 1] = k end
	end

	local current = api.scale
	if type(current) ~= 'string' then current = 'keep' end
	api.scale = M.cycle_values(modes, current)
end

function M.cycle_position()
	local api = swi[swi.mode] ---@type swi.viewer
	local modes = {
		'center',
		'topcenter',
		'leftcenter',
		'rightcenter',
		'bottomcenter',
		'topleft',
		'topright',
		'bottomleft',
		'bottomright',
	}

	local current = type(api.position) == 'string' and api.position or 'center'
	api.position = M.cycle_values(modes, current)
end

function M.two_pane_mode(key)
	local super = require 'swi.mode.custom'
	local tp = { ---@class tp: swi.mode.custom
		_mode = 'gallery',
		_path = 'two_pane',
		save_user_changes = true,
	}
	function tp:set_enabled(val)
		if self._enabled == val then
			if val then swi.mode = 'gallery' end
			return
		end
		if val and not self.swi.gallery.thumb_size then
			self.swi.gallery.thumb_size = swi.get_window_size().width / 2
		end
		return super.set_enabled(self, val)
	end

	super.new(tp)

	tp.swi.mode = 'gallery'
	tp.swi.gallery(function(g) ---@param g swi.gallery
		g.padding_size = 0
		g.cache_limit = 0
		g.preload = false
		g.border_size = 5
		g.selected_scale = 1
		g.window_color = 0xff808080
		g.hover = true

		tp.swi.eventloop.subscribe {
			event = 'WinResized',
			callback = function(ev) g.thumb_size = ev.data.width / 2 end,
		}
	end)

	key = key or 't'
	v.map(key, function() tp.enabled = true end, 'Enable Two-pane mode')
	tp.map(key, function() tp.enabled = false end, 'Disable Two-pane mode')

	return tp
end

---@param key? string key to enter the mode (default: ':')
---@param mode? appmode_t in which mode to register (default: all)
function M.cmd_mode(key, mode)
	local cm = { ---@class cmd_mode: swi.mode.input
		super = require 'swi.mode.input',
		_path = 'swi.mode.cmd',
		_prompt = 'Code: ',
	}
	function cm:on_confirm(out)
		if not out then
			self.text = ''
			return
		end

		self.enabled = false -- disable first to avoid any messages overriding code work
		local cb, err = loadstring(out)
		if not cb or err then return swi.text.set_status(err) end
		cb()
	end

	cm.super.new(cm)

	cm.map('Shift+Return', '\n')
	require('swi.binds').map(mode or 'a', key or ':', function() cm.enabled = true end)
	-- TODO: add autocompletion and history
	return cm
end

return M
