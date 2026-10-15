---@module 'sai.bridge.shell'

---@class sai.bridge.shell
local M = {}

---Single-quote a string for the shell: wrapped, ticks escaped.
---@param s string
---@return string
function M.quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

---@param cmd string
---@return string
function M.parse_shell_cmd(cmd)
	local function expand(lead, ph)
		if ph == 'm' or ph == 's' then
			local marked = sai.imagelist.marked.get()

			if #marked > 0 and (ph ~= 's' or sai.mode == 'gallery') then
				local quoted = {}
				for i, p in ipairs(marked) do
					quoted[i] = M.quote(p)
				end
				return lead .. table.concat(quoted, ' ')
			elseif ph == 'm' then
				error 'No marked files'
			else -- ph == 's'
				ph = 'f'
			end
		end

		local path = sai.imagelist.get_current().path
		if ph == 'f' then
			return lead .. M.quote(path)
		else
			return ('%s%s%s'):format(lead, path, ph)
		end
	end
	-- leading space: the pattern needs a char before `%`, drop it after
	cmd = (' ' .. cmd):gsub('([^%%])%%([^%%])', expand):sub(2):gsub('%%%%', '%%')
	return cmd
end

---@see sai.exec
function M.exec(cmd, async)
	cmd = M.parse_shell_cmd(cmd)

	if async then return cmd, select(1, os.execute(('{ %s; } >/dev/null </dev/null &'):format(cmd))) end

	local handle = io.popen 'mktemp' or error 'Failed to execute mktemp'
	local temp_file = handle:read 'l'
	handle:close()

	local err
	handle, err = io.popen(('{\n%s\n} 2>%s\necho $?'):format(cmd, temp_file), 'r')
	if not handle then error('Error executing command: ' .. (err or '')) end
	local out = handle:read 'a'
	handle:close()

	handle = io.open(temp_file, 'r')
	if not handle then
		err = ''
	else
		err = handle:read 'a'
		handle:close()
	end
	os.remove(temp_file)

	local code = out:match '(%d+)\n$'
	out = out:sub(1, -#code - 3)

	sai.eventloop.trigger { event = 'User', match = 'ShellCmdPost', data = { cmd = cmd, stdout = out, stderr = err } }
	return out, code, err
end

---@return string?
function M.clipboard_get()
	local pipe = io.popen('wl-paste -n', 'r')
	if not pipe then return end
	local text = pipe:read '*a'
	pipe:close()
	return text
end

---@param text string
---@return boolean ok
function M.clipboard_set(text)
	local pipe = io.popen('wl-copy', 'w')
	if not pipe then return false end
	pipe:write(text)
	sai.notify 'Copied text to clipboard'
	return pipe:close()
end

---@param url string
---@param path string destination path relative to sai as pwd
---@param transform fun(content:string):string|false? `false` rejects and removes the download
function M.download(url, path, transform)
	local h = io.popen(
		('{ curl -fsSL -o %s %s || wget -q -O %s %s; } 2>&1 >/dev/null'):format(
			M.quote(path),
			M.quote(url),
			M.quote(path),
			M.quote(url)
		)
	) or error 'Error in download command'
	local out = h:read 'a'
	h:close()

	local handle = io.open(path, 'r')
	if out ~= '' or not handle or handle:seek 'end' == 0 then
		os.remove(path)
		error('Failed to download ' .. url .. ': ' .. out)
	end
	handle:close()

	if transform then
		handle = io.open(path, 'r') or error('Could not read downloaded file: ' .. path)
		local content = handle:read 'a'
		handle:close()
		content = transform(content)
		if not content then
			os.remove(path)
			error('Unexpected contents at ' .. url)
		end
		handle = io.open(path, 'w') or error('Could not write file: ' .. path)
		handle:write(content)
		handle:close()
	end
end

---Wrap `code` in a function declaring `params` (a plain chunk without
---them): the runnable takes their values in order, the code sees them as locals.
---@param code string
---@param params? string[] parameter names the code declares
---@return (fun(...:unknown):unknown)? runnable
---@return string? err syntax error description; nil when a runnable is returned
function M.make_runnable(code, params)
	if not code:find 'return[^\n]*$' and not code:find '[^=]=[^=][^\n]*$' then
		code = code:gsub('([^\n]+)$', 'return %1', 1)
	end
	local wrapped = params ~= nil and #params > 0
	if wrapped then code = ('return function(%s) %s end'):format(table.concat(params, ', '), code) end

	-- the chunk name lands in runtime error locations: the '=' renders it
	-- literally (no [string ...] wrapping), reading better than the
	-- wrapped source dump
	local cb, err = loadstring(code, '=input')
	---@diagnostic disable-next-line: need-check-nil
	if not cb or err then return nil, err end
	if wrapped then return cb() end -- the chunk built the declared function
	return cb
end

---@param so_path string path relative to sai as pwd
---@return string? src matching `.cpp` or generated `.c` source
---@return string? compiler `g++` or `gcc` for the source
local function source_of(so_path)
	for _, src_type in ipairs { { 'cpp', 'g++' }, { 'c', 'gcc' } } do
		local src = so_path:gsub('so$', src_type[1])
		if os.rename(src, src) then return src, src_type[2] end
	end
end

---@param so_path string path relative to sai as pwd
function M.compile_so(so_path)
	local src, compiler = source_of(so_path)
	if not src then error('No source file for module: ' .. so_path) end
	-- stock Lua C sources expect the luajit include path and the 5.2+ module
	-- export macro that LuaJIT headers do not define
	local cflags = compiler == 'gcc' and '-I/usr/include/luajit-2.1 -DLUAMOD_API=' or ''
	local h = io.popen(string.format( --
		'%s -O2 -shared -fPIC %s -o "%s" "%s" 2>&1 >/dev/null',
		compiler,
		cflags,
		so_path,
		src
	)) or error 'Error in compilation command'
	local out = h:read 'a'
	h:close()
	if out ~= '' then error('Failed to compile module: ' .. out) end
end

---@param so_path string path relative to sai as pwd
---@return unknown
function M.load_so(so_path)
	if not source_of(so_path) then error('No source file for module: ' .. so_path) end
	if not os.rename(so_path, so_path) then M.compile_so(so_path) end

	local loader, err = package.loadlib(so_path, 'luaopen_' .. so_path:match '([^/]+)%.so$')
	if not loader then error('Unable to load ' .. err) end
	return loader()
end

return M
