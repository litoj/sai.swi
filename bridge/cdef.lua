---@module 'sai.bridge.cdef'
---The ffi cdefs used by more than one runtime module.

local ffi = require 'ffi'

ffi.cdef [[
typedef int pid_t;
pid_t getpid(void);
]]

return ffi
