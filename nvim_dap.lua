---@module 'sai.nvim_dap'
local M = {}

local ADAPTER = 'sai'

local function uv() return vim.uv or vim.loop end

-- vim.env is a lookup table in nvim, os.getenv a function elsewhere
local env_get = vim and function(k) return vim.env[k] end or os.getenv
local runtime_dir = env_get 'XDG_RUNTIME_DIR' or '/tmp'

local function socket_path(pid) return ('%s/sai-debug-%d.sock'):format(runtime_dir, pid) end

---Test injection for the process/filesystem seams.
---@class sai.nvim_dap.probe
---@field glob? fun(pattern: string): string[] default vim.fn.glob
---@field fs_stat? fun(path: string): unknown default uv().fs_stat

---Lists running swayimg instances with an active debug harness.
---@param probe? sai.nvim_dap.probe
---@return { pid: integer, path: string }[]
function M.sockets(probe)
	local glob = probe and probe.glob or function(pat) return vim.fn.glob(pat, false, true) end
	local fs_stat = probe and probe.fs_stat or uv().fs_stat
	local out = {}
	for _, path in ipairs(glob(runtime_dir .. '/sai-debug-*.sock')) do
		local pid = tonumber(path:match 'sai%-debug%-(%d+)%.sock$')
		if pid and fs_stat(('/proc/%d'):format(pid)) then out[#out + 1] = { pid = pid, path = path } end
	end
	return out
end

---@param config table attach config: explicit `pipe`/`pid` or auto-discovery
---@param probe? sai.nvim_dap.probe
---@return string? path, integer count running instances (0 when the explicit target is missing)
function M.resolve(config, probe)
	local fs_stat = probe and probe.fs_stat or uv().fs_stat
	if config.pipe then
		if fs_stat(config.pipe) then return config.pipe, 1 end
		return nil, 0
	end
	if config.pid then
		local path = socket_path(config.pid)
		if fs_stat(path) then return path, 1 end
		return nil, 0
	end
	local found = M.sockets(probe)
	if #found == 1 then return found[1].path, 1 end
	return nil, #found
end

---Registers the `sai` adapter and 'Attach to swayimg' config; offered only under a swayimg dir.
---Run `require('sai.bridge.debug').start {}` in swayimg (Shift+F6) to launch the socket.
function M.setup()
	local dap = require 'dap'
	dap.adapters[ADAPTER] = function(callback, config)
		local path, count = M.resolve(config)
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
