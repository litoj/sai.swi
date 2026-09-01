---@module 'sai.bridge.socket'
---Generic unix-socket layer for the bridge modules (debug, ipc): buffered
---connections and servers with O_ASYNC arming and signal-driven or polled
---io dispatch. Extend the class tables the way the sai modes extend each
---other (`super` + U.new_object flattening) and override the `on_*` hooks;
---framing stays with the consumers.
local ffi = require 'ffi'
local bit = require 'bit'
local U = require 'sai.lib.utils'

-- applied one by one: another module in the same process may have defined
-- some of them already (ffi.cdef cannot redefine)
local DEFS = {
	'typedef unsigned short sa_family_t;',
	'typedef unsigned int mode_t;',
	'typedef int pid_t;',
	'struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; };',
	'struct timeval { long tv_sec; long tv_usec; };',
	'struct pollfd { int fd; short events; short revents; };',
	'int socket(int domain, int type, int protocol);',
	'int bind(int fd, const struct sockaddr_un *addr, int addrlen);',
	'int listen(int fd, int backlog);',
	'int accept4(int fd, void *addr, void *addrlen, int flags);',
	'int connect(int fd, const struct sockaddr_un *addr, int addrlen);',
	'int recv(int fd, void *buf, size_t len, int flags);',
	'int send(int fd, const void *buf, size_t len, int flags);',
	'int close(int fd);',
	'int unlink(const char *path);',
	'int fcntl(int fd, int cmd, ...);',
	'int chmod(const char *path, mode_t mode);',
	'pid_t getpid(void);',
	'int setsockopt(int fd, int level, int optname, const void *optval, int optlen);',
	'int poll(struct pollfd *fds, unsigned long nfds, int timeout);',
}

for _, def in ipairs(DEFS) do
	pcall(ffi.cdef, def)
end

local AF_UNIX = 1
local SOCK_STREAM = 1
local SOCK_NONBLOCK = 0x800
local MSG_DONTWAIT = 0x40
local MSG_NOSIGNAL = 0x4000
local F_SETFL, F_SETOWN, F_SETSIG = 4, 8, 10
local O_ASYNC, O_NONBLOCK = 0x2000, 0x800
local SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO = 1, 20, 21
local SIGUSR1, SIGUSR2 = 10, 12
local POLLIN, POLLERR, POLLHUP = 0x1, 0x8, 0x10

local M = {}

---Is the signal actually handled by this process?
---swayimg installs its SIGUSR1/2 handlers only after the config script
---finished; arming O_ASYNC before that kills the process on the first
---IO signal (default action).
---@param signal string 'USR1' or 'USR2'
---@return boolean
local function signal_handled(signal)
	local num = signal == 'USR1' and SIGUSR1 or SIGUSR2
	local f = io.open('/proc/self/status', 'r')
	if not f then return false end
	local txt = f:read '*a'
	f:close()
	local mask = tonumber(txt:match 'SigCgt:%s*(%x+)' or '', 16)
	if not mask then return false end
	return bit.band(mask, bit.lshift(1, num - 1)) ~= 0
end

local function arm_fd(fd, signal, nonblocking)
	local sig = signal == 'USR1' and SIGUSR1 or SIGUSR2
	ffi.C.fcntl(fd, F_SETOWN, ffi.new('int', tonumber(ffi.C.getpid())))
	ffi.C.fcntl(fd, F_SETSIG, ffi.new('int', sig))
	local flags = O_ASYNC
	if nonblocking then flags = bit.bor(flags, O_NONBLOCK) end
	ffi.C.fcntl(fd, F_SETFL, ffi.new('int', flags))
end

local function make_addr(path)
	local addr = ffi.new 'struct sockaddr_un'
	addr.sun_family = AF_UNIX
	ffi.copy(ffi.cast('char *', addr.sun_path), path)
	return addr
end

local function check_path(path)
	if type(path) ~= 'string' or #path > 107 then error('socket: invalid path: ' .. tostring(path)) end
end

---@class sai.bridge.socket.conn
---@field fd integer
---@field buffer string received bytes not yet consumed by the framing
---@field owner sai.bridge.socket.server? set while tracked by the server
local Conn = {
	fd = -1,
	buffer = '',
	owner = nil,
}

---Append everything currently readable without blocking.
---Returns whether the peer closed the connection.
---@return boolean closed
function Conn:drain()
	local buf = ffi.new 'char[65536]'
	while true do
		local r = ffi.C.recv(self.fd, buf, 65536, MSG_DONTWAIT)
		if r > 0 then
			self.buffer = self.buffer .. ffi.string(buf, r)
		else
			return r == 0
		end
	end
end

---Read exactly `n` bytes, first from the buffer, then blocking from the
---socket. Nil on error or close.
---@param n integer
---@return string?
function Conn:read(n)
	if #self.buffer >= n then
		local data = self.buffer:sub(1, n)
		self.buffer = self.buffer:sub(n + 1)
		return data
	end
	local buf = ffi.new('char[?]', n)
	local got = 0
	if #self.buffer > 0 then
		ffi.copy(buf, self.buffer)
		got = #self.buffer
		self.buffer = ''
	end
	while got < n do
		local r = ffi.C.recv(self.fd, buf + got, n - got, 0)
		if r <= 0 then return nil end
		got = got + r
	end
	return ffi.string(buf, n)
end

---Send the whole buffer; never raises SIGPIPE.
---@param data string
---@return boolean ok
function Conn:send(data)
	local sent, total = 0, #data
	while sent < total do
		local ptr = ffi.cast('const char *', data) + sent
		local n = ffi.C.send(self.fd, ptr, total - sent, MSG_NOSIGNAL)
		if n <= 0 then return false end
		sent = sent + n
	end
	return true
end

---@param seconds integer
function Conn:set_timeouts(seconds)
	local tv = ffi.new('struct timeval', { tv_sec = seconds, tv_usec = 0 })
	ffi.C.setsockopt(self.fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
	ffi.C.setsockopt(self.fd, SOL_SOCKET, SO_SNDTIMEO, tv, ffi.sizeof(tv))
end

function Conn:close()
	if self.fd >= 0 then
		ffi.C.close(self.fd)
		self.fd = -1
	end
	local srv = self.owner
	if srv then
		self.owner = nil
		for i, c in ipairs(srv.conns) do
			if c == self then
				table.remove(srv.conns, i)
				break
			end
		end
	end
end

---Connect a blocking client unix socket (`self.path` set), or wrap an
---already accepted fd (`self.fd` set). `self` may be a Conn extension.
---@generic O: table
---@param self `O`
---@return `O`
function Conn.new(self)
	U.new_object(self, Conn)
	if self.path then
		check_path(self.path)
		local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
		if fd < 0 then error 'socket: failed to create socket' end
		if ffi.C.connect(fd, make_addr(self.path), ffi.sizeof 'struct sockaddr_un') < 0 then
			ffi.C.close(fd)
			error('socket: failed to connect to ' .. self.path)
		end
		self.fd = fd
	end
	return self
end

---@class sai.bridge.socket.server
---@field path string
---@field signal string? 'USR1' or 'USR2'
---@field arm_conns boolean track, arm and report accepted connections
---@field conns sai.bridge.socket.conn[]
---@field listen_fd integer
local Server = {
	arm_conns = false,
}

---Hook: called per accepted connection, after the socket layer drained it.
function Server:on_conn(conn) end

---Hook: called on io of an armed connection.
function Server:on_data(conn) end

---Hook: signal dispatch; also runs after the fds were finally armed.
function Server:on_io() self:poll(0) end

local function try_arm(srv)
	if not srv.signal then return true end
	if not signal_handled(srv.signal) then return false end
	arm_fd(srv.listen_fd, srv.signal, true)
	for _, conn in ipairs(srv.conns) do
		arm_fd(conn.fd, srv.signal, false)
	end
	return true
end

---swayimg installs its signal handlers only after the config script
---finished: keep retrying until then, then dispatch what arrived unarmed.
local function arm_retry(srv, attempt)
	if srv.listen_fd < 0 or attempt > 100 then return end
	if try_arm(srv) then
		srv:on_io()
		return
	end
	if sai and sai.defer_fn then sai.defer_fn(function() arm_retry(srv, attempt + 1) end, 100) end
end

function Server:accept()
	while true do
		local cfd = ffi.C.accept4(self.listen_fd, nil, nil, 0)
		if cfd < 0 then break end
		local conn = Conn.new { fd = cfd }
		-- O_ASYNC only signals NEW data: bytes that arrived before the
		-- accept never wake us - drain now so on_conn sees them.  EOF
		-- here does not mean dead: half-closing peers (shutdown on
		-- their write side) deliver data-then-FIN in one breath, so
		-- serve the buffered request and let read() hit the EOF only
		-- after it consumed the data.
		conn:drain()
		if self.arm_conns then
			conn.owner = self
			self.conns[#self.conns + 1] = conn
			if self.signal and signal_handled(self.signal) then arm_fd(conn.fd, self.signal, false) end
		end
		self:on_conn(conn)
	end
end

---Poll the listen socket and the armed connections for `timeout` ms,
---then dispatch what is ready.
function Server:poll(timeout)
	if self.listen_fd < 0 then return end
	-- snapshot: the accept dispatch below may close or add connections
	local watched = {}
	for i, conn in ipairs(self.conns) do
		watched[i] = conn
	end
	local n = #watched + 1
	local arr = ffi.new('struct pollfd[?]', n)
	arr[0].fd = self.listen_fd
	arr[0].events = POLLIN
	for i, conn in ipairs(watched) do
		arr[i].fd = conn.fd
		arr[i].events = POLLIN
	end
	if ffi.C.poll(arr, n, timeout) < 0 then return end
	if bit.band(arr[0].revents, POLLIN) ~= 0 then self:accept() end
	for i, conn in ipairs(watched) do
		local re = bit.band(arr[i].revents, bit.bor(POLLIN, POLLERR, POLLHUP))
		if conn.fd >= 0 and re ~= 0 then self:on_data(conn) end
	end
end

function Server:stop()
	while self.conns[1] do
		self.conns[1]:close()
	end
	if self.listen_fd >= 0 then
		ffi.C.close(self.listen_fd)
		self.listen_fd = -1
	end
	if self.path then pcall(ffi.C.unlink, self.path) end
	if self.sub then
		if sai and sai.eventloop and sai.eventloop.unsubscribe then
			pcall(sai.eventloop.unsubscribe, { id = self.sub })
		end
		self.sub = nil
	end
end

---Create a listening unix-socket server. Config on `self`: `path`
---(required), `signal?`. `self` may be a Server extension: the socket
---methods and hook defaults are flattened into it, overrides survive.
---Re-creating after `stop()` re-binds the socket.
---@generic O: table
---@param self `O`
---@return `O`
function Server.new(self)
	U.new_object(self, Server)
	check_path(self.path)
	self.conns = {}
	self.listen_fd = -1
	self.sub = nil

	local fd = ffi.C.socket(AF_UNIX, bit.bor(SOCK_STREAM, SOCK_NONBLOCK), 0)
	if fd < 0 then error 'socket: failed to create socket' end
	ffi.C.unlink(self.path)
	local addr = make_addr(self.path)
	if ffi.C.bind(fd, addr, ffi.sizeof(addr)) < 0 then
		ffi.C.close(fd)
		error('socket: failed to bind ' .. self.path)
	end
	if ffi.C.listen(fd, 5) < 0 then
		ffi.C.close(fd)
		error 'socket: failed to listen'
	end
	ffi.C.chmod(self.path, 0x180)
	self.listen_fd = fd

	if self.signal then
		if not try_arm(self) then arm_retry(self, 0) end
		if sai and sai.eventloop and sai.eventloop.subscribe then
			self.sub = sai.eventloop.subscribe {
				event = 'Signal',
				pattern = self.signal,
				callback = function() self:on_io() end,
			}
		end
	end
	return self
end

M.Server = Server
M.Conn = Conn

return M
