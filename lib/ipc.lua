---@diagnostic disable: invisible
---@module 'sai.lib.ipc'

local ffi = require 'ffi'
local bit = require 'bit'

local AF_UNIX = 1
local SOCK_STREAM = 1
local SOCK_NONBLOCK = 0x800
local F_SETFL = 4
local F_SETOWN = 8
local F_SETSIG = 10
local F_GETFL = 3
local O_NONBLOCK = 0x800
local O_ASYNC = 0x2000
local SOL_SOCKET = 1
local SO_RCVTIMEO = 20
local SO_SNDTIMEO = 21
local SIGUSR1 = 10
local SIGUSR2 = 12

ffi.cdef [[
typedef unsigned short sa_family_t;
typedef unsigned int mode_t;
typedef int pid_t;

struct sockaddr_un {
	sa_family_t sun_family;
	char sun_path[108];
};

struct timeval {
	long tv_sec;
	long tv_usec;
};

int socket(int domain, int type, int protocol);
int bind(int fd, const struct sockaddr_un *addr, int addrlen);
int listen(int fd, int backlog);
int accept4(int fd, void *addr, void *addrlen, int flags);
int connect(int fd, const struct sockaddr_un *addr, int addrlen);
int recv(int fd, void *buf, size_t len, int flags);
int send(int fd, const char *buf, size_t len, int flags);
int close(int fd);
int unlink(const char *path);
int fcntl(int fd, int cmd, ...);
int chmod(const char *path, mode_t mode);
pid_t getpid(void);
int setsockopt(int fd, int level, int optname, const void *optval, int optlen);
]]

local function pack_u32_le(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function unpack_u32_le(s) return s:byte(1) + s:byte(2) * 256 + s:byte(3) * 65536 + s:byte(4) * 16777216 end

local function recv_all(fd, n)
	local buf = ffi.new('char[?]', n)
	local received = 0
	while received < n do
		local r = ffi.C.recv(fd, buf + received, n - received, 0)
		if r <= 0 then return nil end
		received = received + r
	end
	return ffi.string(buf, n)
end

local function send_all(fd, data)
	local len = #data
	local sent = 0
	while sent < len do
		local ptr = ffi.cast('const char *', data) + sent
		local s = ffi.C.send(fd, ptr, len - sent, 0)
		if s <= 0 then return false end
		sent = sent + s
	end
	return true
end

local function set_timeouts(fd, seconds)
	local tv = ffi.new('struct timeval', { tv_sec = seconds, tv_usec = 0 })
	ffi.C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
	ffi.C.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))
end

local function make_addr(path)
	---@type sai.lib.ipc.sockaddr_un
	local addr = ffi.new 'struct sockaddr_un' ---@diagnostic disable-line: assign-type-mismatch
	addr.sun_family = AF_UNIX --[[@as integer]]
	ffi.copy(ffi.cast('char *', addr.sun_path), path)
	return addr
end

---@class sai.lib.ipc.sockaddr_un : ffi.cdata*
---@field sun_family integer
---@field sun_path string

---IPC: remote Lua code execution via Unix domain socket.
---@class sai.lib.ipc
---@field enabled boolean starts/stops the server or client
---@field private _socket_path string
local M = {
	_enabled = false, ---@protected
	_max_msg_size = 1024 * 1024, ---@private
	_timeout = 5, ---@private
	_fd = -1, ---@private
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

---Server instance: binds, listens, O_ASYNC + signal.
---`hook` is called on enable/disable to manage the signal subscription.
---The default hooks into sai.eventloop Signal events.
---Set `hook = nil` for manual control.
---@class sai.lib.ipc.server : sai.lib.ipc
local server = {
	_signal = 'USR2', ---@protected signal to listen on or false to disable auto-hook
	_sub_id = nil, ---@private
}

---@protected
function server:set_enabled(val)
	if self._enabled == val then return false end

	if val then
		local path = self._socket_path
		if type(path) ~= 'string' then error 'IPC: socket path not set' end

		local fd = ffi.C.socket(AF_UNIX, bit.bor(SOCK_STREAM, SOCK_NONBLOCK), 0)
		if fd < 0 then error 'IPC: failed to create socket' end

		ffi.C.unlink(path)

		local addr = make_addr(path)

		if ffi.C.bind(fd, addr, ffi.sizeof(addr)) < 0 then
			ffi.C.close(fd)
			error('IPC: failed to bind socket to ' .. path)
		end

		if ffi.C.listen(fd, 5) < 0 then
			ffi.C.close(fd)
			error 'IPC: failed to listen on socket'
		end

		ffi.C.chmod(path, bit.bor(0x100, 0x80))

		if self._signal then
			local signum = self._signal == 'USR1' and SIGUSR1 or SIGUSR2
			ffi.C.fcntl(fd, F_SETOWN, ffi.new('int', tonumber(ffi.C.getpid())))
			ffi.C.fcntl(fd, F_SETSIG, ffi.new('int', signum))
			ffi.C.fcntl(fd, F_SETFL, ffi.new('int', bit.bor(O_NONBLOCK, O_ASYNC)))
		end

		self._fd = fd --[[@as integer]]
		print('IPC listening on ' .. path)

		M.set_enabled(self, true)
		if self.hook then self.hook(self, true) end
	else
		if self.hook then self.hook(self, false) end
		M.set_enabled(self, false)

		if self._fd >= 0 then
			ffi.C.close(self._fd)
			self._fd = -1
		end

		if self._socket_path then ffi.C.unlink(self._socket_path) end
	end
end

--- Default hook: subscribe to sai.eventloop Signal events.
---@param self sai.lib.ipc.server
---@param enable boolean
function server.hook(self, enable)
	if enable then
		if sai then
			self._sub_id = sai.eventloop.subscribe {
				event = 'Signal',
				pattern = self._signal,
				callback = function() self:receive() end,
			}
		end
	else
		if self._sub_id then
			sai.eventloop.unsubscribe { id = self._sub_id }
			self._sub_id = nil
		end
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

function server:receive()
	while true do
		local fd = ffi.C.accept4(self._fd, nil, nil, 0)
		if fd < 0 then break end

		local flags = ffi.C.fcntl(fd, F_GETFL, 0)
		if flags >= 0 then ffi.C.fcntl(fd, F_SETFL, bit.band(flags, bit.bnot(O_NONBLOCK))) end

		set_timeouts(fd, self._timeout)

		local function io(result, err)
			if result ~= nil or err ~= nil then
				local st = result and 0 or 1
				local s = result or err
				if not send_all(fd, string.char(st) .. pack_u32_le(#s) .. s) then return nil end
			end

			local h = recv_all(fd, 4)
			if not h then return nil end
			local n = unpack_u32_le(h)
			if n > self._max_msg_size then return nil end
			return recv_all(fd, n)
		end

		pcall(self.handle, io)

		ffi.C.close(fd)
	end
end

---Client instance: connects, synchronous send/recv.
---@class sai.lib.ipc.client : sai.lib.ipc
local client = {}

---@param code string
---@return string? result
---@return string? err
function client:send(code)
	if not self._enabled then return nil, 'not connected' end

	local payload = pack_u32_le(#code) .. code
	if not send_all(self._fd, payload) then return nil, 'send failed' end

	local header = recv_all(self._fd, 5)
	if not header then return nil, 'connection closed' end

	local status = header:byte(1)
	local resp_len = unpack_u32_le(header:sub(2, 5))
	if resp_len > self._max_msg_size then return nil, 'response too large' end

	local data = recv_all(self._fd, resp_len)
	if not data then return nil, 'connection closed' end

	if status == 0 then return data, nil end
	return nil, data
end

---@protected
function client:set_enabled(val)
	if self._enabled == val then return false end

	if val then
		local path = self._socket_path
		if type(path) ~= 'string' then error 'IPC: socket path not set' end

		local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
		if fd < 0 then error 'IPC: failed to create socket' end

		local addr = make_addr(path)

		if ffi.C.connect(fd, addr, ffi.sizeof(addr)) < 0 then
			ffi.C.close(fd)
			error('IPC: failed to connect to ' .. path)
		end

		set_timeouts(fd, self._timeout)
		self._fd = fd --[[@as integer]]
		print('IPC connected to ' .. path)

		M.set_enabled(self, true)
	else
		M.set_enabled(self, false)

		if self._fd >= 0 then
			ffi.C.close(self._fd)
			self._fd = -1
		end
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

---@private
function M:new(path)
	if type(path) ~= 'string' or #path == 0 then error 'IPC: path is required' end
	if #path > 107 then error('IPC: socket path too long: ' .. path) end

	local new = { _socket_path = path }

	for k, v in pairs(M) do
		new[k] = v
	end
	for k, v in pairs(self) do
		new[k] = v
	end

	return setmetatable(new, backer_meta)
end

---@param path string
---@return sai.lib.ipc.server
function M.server(path)
	local self = M.new(server, path)
	self:set_enabled(true)
	return self
end

---@param path string
---@return sai.lib.ipc.client
function M.client(path)
	local self = M.new(client, path)
	self:set_enabled(true)
	return self
end

return M
