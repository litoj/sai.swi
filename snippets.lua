---@module 'sai.snippets'
local M = {}

local e = require 'sai.api.eventloop'
local S = require 'sai.bridge.shell'
local remapper = require 'sai.lib.remapper'
local editor = require 'sai.mode.editor'

function M.update()
	local bridge_dir = debug.getinfo(1, 'S').source:match '/.+/sai/' .. 'bridge/'
	sai.exec(('cd %s && git pull'):format(bridge_dir))

	local p = io.popen('ls -1 ' .. bridge_dir .. '*.so') or error('Could not list cpp modules in: ' .. bridge_dir)
	for so_path in p:lines() do
		if os.execute(string.format('[ %s -nt %s ]', so_path:gsub('.so$', '.cpp'), so_path)) ~= 1 then
			S.compile_so(so_path)
			local old = package.loaded['sai.bridge.' .. so_path:match '([^/]+)%.so$']
			for k, v in pairs(old and S.load_so(so_path) or {}) do
				old[k] = v
			end
		end
	end
	p:close()
end

function M.load_dir_if_single()
	local function check_n_load()
		local l = sai.imagelist
		if l.size ~= 1 then return end
		local dir = l.get_current().path:match '.+/'

		-- find follows symlinks (-L): symlinked files are added, symlinked dirs are not
		local p = io.popen(("find -L '%s' -maxdepth 1 -type f"):format(dir:gsub("'", [['\'']])))
			or error('Could not list files in: ' .. dir)
		local files = {}
		for line in p:lines() do
			files[#files + 1] = line
		end
		p:close()
		l.add(files)
	end

	if sai.initialized then
		check_n_load()
	else
		e.subscribe { event = 'SwiEnter', once = true, callback = check_n_load }
	end
end

---@param timeout? integer how many seconds to display the output for, negative for #out/-timeout
function M.print_shell_output(timeout)
	timeout = timeout or -10
	e.subscribe {
		event = 'User',
		match = 'ShellCmdPost',
		callback = function(ev)
			if #ev.data.stderr > 0 then
				sai.notify(
					('===ERROR STREAM===\n%s\n\n===STDOUT===\n%s'):format(ev.data.stderr, ev.data.stdout),
					timeout < 0 and math.ceil((2 * #ev.data.stderr + #ev.data.stdout) / -timeout) or 2 * timeout
				)
			elseif #ev.data.stdout > 0 then
				sai.notify(ev.data.stdout, timeout < 0 and math.ceil(#ev.data.stdout / -timeout) or timeout)
			end
		end,
	}
end

---@param timeout integer|false? how long it should show the message for (s)
function M.print_option_changes(timeout)
	if timeout == false then
		e.unsubscribe { event = 'OptionSet', group = 'print_var_change' }
		return
	end

	local function register_printer()
		-- register after base config has been loaded
		e.subscribe {
			event = 'OptionSet',
			pattern = { '!sai.imagelist.size', '!sai.text.status', '^' },
			group = 'print_var_change',
			callback = function(ev)
				if e.ignore_opts then return end
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
				sai.notify(
					('%s%s: %s'):format(
						name:sub(1, 1):upper(),
						name:sub(2):gsub('[_.](.)', function(x) return ' ' .. x:upper() end),
						v
					),
					timeout
				)
			end,
		}
	end

	if sai.initialized then
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
			---@diagnostic disable-next-line: assign-type-mismatch
			local v = sai[ev.mode] ---@type sai.api.viewer
			if type(v.scale) == 'string' then v.super.set_fix_scale(v.scale) end
		end,
	}
end

---Auto-play videos in an external player (mpv by default), killing it on image change.
---@param cmd? string string to run with % or %f as the template for the video file
function M.auto_open_video(cmd)
	cmd = cmd or 'mpv --no-terminal %f'
	sai.formats.video = { size = 100, columns = 1, rows = 1 }
	local disable = function() end
	e.subscribe {
		event = 'ImgChanged',
		match = { 'viewer', 'slideshow' },
		callback = function(ev)
			disable()
			if ev.data.format:find('Video', 1, true) then
				sai.exec(cmd, true)
				disable = function()
					os.execute(("pkill -f '%s'"):format(cmd:gsub('%%[f]?', ev.data.path)))
					disable = function() end
				end
			end
		end,
	}
	e.subscribe { event = 'ModeChanged', match = { 'v:g', 's:g' }, callback = function() disable() end }
	e.subscribe {
		event = 'SwiLeavePre',
		mode = { 'viewer', 'slideshow' },
		callback = function()
			disable()
			return true
		end,
	}
end

function M.cycle_values(values, current)
	for i, mode in ipairs(values) do
		if mode == current then return values[i % #values + 1] end
	end
end

function M.cycle_scale()
	local api = sai.modes[1] ---@cast api sai.api.viewer
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
	local api = sai.modes[1] ---@cast api sai.api.viewer
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

---@param key string?
---@return sai.lib.remapper
function M.two_pane_mode(key)
	local super = remapper
	---@class tp: sai.lib.remapper
	local tp = { _path = 'snippets.two_pane_mode' }
	function tp:set_enabled(val)
		if self._enabled == val then return end
		if val and not self.sai.gallery.thumb_size then
			self.sai.gallery.thumb_size = sai.get_window_size().width / 2
		end
		return super.set_enabled(self, val)
	end

	super.new(tp)

	tp.sai.save_user_changes = true
	tp.sai.mode = 'gallery'
	tp.sai.gallery(function(g) ---@param g sai.gallery
		g.padding_size = 0
		g.cache_size = 0
		g.preload = false
		g.border_size = 5
		g.selected_scale = 1
		g.window_color = 0xff808080
		g.hover = true

		tp.sai.eventloop.subscribe {
			event = 'WinResized',
			callback = function(ev) g.thumb_size = ev.data.width / 2 end,
		}
	end)

	key = key or 't'
	v.map(key, function() tp.enabled = true end, 'Enable Two-pane mode')
	tp.map(key, function() tp.enabled = false end, 'Disable Two-pane mode')

	return tp
end

---@return sai.mode.editor lua prompt with its own history
function M.lua_mode()
	---@param out string[]|false
	---@return boolean?|false verdict
	---@return string? msg message the editor notifies after the mode settles
	local on_confirm = function(_, out)
		if not out then return end
		local text = table.concat(out, '\n')
		if text == '' then return end

		-- the editor owns the lifecycle and emits the message after the
		-- mode settles; this only runs and decides
		local cb, syntax = S.make_runnable(text)
		if not cb then return false, syntax end

		local ran, res = pcall(cb)
		if not ran then return false, 'Runtime error: ' .. res:gsub('^.-:%d:%s*', '') end
		return true, res
	end
	---@diagnostic disable-next-line: missing-fields
	return editor.new {
		_path = 'snippets.lua_mode',
		_prompt = 'Lua',
		-- TODO: add autocompletion, likely just for paths and potentially variables
		on_confirm = on_confirm,
	}
end

---@return sai.mode.editor shell prompt with its own history
function M.shell_mode()
	---@param out string[]|false
	---@return boolean?|false verdict
	---@return string? msg message the editor notifies after the mode settles
	local on_confirm = function(_, out)
		if not out then return end
		local text = table.concat(out, '\n')
		if text == '' then return end

		-- the editor owns the lifecycle and emits the message; a throw
		-- (bad % expansion, no shell to run in) counts as a failed run
		local ok, res, code, err = pcall(sai.exec, text)
		if not ok then return false, res end
		if tonumber(code or '') ~= 0 then
			return false, ('Shell exited %s: %s'):format(tostring(code), err ~= '' and err or res)
		end
		return true, res
	end
	---@diagnostic disable-next-line: missing-fields
	return editor.new {
		_path = 'snippets.shell_mode',
		_prompt = 'Shell',
		on_confirm = on_confirm,
	}
end

return M
