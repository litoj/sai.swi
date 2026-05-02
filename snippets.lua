---@module 'swi.snippets'
local M = {}

function M.load_dir_if_single()
	local function check_n_load()
		local l = swi.imagelist
		if l.size() == 1 then l.add(l.get_current().path:match '.+/') end
		return true
	end

	if swi.initialized then
		check_n_load()
	else
		swi.eventloop.subscribe { event = 'SwiEnter', callback = check_n_load }
	end
end

---@param enable boolean? true by default
function M.print_option_changes(enable)
	if enable == false then
		swi.eventloop.unsubscribe { event = 'OptionSet', group = 'print_var_change' }
		return
	end

	local function register_printer()
		-- register after base config has been loaded
		swi.eventloop.subscribe { -- Print messages on option update
			event = 'OptionSet',
			pattern = { '!swi.imagelist.size', '^[^.]+%.?[^.]*%.[^.]*$' }, -- all main opts - not the subsubtables (text etc.)
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

		return true
	end

	if swi.initialized then
		register_printer()
	else
		swi.eventloop.subscribe { event = 'SwiEnter', callback = register_printer }
	end
end

function M.resize_image_with_window()
	swi.eventloop.subscribe {
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
	local api = swi[swi.mode] ---@type swi.viewer
	local modes = {
		'optimal',
		'width',
		'height',
		'fit',
		'fill',
		'real',
		'keep',
		'keep_by_width',
		'keep_by_height',
		'keep_by_size',
	}

	local current = type(api.scale) == 'string' and api.scale or 'keep'
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

function M.print_shell_output()
	swi.eventloop.subscribe {
		event = 'ShellCmdPost',
		callback = function(ev) swi.text.set_status(ev.data) end,
	}
end

function M.two_pane_mode()
	local super = require 'swi.lib.mode_override'
	local tp = { ---@class tp: swi.lib.mode_override
		_mode = 'gallery',
		_path = 'two-paned',
	}
	function tp:set_enabled(val)
		if self._enabled == val then return end
		if val then self.swi.gallery.thumb_size = swi.get_window_size().width / 2 end
		return super.set_enabled(self, val)
	end

	super.new(tp)

	swi.eventloop.subscribe {
		event = 'WinResized',
		callback = function(e) tp.swi.gallery.thumb_size = e.data.width / 2 end,
	}
	tp.swi.mode = 'gallery'
	local g = tp.swi.gallery
	g.padding_size = 0
	g.cache_limit = 0
	g.preload = false
	g.border_size = 5
	g.selected_scale = 1
	g.window_color = 0xff808080

	v.map('t', function() tp.enabled = true end, 'Enable Two-pane mode')
	tp.map('t', function() tp.enabled = false end, 'Disable Two-pane mode')

	return tp
end

return M
