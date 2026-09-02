---@module 'sai.bridge.shell'

---@class sai.bridge.shell
local M = {}

---@param cmd string
---@return string
function M.parse_shell_cmd(cmd)
	cmd = cmd:gsub('([^%%])%%([^%%])', function(a, type)
		if type == 'm' or type == 's' then
			local marked = sai.imagelist.marked.get()

			if #marked > 0 then
				return ("%s'%s'"):format(a, table.concat(marked, "' '"))
			elseif type == 'm' then
				error 'No marked files'
			else -- type == 's'
				type = 'f'
			end
		end

		local path = sai.imagelist.get_current().path
		if type == 'f' then
			return ("%s'%s'"):format(a, path)
		else
			return ('%s%s%s'):format(a, path, type)
		end
	end):gsub('%%%%', '%%')
	return cmd
end

---@see sai.exec
function M.exec(cmd, async)
	cmd = M.parse_shell_cmd(cmd)

	if async then return cmd, select(1, os.execute(('{ %s; } >/dev/null </dev/null &'):format(cmd))) end

	local h = io.popen 'mktemp' or error 'Failed to execute mktemp'
	local tf = h:read 'l'
	h:close()

	local err
	h, err = io.popen(('{ %s; } 2>%s\necho $?'):format(cmd, tf), 'r')
	if not h then error('Error executing command: ' .. (err or '')) end
	local out = h:read 'a'
	h:close()

	h = io.open(tf, 'r')
	if not h then
		err = ''
	else
		err = h:read 'a'
		h:close()
	end
	os.remove(tf)

	local code = out:match '(%d+)\n$'
	out = out:sub(1, -#code - 2)

	sai.eventloop.trigger { event = 'User', match = 'ShellCmdPost', data = { cmd = cmd, stdout = out, stderr = err } }
	return out, code, err
end

---Get the current Wayland clipboard content via wl-paste.
---@return string? text clipboard content, or nil on failure
function M.clipboard_get()
	local p = io.popen('wl-paste -n', 'r')
	if not p then return end
	local text = p:read '*a'
	p:close()
	return text
end

---Set the Wayland clipboard content via wl-copy.
---@param text string text to copy to clipboard
---@return boolean ok true on success
function M.clipboard_set(text)
	local p = io.popen('wl-copy', 'w')
	if not p then return false end
	p:write(text)
	sai.notify 'Copied text to clipboard'
	return p:close()
end

---The transform doubles as a content check: returning false rejects and
---removes the download (e.g. the remote file changed unexpectedly).
---@param url string remote location of the file
---@param path string destination path relative to sai as pwd
---@param transform fun(content:string):string|false? content filter
function M.download(url, path, transform)
	local h = io.popen(
		('{ curl -fsSL -o "%s" "%s" || wget -q -O "%s" "%s"; } 2>&1 >/dev/null'):format(path, url, path, url)
	) or error 'Error in download command'
	local out = h:read 'a'
	h:close()

	local f = io.open(path, 'r')
	if out ~= '' or not f or f:seek 'end' == 0 then
		os.remove(path)
		error('Failed to download ' .. url .. ': ' .. out)
	end
	f:close()

	if transform then
		f = io.open(path, 'r') or error('Could not read downloaded file: ' .. path)
		local content = f:read 'a'
		f:close()
		content = transform(content)
		if not content then
			os.remove(path)
			error('Unexpected contents at ' .. url)
		end
		f = io.open(path, 'w') or error('Could not write file: ' .. path)
		f:write(content)
		f:close()
	end
end

---@param code string
---@return (fun(self?:any):any)?
function M.make_runnable(code)
	if not code:find 'return[^\n]*$' and not code:find '[^=]=[^=][^\n]*$' then
		code = code:gsub('([^\n]+)$', 'return %1', 1)
	end

	local cb, err = loadstring(code)
	---@diagnostic disable-next-line: need-check-nil
	if not cb or err then return sai.notify(err:gsub('^.-:%d:', 'Syntax error:')) end
	return function(self)
		-- if self == false then return end
		_G.self = self
		err = cb()
		_G.self = nil
		return err
	end
end

---Find the source file of a compiled module: either an in-repo `.cpp`
---or a downloaded/generated `.c` sibling.
---@param so_path string path relative to sai as pwd
---@return string? src
---@return string? compiler
local function source_of(so_path)
	for _, src_type in ipairs { { 'cpp', 'g++' }, { 'c', 'gcc' } } do
		local src = so_path:gsub('so$', src_type[1])
		if os.rename(src, src) then return src, src_type[2] end
	end
end

---@param so_path string path relative to sai as pwd
function M.compile_so(so_path)
	local src, cc = source_of(so_path)
	if not src then error('No source file for module: ' .. so_path) end
	-- stock Lua C sources expect the luajit include path and the 5.2+ module
	-- export macro that LuaJIT headers do not define
	local cflags = cc == 'gcc' and '-I/usr/include/luajit-2.1 -DLUAMOD_API=' or ''
	local h = io.popen(string.format( --
		'%s -O2 -shared -fPIC %s -o "%s" "%s" 2>&1 >/dev/null',
		cc,
		cflags,
		so_path,
		src
	)) or error 'Error in compilation command'
	local out = h:read 'a'
	h:close()
	if out ~= '' then error('Failed to compile module: ' .. out) end
end

function M.load_so(so_path)
	if not source_of(so_path) then error('No source file for module: ' .. so_path) end
	if not os.rename(so_path, so_path) then M.compile_so(so_path) end

	local loader = package.loadlib(so_path, 'luaopen_' .. so_path:match '([^/]+)%.so$')
	if not loader then error('Unable to load library: ' .. so_path) end
	return loader()
end

return M
