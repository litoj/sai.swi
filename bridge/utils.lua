---@module 'sai.bridge.utils'
---@class sai.bridge.utils
local BU = {}

---@param cmd string
---@return string
function BU.parse_shell_cmd(cmd)
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

-- TODO: how to make stderr appear? 2>&1 doesn't work
---@see sai.exec
function BU.exec(cmd, async)
	cmd = BU.parse_shell_cmd(cmd)

	if async then return cmd, select(1, os.execute(('{ %s; } >/dev/null </dev/null &'):format(cmd))) end

	local p, err = io.popen(cmd .. '\necho $?', 'r')
	if not p then error('Error executing command: ' .. (err or '')) end
	local out = p:read '*a'
	p:close()

	local code = out:match '(%d+)\n$'
	out = out:sub(1, -#code - 2)

	sai.eventloop.trigger { event = 'User', match = 'ShellCmdPost', data = { cmd = cmd, stdout = out } }
	return out, code
end

---Get the current Wayland clipboard content via wl-paste.
---@return string? text clipboard content, or nil on failure
function BU.clipboard_get()
	local p = io.popen('wl-paste -n', 'r')
	if not p then return end
	local text = p:read '*a'
	p:close()
	return text
end

---Set the Wayland clipboard content via wl-copy.
---@param text string text to copy to clipboard
---@return boolean ok true on success
function BU.clipboard_set(text)
	local p = io.popen('wl-copy', 'w')
	if not p then return false end
	p:write(text)
	sai.notify 'Copied text to clipboard'
	return p:close()
end

---@param code string
---@return (fun(self?:any):any)?
function BU.make_runnable(code)
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

---@param so_path string path relative to sai as pwd
function BU.compile_so(so_path)
	local h = io.popen(string.format( --
		'g++ -O2 -shared -fPIC -o "%s" "%s" 2>&1 >/dev/null',
		so_path,
		so_path:gsub('so$', 'cpp')
	)) or error 'Error in compilation command'
	local out = h:read 'a'
	h:close()
	if out ~= '' then error('Failed to compile module: ' .. out) end
end

function BU.load_so(so_path)
	local src = so_path:gsub('so$', 'cpp')
	if not os.rename(src, src) then error('No such cpp module: ' .. src) end
	if not os.rename(so_path, so_path) then BU.compile_so(so_path) end

	local loader = package.loadlib(so_path, 'luaopen_' .. so_path:match '([^/]+)%.so$')
	if not loader then error('Unable to load library: ' .. so_path) end
	return loader()
end

return BU
