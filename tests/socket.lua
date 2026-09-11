---Tests for sai.bridge.socket: path checks, in-process client/server
---framing, tracking and teardown.
---Runs in-process over real unix sockets in /tmp.
---Development tool: not used during normal swayimg operation.

local dir = debug.getinfo(1, 'S').source:match '^@(.*)/'
if not dir:match '^/' then dir = (os.getenv 'PWD' or '.') .. '/' .. dir end
package.path = dir .. '/?.lua;' .. package.path

local H = require 'harness'

local sock = require 'sai.bridge.socket'

local PATH = '/tmp/sai_socket_test.sock'
local function cleanup()
	pcall(function() os.remove(PATH) end)
end
cleanup()

local T = {}

-- the sun_path fit is checked up front; both ends reject oversize paths
T.check_path = function(h)
	h.ok('server rejects an overlong path', not pcall(sock.Server.new, { _socket_path = string.rep('a', 200) }))
	h.ok('conn rejects an overlong path', not pcall(sock.Conn.new, { _socket_path = string.rep('a', 200) }))
	h.ok('conn rejects a non-string path', not pcall(sock.Conn.new, { _socket_path = 42 }))
end

-- connect, exchange framed text both ways, close from both sides
T.round_trip_and_close = function(h)
	local ran, err = pcall(function()
		local seen = {}
		local srv = sock.Server.new {
			_socket_path = PATH,
			_signal = nil,
			_arm_conns = true,
			on_conn = function() seen[#seen + 1] = 'conn' end,
			on_data = function(_, conn)
				conn:drain()
				local msg = conn:read(2)
				if msg then
					seen[#seen + 1] = msg
					conn:send 'hi'
				end
			end,
		}

		local cli = sock.Conn.new { _socket_path = PATH }
		srv:poll(0) -- accept
		h.eq('accept hook fired', 1, #seen)
		h.eq('server tracks the conn', 1, #srv._conns)

		cli:send 'yo'
		srv:poll(10) -- dispatch the data hook
		h.eq('server read the frame', 'yo', seen[2])
		h.eq('client read the reply', 'hi', cli:read(2))

		h.eq('server tracks the accepted side', 1, #srv._conns)
		srv._conns[1]:close()
		h.eq('a tracked conn untracks on close', 0, #srv._conns)

		cli:close()
		h.eq('client fd resets to -1', -1, cli._fd)

		srv:stop()
		h.eq('socket file unlinked', false, H.file_exists(PATH))
		h.eq('listen fd released', -1, srv._listen_fd)
	end)
	cleanup()
	if not ran then error(err, 0) end
end

-- half-closing peers: data and FIN in one breath are served, not dropped
T.drain_serves_data_before_eof = function(h)
	local got
	local srv = sock.Server.new {
		_socket_path = PATH,
		_signal = nil,
		_arm_conns = true,
		on_data = function(_, conn)
			conn:drain()
			got = conn:read(5)
		end,
	}
	local ran, err = pcall(function()
		local cli = sock.Conn.new { _socket_path = PATH }
		cli:send 'later'
		cli:close() -- send-then-FIN before the server ever polls
		srv:poll(10) -- accepts and drains; the eof arrives on the accepted fd
		srv:poll(10) -- the drained request is served despite the dead peer
		h.eq('buffered data served despite the EOF', 'later', got)
		srv:stop()
	end)
	cleanup()
	if not ran then error(err, 0) end
end

H.maybe_standalone(T)

return T
