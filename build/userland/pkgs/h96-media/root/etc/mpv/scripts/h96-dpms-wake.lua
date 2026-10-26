-- h96-dpms-wake: playback started while the X11 display sleeps (DPMS off) wakes it; video tracks only
local function run(args)
    return mp.command_native({name = "subprocess", args = args, capture_stdout = true,
                              capture_stderr = true, playback_only = false})
end

local function wake()
    if not os.getenv("DISPLAY") or os.getenv("WAYLAND_DISPLAY") then return end
    if mp.get_property("vid") == "no" or mp.get_property_native("current-tracks/video") == nil then return end
    local q = run({"xset", "q"})
    if not q or q.status ~= 0 or not q.stdout then return end
    local state = q.stdout:match("Monitor is (%a+)")
    if state and state ~= "On" then
        run({"xset", "dpms", "force", "on"})
        mp.msg.info("display was " .. state .. " (DPMS); woken for playback")
    end
end

mp.register_event("file-loaded", wake)
