---@module 'sai.nvim_dap'
local M = {}

local ADAPTER = 'sai'

local function uv() return vim.uv or vim.loop end

local function socket_path(pid) return ('%s/sai-debug-%d.sock'):format(vim.env.XDG_RUNTIME_DIR or '/tmp', pid) end

---Lists running swayimg instances with an active debug harness.
---@return { pid: integer, path: string }[]
function M.sockets()
	local dir = vim.env.XDG_RUNTIME_DIR or '/tmp'
	local out = {}
	for _, path in ipairs(vim.fn.glob(dir .. '/sai-debug-*.sock', false, true)) do
		local pid = tonumber(path:match 'sai%-debug%-(%d+)%.sock$')
		if pid and uv().fs_stat(('/proc/%d'):format(pid)) then out[#out + 1] = { pid = pid, path = path } end
	end
	return out
end

local function resolve(config)
	if config.pipe then
		if uv().fs_stat(config.pipe) then return config.pipe end
		return nil, 0
	end
	if config.pid then
		local path = socket_path(config.pid)
		if uv().fs_stat(path) then return path end
		return nil, 0
	end
	local found = M.sockets()
	if #found == 1 then return found[1].path end
	return nil, #found
end

---Registers the `sai` adapter and the lua 'Attach to swayimg' configuration in nvim-dap.
---The configuration is offered only when the current file lives under a swayimg
---directory; run `require('sai.bridge.debug').start {}` in swayimg (bound to
---Shift+F6 by default) to launch the socket
function M.setup()
	local dap = require 'dap'
	dap.adapters[ADAPTER] = function(callback, config)
		local path, count = resolve(config)
		if not path then
			local msg = count > 1
					and ('sai.nvim_dap: %d debug-enabled swayimg instances running, close the others'):format(count)
				or 'sai.nvim_dap: no debug-enabled swayimg instance running'
			vim.notify(msg, vim.log.levels.ERROR)
			return
		end
		callback { type = 'pipe', pipe = path }
	end
	dap.providers.configs['sai.swayimg'] = function(bufnr)
		if not vim.api.nvim_buf_get_name(bufnr):find('/swayimg/', 1, true) then return {} end
		return {
			{
				name = 'Attach to swayimg',
				type = ADAPTER,
				request = 'attach',
			},
		}
	end
end

return M
