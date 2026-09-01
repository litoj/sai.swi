---@diagnostic disable: invisible
---@module 'sai.bridge.ipc'

local sock = require 'sai.bridge.socket'
local U = require 'sai.lib.utils'

local function pack_u32_le(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function unpack_u32_le(s) return s:byte(1) + s:byte(2) * 256 + s:byte(3) * 65536 + s:byte(4) * 16777216 end

---IPC: remote Lua code execution via Unix domain socket.
---@class sai.bridge.ipc
---@field enabled boolean starts/stops the server or client
---@field private _socket_path string
local M = {
	_enabled = false, ---@protected
	_max_msg_size = 1024 * 1024, ---@private
	_timeout = 5, ---@private
	_leave_hook = nil, ---@private
}

function M:set_enabled(val)
	if self._enabled == val then return false end
	self._enabled = val

	if not self._leave_hook and sai and val then
		self._leave_hook = sai.eventloop.subscribe {
			event = 'SwiLeavePre',
			callback = function()
				self.enabled = false
				return true
			end,
		}
	end
end

local backer_meta = {
	__index = function(self, key) return rawget(self, '_' .. key) end,
	__newindex = function(self, key, val)
		local setter = rawget(self, 'set_' .. key)
		if setter then
			setter(self, val, key)
		else
			rawset(self, key, val)
		end
	end,
}

---Server: a socket server extension - signal-driven when sai handles the
---Signal events, otherwise call `poll(0)` manually (poll-driven).
---@class sai.bridge.ipc.server : sai.bridge.ipc, sai.bridge.socket.server
local server = {
	super = sock.Server,
	_signal = 'USR2', ---@protected signal for the socket io or false to disable
}
setmetatable(server, { __index = server.super })

---@generic O: sai.bridge.ipc.server
---@param self `O` with `_socket_path` set
---@return `O`
function server.new(self)
	U.new_object(self, server)
	U.new_object(self, M)
	if type(self._socket_path) ~= 'string' or #self._socket_path == 0 then error 'IPC: path is required' end
	return setmetatable(self, backer_meta)
end

---@protected
function server:set_enabled(val)
	if self._enabled == val then return false end

	if val then
		if type(self._socket_path) ~= 'string' then error 'IPC: socket path not set' end

		self.path = self._socket_path
		self.signal = self._signal
		sock.Server.new(self)

		M.set_enabled(self, true)
	else
		M.set_enabled(self, false)

		if self.listen_fd >= 0 then self:stop() end
	end
end

--- Handle a connection. `io` is a bidirectional channel:
--- `io()` reads and returns the next client message (nil on disconnect).
--- `io(result)` sends a result, then reads and returns the next message.
--- `io(nil, err)` sends an error, then reads and returns the next message.
--- Override to implement custom protocols.
---@param io fun(result?: string, err?: string): string?
function server.handle(io)
	local code = io()
	while code do
		local fn, err = load(code)
		if not fn then
			code = io(nil, err)
		else
			local ok, ret = pcall(fn)
			if ok then
				code = io(tostring(ret))
			else
				code = io(nil, ret)
			end
		end
	end
end

---Serves one connection to completion.
---@param conn sai.bridge.socket.conn
function server:on_conn(conn)
	conn:set_timeouts(self._timeout)

	local function io(result, err)
		if result ~= nil or err ~= nil then
			local st = result and 0 or 1
			local s = result or err
			if not conn:send(string.char(st) .. pack_u32_le(#s) .. s) then return nil end
		end

		local h = conn:read(4)
		if not h then return nil end
		local n = unpack_u32_le(h)
		if n > self._max_msg_size then return nil end
		return conn:read(n)
	end

	pcall(self.handle, io)

	conn:close()
end

---Client: a socket connection extension - connects, synchronous send/recv.
---@class sai.bridge.ipc.client : sai.bridge.ipc, sai.bridge.socket.conn
local client = {
	super = sock.Conn,
}
setmetatable(client, { __index = client.super })

---@generic O: sai.bridge.ipc.client
---@param self `O` with `_socket_path` set
---@return `O`
function client.new(self)
	U.new_object(self, client)
	U.new_object(self, M)
	if type(self._socket_path) ~= 'string' or #self._socket_path == 0 then error 'IPC: path is required' end
	return setmetatable(self, backer_meta)
end

---Send Lua code to execute on the server. A function is sent as bytecode
---(`load` on the server accepts both): it must be self-contained - client
---upvalue values do not travel and globals resolve on the server.
---@param code string|function
---@return string? result
---@return string? err
function client:send(code)
	if self.fd < 0 then return nil, 'not connected' end

	if type(code) == 'function' then
		local ok, dumped = pcall(string.dump, code)
		if not ok then return nil, 'cannot dump function: ' .. tostring(dumped) end
		code = dumped
	end

	local payload = pack_u32_le(#code) .. code
	if not self.super.send(self, payload) then return nil, 'send failed' end

	local header = self:read(5)
	if not header then return nil, 'connection closed' end

	local status = header:byte(1)
	local resp_len = unpack_u32_le(header:sub(2, 5))
	if resp_len > self._max_msg_size then return nil, 'response too large' end

	local data = self:read(resp_len)
	if not data then return nil, 'connection closed' end

	if status == 0 then return data, nil end
	return nil, data
end

---@protected
function client:set_enabled(val)
	if self._enabled == val then return false end

	if val then
		if type(self._socket_path) ~= 'string' then error 'IPC: socket path not set' end

		self.path = self._socket_path
		sock.Conn.new(self)
		self:set_timeouts(self._timeout)

		M.set_enabled(self, true)
	else
		M.set_enabled(self, false)

		if self.fd >= 0 then self:close() end
	end
end

---@param path string?
---@return sai.bridge.ipc.server
function M.server(path)
	local self = server.new {
		_socket_path = path or ('%s/%s-%d.socket'):format( -- default path
			os.getenv 'XDG_RUNTIME_DIR' or '/tmp',
			sai.app_id,
			sai.pid
		),
	}
	self:set_enabled(true)
	return self
end

---@param path string
---@return sai.bridge.ipc.client
function M.client(path)
	local self = client.new { _socket_path = path }
	self:set_enabled(true)
	return self
end

return M
