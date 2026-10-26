-- h96: load MPRIS plugin only when this user's session bus is reachable (plugin waits forever on unusable bus)
local utils = require "mp.utils"

local function uid()
    local f = io.open("/proc/self/status")
    if not f then return nil end
    for l in f:lines() do
        local u = l:match("^Uid:%s+(%d+)")
        if u then f:close() return u end
    end
    f:close()
end

-- socket path exists and, under /run/user/<n>/, belongs to this uid (root's bus address leaks through runuser)
local function usable(p)
    if not p or p == "" or not utils.file_info(p) then return false end
    local n = p:match("^/run/user/(%d+)/")
    return n == nil or n == uid()
end

local ok = false
local addr = os.getenv("DBUS_SESSION_BUS_ADDRESS")
if addr and addr ~= "" then
    local first = addr:match("^([^;]*)")
    local p = first:match("^unix:path=([^,]+)")
    if p then ok = usable(p) else ok = first:match("^unix:abstract=") ~= nil end
else
    local run = os.getenv("XDG_RUNTIME_DIR")
    ok = run ~= nil and run ~= "" and usable(run .. "/bus")
end
if ok then
    mp.commandv("load-script", "/usr/lib/h96/mpv-mpris/mpris.so")
    mp.msg.verbose("MPRIS plugin loaded")
else
    mp.msg.verbose("no usable session bus: MPRIS plugin not loaded")
end
