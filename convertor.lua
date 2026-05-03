-- Streaming, atomic INI-to-Lua converter for the swi API.
-- Outputs Lua assignments and map() calls, closely matching the swi API types and structures.
local M = {}

-- String helpers
local function trim(s) return (s or ''):gsub('^%s+', ''):gsub('%s+$', '') end
local function split(s, sep)
	local t = {}
	for part in s:gmatch('([^' .. sep .. ']+)') do
		t[#t + 1] = trim(part)
	end
	return t
end

local truthy = { yes = 1, ['true'] = 1, on = 1, ['1'] = 1 }
local falsy = { no = 1, ['false'] = 1, off = 1, ['0'] = 1 }
local function parse_bool(val)
	local s = tostring(val or ''):lower()
	if truthy[s] then return 'true' end
	if falsy[s] then return 'false' end
	return nil
end

local function ini_to_argb(s)
	if not s then return nil end
	local hex = s:match '^#(%x+)$'
	if not hex then return end
	if #hex == 6 then return '0xff' .. hex end
	if #hex == 8 then return '0x' .. hex:sub(7) .. hex:sub(1, 6) end
end

local function lua_escape(s)
	s = s:gsub('\\', '\\\\'):gsub("'", "\\'")
	return s
end
local function to_lua_string(s)
	return s:find("'", 0, true) and not s:find(']]', 0, true) and string.format('[[%s]]', s)
		or string.format("'%s'", lua_escape(s))
end

-- Mapping for section aliases
local section_map = {
	general = 'swi',
	list = 'l',
	font = 't',
	info = 't',
	viewer = 'v',
	gallery = 'g',
	slideshow = 's',
}
local opt_translations = {
	['font.color'] = 't.foreground',
	['font.name'] = 't.font',
	['font.size'] = function(x) return 't.size = ' .. (tonumber(x) * 1.25) end,
	['info.show'] = 't.enabled', -- boolean
	['info.info_timeout'] = 't.enabled', -- number
	['general.position'] = function(x)
		if x ~= 'auto' then return '' end
		return '-- window position not available in new format'
	end,
	['general.app_id'] = 'swi.title',
	['general.size'] = function(x)
		if x == 'fullscreen' then return 'swi.toggle_fullscreen()' end
		if x == 'image' then return '-- swi.window_size on `image` by default' end
		return string.format('swi.window_size = { %s }', x)
	end,

	['list.all'] = function()
		return "require('swi.snippets').load_dir_if_single() -- for static setting use swi.imagelist.adjecent"
	end,

	['viewer.antialiasing'] = function(x) return 'swi.antialiasing = ' .. tostring(x ~= 'none') end,
	['gallery.antialiasing'] = '-- swi.antialiasing only for viewer',
	['slideshow.antialiasing'] = '-- swi.antialiasing only for viewer',
	['viewer.window'] = 'v.window_background',
	['viewer.history'] = 'v.history_limit',
	['viewer.preload'] = 'v.preload_limit',
	['viewer.transparency'] = function(x)
		if x:sub(1, 1) == '#' then return string.format('v.image_background = %s', ini_to_argb(x)) end
		local a, b = x:match '(.+),(.+)'
		return string.format('v.image_background = { %s, %s }', ini_to_argb(a), ini_to_argb(b))
	end,
	['slideshow.transparency'] = function(x)
		if x:sub(1, 1) == '#' then return string.format('s.image_background = %s', ini_to_argb(x)) end
		local a, b = x:match '(.+),(.+)'
		return string.format('s.image_background = { %s, %s }', ini_to_argb(a), ini_to_argb(b))
	end,
	['viewer.scale'] = 'v.default_scale',
	['viewer.position'] = 'v.default_position',

	['slideshow.time'] = 's.timeout',

	['gallery.size'] = 'g.thumb_size',
	['gallery.padding'] = 'g.padding_size',
	['gallery.select'] = 'g.selected_color',
	['gallery.background'] = 'g.unselected_color',
	['gallery.border_width'] = 'g.border_size',
	['gallery.window'] = 'g.window_color',
	['gallery.cache'] = 'g.cache_limit',
}
for k, v in pairs(opt_translations) do
	if k:match '^viewer' then
		local name = 'slideshow.' .. k:sub(8)
		if not opt_translations[name] then opt_translations[name] = type(v) == 'function' and v or ('s' .. v:sub(2)) end
	end
end

local enums = {
	['v.default_position'] = {
		top = 'topcenter',
		left = 'leftcenter',
		right = 'rightcenter',
		bottom = 'bottomcenter',
		top_left = 'topleft',
		top_right = 'topright',
		bottom_left = 'bottomleft',
		bottom_right = 'bottomright',
	},
}
enums['s.default_scale'] = enums['v.scale']
enums['s.default_position'] = enums['v.position']

local function format_value(lhs, rhs)
	local out = ini_to_argb(rhs) or tonumber(rhs) or parse_bool(rhs)
	if out ~= nil then return out end
	return to_lua_string((enums[lhs] or {})[rhs] or rhs)
end

local function process_assignment(section, line)
	local k, v = line:match '^(.-)%s*=%s*(.-)%s*$'
	if not k then return '-- unknown config line: ' .. line end
	k = trim(k)
	local alias = section_map[section]
	local key_id = section .. '.' .. k

	local lhs = opt_translations[key_id] or (alias .. '.' .. k)
	if type(lhs) == 'function' then return lhs(v) end
	if lhs:sub(1, 2) == '--' then return string.format('%s = %s', lhs, tostring(v)) end
	return string.format('%s = %s', lhs, format_value(lhs, v))
end

--- Keybinding translation

-- Action mappings outside main loop
local action_map = {
	exit = 'swi.exit(%s)',
	skip_file = 'l.remove(l.get_current().path)',
	info = 't.enabled = not t.enabled',
	antialiasing = function(x)
		if not x then return 'swi.antialiasing = not swi.antialiasing' end
		return 'swi.antialiasing = ' .. tostring(x ~= 'none')
	end,
	fullscreen = 'swi.toggle_fullscreen()',
	zoom = function(x, alias)
		if not x then return "require('swi.snippets').cycle_scale()" end

		local setter = '%s.scale = %s'
		if x:match 'mouse$' then
			x = x:gsub(' ?mouse$', '')
			setter = '--\n  local p = swi.get_mouse_pos()\n  %s.scale_centered(%s, p.x, p.y)'
		end

		x = tostring(x or '')
		return string.format(
			setter,
			alias,
			x:match '^[%+%-]?%d+$'
					and (
						x:find '^[+-]' --
							and alias .. '.get_abs_scale() * ' .. (1 + tonumber(x) / 100)
						or '' .. tonumber(x) / 100
					)
				or format_value('v.scale', x)
		)
	end,
	position = function(x, alias)
		if not x then return "require('swi.snippets').cycle_position()" end
		return string.format("%s.position = '%s'", alias, x)
	end,
	mode = function(x)
		if not x then return 'swi.mode = swi.mode == "gallery" and "viewer" or "gallery"' end
		return 'swi.mode = ' .. to_lua_string(x)
	end,
	mark = "l.marked.set_current('toggle')",
	exec = function(x) return string.format('swi.exec(%s)', to_lua_string(x:gsub("'%%'", '%%f'))) end,
	animation = function(_, alias) return string.format('%s.animation = not %s.animation', alias, alias) end,
	pause = "swi.mode = 'viewer'",
	thumb = function(x)
		return string.format(
			'g.thumb_size = %s',
			x:match '^[%+%-]?%d+$'
					and (
						x:find '^[+-]' --
							and 'g.thumb_size * ' .. (1 + tonumber(x) / 100)
						or x
					)
				or format_value('g.thumb_size', x)
		)
	end,
	help = "require('swi.help').enabled = not swi.help.enabled",
}

local context_action_map = {
	g = setmetatable({}, {
		__index = function(tbl, idx)
			idx = idx:gsub('^step_', '')
			tbl[idx] = string.format('go.%s()', idx)
			return tbl[idx]
		end,
	}),
	v = setmetatable({
		rotate_left = 'rotate(270)',
		rotate_right = 'rotate(90)',
		next_frame = 'next_frame()',
		prev_frame = 'prev_frame()',
		rand_file = 'go.random()',
		flip_vertical = 'flip_vertical()',
		flip_horizontal = 'flip_horizontal()',
		export = 'export(%s)',
	}, {
		__index = function(tbl, idx)
			idx = idx:gsub('_file$', '')
			if idx:match '^step' then
				tbl[idx] = string.format('step.%s(%%s)', idx:gsub('^step_', ''))
			else
				tbl[idx] = string.format('go.%s()', idx)
			end
			return tbl[idx]
		end,
	}),
}
context_action_map.s = context_action_map.v

-- Emit/transform actions
local function translate_action(alias, action, argline)
	if not action then return '--[[missing an action]]' end
	local conversion = action_map[action]
	local prefix = conversion and '' or (alias .. '.')
	conversion = conversion or context_action_map[alias][action]

	if argline and #argline == 0 then argline = nil end
	if type(conversion) == 'function' then return conversion(argline, alias) end

	local arg
	if argline then arg = tonumber(argline) and argline or to_lua_string(argline) end

	return prefix .. string.format(conversion, arg or '')
end

local function process_hook(alias, v, allow_shstr)
	if v:find ';' then
		local ret = { 'function()' }
		for _, act in ipairs(split(v, ';')) do
			local action, argline = act:match '^([^ ]+)%s*(.*)'
			ret[#ret + 1] = '  ' .. translate_action(alias, action, argline)
		end
		ret[#ret + 1] = 'end'
		return table.concat(ret, '\n')
	end

	local action, argline = v:match '^([^ ]+)%s*(.*)'
	local converted = translate_action(alias, action, argline)
	if allow_shstr and converted:find '^swi.exec' then return converted:match '^swi.exec%(?(.+[^)])%)?$' end
	if converted:sub(-2) == '()' then return converted:sub(1, -3) end
	return string.format('function() %s end', converted)
end

local function sigbind(sig, x)
	return string.format(
		[[e.subscribe {
  event = 'Signal',
  match = '%s',
	callback = %s,
}]],
		sig,
		process_hook('v', x)
	)
end
opt_translations['general.sigusr1'] = function(x) return sigbind('USR1', x) end
opt_translations['general.sigusr2'] = function(x) return sigbind('USR2', x) end

local function process_keybind(alias, line)
	local bind, actline = line:match '^(.-)%s*=%s*(.-)%s*$'
	if actline == 'none' then return string.format("%s.unmap('%s')", alias, bind) end
	return string.format("%s.map('%s', %s)", alias, bind, process_hook(alias, actline, true))
end

--- text parsing

local text_map = {
	index = '{list.index}/{list.total}',
	filesize = '{sizehr}',
	imagesize = '{frame.width}x{frame.height}',
	frame = '{frame.index}/{frame.total}',
	status = '~status deprecated~',
}

local function process_text(alias, line)
	local corner, list = line:match '^(.-)%s*=%s*(.-)%s*$'
	corner = enums['v.default_position'][corner]

	local modules = split(list, ',')
	local items = {}
	for i, v in ipairs(modules) do
		if v ~= 'none' then
			if v:sub(1, 1) == '+' then
				v = v:sub(2)
				items[i] = string.format("'%s%s: %s'", v:sub(1, 1):upper(), v:sub(2), text_map[v] or ('{' .. v .. '}'))
			else
				items[i] = string.format("'%s'", text_map[v] or ('{' .. v .. '}'))
			end
		end
	end

	return string.format('%s.text.%s = {%s}', alias, corner, table.concat(items, ', '))
end

function M.convert(path)
	local f, err = io.open(
		path and path:gsub('^~', os.getenv 'HOME')
			or ((os.getenv 'XDG_CONFIG_HOME' or (os.getenv 'HOME' .. '/.config')) .. '/swayimg/config'),
		'r'
	)
	if not f then
		io.stderr:write('Failed to open file: ' .. tostring(err) .. '\n')
		return
	end

	local ret = {
		[[require 'swi.api.globals'
require('swi.snippets').print_option_changes()
t.line_spacing = 0.5
]],
	}

	local section_type, section
	local alias
	for raw_line in f:lines() do
		local line = trim(raw_line)
		if line == '' then
			ret[#ret + 1] = line
		elseif line:match '^[;#]' then
			ret[#ret + 1] = '--' .. line:sub(2):gsub('^(#+)', function(m) return ('-'):rep(#m) end)
		elseif line:match '^%[.-%]' then
			ret[#ret + 1] = '--' .. line
			_, section_type, section = line:match '^%[(([^.]-)%.?)([^.]+)%]$'
			alias = section_map[section]
		elseif not alias then
			ret[#ret + 1] = '-- ' .. line
		elseif section_type == 'keys' then
			ret[#ret + 1] = process_keybind(alias, line)
		elseif section_type == 'info' then
			ret[#ret + 1] = process_text(alias, line)
		else
			ret[#ret + 1] = process_assignment(section, line)
		end
	end
	f:close()

	return table.concat(ret, '\n') .. '\n'
end

function M.load(path)
	local out, err = loadstring(M.convert(path), path or 'config')
	if not out then
		io.stderr:write(err .. '\n')
	else
		out()
	end
end

function M.save(out_path, config_path)
	local out = M.convert(config_path)
	local f = io.open(out_path, 'w')
	if not f then
		io.stderr:write('Inaccessible output path: ' .. out_path .. '\n')
		return
	end
	f:write(out)
	f:close()
end

function M.save_or_print(out_path, config_path)
	if not out_path then
		print(M.convert(config_path))
	else
		M.save(out_path, config_path)
	end
end

if arg and arg[0] and arg[0]:match 'convertor%.lua$' then M.save_or_print(arg[1], arg[2]) end
return M
