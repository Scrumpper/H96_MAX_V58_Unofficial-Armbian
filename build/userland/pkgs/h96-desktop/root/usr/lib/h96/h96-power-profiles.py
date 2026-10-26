#!/usr/bin/env python3
"""
h96-power-profiles: power-profiles-daemon replacement for H96 Max V58.

Claims org.freedesktop.UPower.PowerProfiles (GNOME 50) and
net.hadess.PowerProfiles (legacy compat) on the system bus.
power-profiles-daemon.service must be masked; upowerd runs normally.
Profile switches and holds: root, or a caller in the active local x11/wayland
session; everything else gets AccessDenied (no password prompt).
Hold release: the bus name that made the hold, or root.
Sole owner of CPU governor, CPU floor and ceiling (tune.conf big-core cap outside performance,
power-saver caps per cluster), deep cpuidle, GPU range and DDR devfreq floor per profile.
"""
import glob, os, sys

try:
    import dbus, dbus.service, dbus.mainloop.glib
    from gi.repository import GLib
except ImportError:
    sys.exit("h96-power-profiles: missing python3-dbus or python3-gi")

PP_BUS    = "org.freedesktop.UPower.PowerProfiles"
PP_PATH   = "/org/freedesktop/UPower/PowerProfiles"
LEG_BUS   = "net.hadess.PowerProfiles"
LEG_PATH  = "/net/hadess/PowerProfiles"

TUNE_CONF = "/etc/h96-tune.conf"   # BIG_MAX_FREQ_MHZ: big-core cap in balanced and power-saver
CPU_SYS = "/sys/devices/system/cpu"


def _big_policies():
    """Policies of the CPUs with the highest cpu_capacity (A76; numbering differs per build)."""
    caps = {}
    for pol in glob.glob(f"{CPU_SYS}/cpufreq/policy*"):
        try:
            cpu = open(f"{pol}/related_cpus").read().split()[0]
            caps[os.path.basename(pol)] = int(open(f"{CPU_SYS}/cpu{cpu}/cpu_capacity").read())
        except (OSError, ValueError, IndexError):
            continue
    top = max(caps.values(), default=0)
    big = {p for p, c in caps.items() if c == top}
    return big if top and len(big) < len(caps) else {"policy1", "policy3"}


BIG_POLICIES = _big_policies()


def _tune_cap_khz():
    """BIG_MAX_FREQ_MHZ from tune.conf (key=value, not sourced) when ENABLED=1 and > 0, else None."""
    kv = {}
    try:
        for ln in open(TUNE_CONF):
            k, sep, v = ln.strip().partition("=")
            if sep and not k.startswith("#"):
                kv[k.strip()] = v.strip().strip('"\'')
    except OSError:
        return None
    try:
        mhz = int(kv.get("BIG_MAX_FREQ_MHZ", "0"))
    except ValueError:
        return None
    return mhz * 1000 if kv.get("ENABLED") == "1" and mhz > 0 else None

PROFILE_GOVERNORS = {
    "performance": {"big": "performance", "little": "schedutil"},
    "balanced":    {"big": "schedutil",   "little": "schedutil"},
    "power-saver": {"big": "schedutil",   "little": "schedutil"},
}

# CPU floor in kHz (nearest OPP >= value); 0 = lowest OPP. The DTB carries 408-1008 MHz OPPs for power-saver only.
CPU_MIN_FLOOR = {"performance": 1200000, "balanced": 1200000, "power-saver": 408000}
# CPU ceiling in kHz per cluster (nearest OPP <= value); power-saver: 4K60 with 0 drops at lowest load (re-test 2026-10-21)
CPU_MAX_CAP = {"power-saver": {"big": 1800000, "little": 1416000}}
# Deep cpuidle states (cpu-sleep) only in power-saver; they cost GPU-bound throughput.
DEEP_IDLE = {"power-saver"}
# DDR (dmc devfreq, 6.12): performance pins min_freq to max_freq, other profiles restore lowest OPP; absent on 6.1
DMC_DEVFREQ = "/sys/class/devfreq/dmc"

# GPU (Mali-G610 / panthor devfreq) per-profile frequency ceiling in Hz, mapped to
# the nearest available opp <= cap. Performance unlocks the full 1000MHz; balanced
# keeps the stock 800MHz; power-saver caps low. simple_ondemand with a low floor
# lets the GPU idle down at rest while the thermal cooling device still throttles.
# The BSP 'performance' devfreq governor does not pin the clock; raise max_freq instead.
GPU_DEVFREQ = "/sys/class/devfreq/fb000000.gpu"
GPU_MAX_CAP = {"performance": 10**12, "balanced": 800000000, "power-saver": 600000000}
# per-profile frequency floor: performance keeps a 600MHz floor so bursty desktop
# work (window drags) never waits on the 300MHz->up ramp; others idle fully down
GPU_MIN_FLOOR = {"performance": 600000000, "balanced": 0, "power-saver": 0}


def _set_gpu(profile):
    g = GPU_DEVFREQ
    if not os.path.isdir(g):
        return
    try:
        with open(f"{g}/available_frequencies") as f:
            avail = sorted(int(x) for x in f.read().split() if x.isdigit())
    except OSError:
        return
    if not avail:
        return
    cap = GPU_MAX_CAP.get(profile, avail[-1])
    target_max = max([a for a in avail if a <= cap] or [avail[0]])

    def _w(path, val):
        try:
            with open(path, "w") as f:
                f.write(str(val))
        except OSError:
            pass
    floor_cap = min(GPU_MIN_FLOOR.get(profile, 0), target_max)
    target_min = max([a for a in avail if a <= floor_cap] or [avail[0]])
    _w(f"{g}/governor", "simple_ondemand")
    _w(f"{g}/polling_interval", 16)     # BSP default 50ms is too slow for a drag burst
    _w(f"{g}/min_freq", target_min)     # write floor first, avoids min>max transient
    _w(f"{g}/max_freq", target_max)

def _set_ddr(profile):
    d = DMC_DEVFREQ
    if not os.path.isdir(d):
        return
    try:
        if profile == "performance":
            target = int(open(f"{d}/max_freq").read())
        else:
            target = min(int(x) for x in open(f"{d}/available_frequencies").read().split() if x.isdigit())
    except (OSError, ValueError):
        return
    _wr(f"{d}/min_freq", target)


_PROFILES = [
    {"Profile": "power-saver", "Driver": "h96-tune", "CpuDriver": "cpufreq"},
    {"Profile": "balanced",    "Driver": "h96-tune", "CpuDriver": "cpufreq"},
    {"Profile": "performance", "Driver": "h96-tune", "CpuDriver": "cpufreq"},
]

# boot default: balanced, so the GPU floor is 0 and it idles to 300MHz at rest;
# the performance profile's 600MHz floor engages only when the user toggles it
_active_profile = "balanced"
_base_profile = "balanced"     # user's choice; returns when the last hold ends
_holds = {}                    # cookie -> {profile, reason, app, sender, uid, watch}
_next_cookie = 1
_bus = None
_objs = []                     # (object, interface) pairs for change signals


def _tune_schedutil(pol):
    """Make schedutil climb to max clock sooner after a sudden load.

    Measured on hardware: target_load is the lever that matters here, not
    rate_limit_us (dropping rate_limit_us 20x changed ramp time by 6%, while
    80 -> 75 took it from 49.0 ms to 39.9 ms). 75 is used rather than 70
    because 70 had a better median but a much worse tail.

    These reset every time the governor is re-selected, so they are applied
    here rather than written once at build time. Failure is ignored: an older
    kernel without these tunables must not stop the profile from applying.
    """
    base = f"{CPU_SYS}/cpufreq/{pol}/schedutil"
    for name, value in (("rate_limit_us", "2000"), ("target_load", "75")):
        try:
            with open(f"{base}/{name}", "w") as f:
                f.write(value)
        except OSError:
            pass


def _wr(path, val):
    try:
        with open(path, "w") as f:
            f.write(str(val))
    except OSError:
        pass


def _set_cpu_idle(profile):
    """Deep idle states (index >= 1; state0 is WFI) on in DEEP_IDLE profiles, off elsewhere."""
    flag = "0" if profile in DEEP_IDLE else "1"
    for path in glob.glob(f"{CPU_SYS}/cpu[0-9]*/cpuidle/state[1-9]*/disable"):
        _wr(path, flag)


def _set_cpu_floor(profile):
    floor = CPU_MIN_FLOOR.get(profile, 1200000)
    for pol in glob.glob(f"{CPU_SYS}/cpufreq/policy*"):
        try:
            with open(f"{pol}/scaling_available_frequencies") as f:
                avail = sorted(int(x) for x in f.read().split() if x.isdigit())
        except OSError:
            continue
        if avail:
            _wr(f"{pol}/scaling_min_freq", min([a for a in avail if a >= floor] or [avail[-1]]))


def _set_governors(profile):
    global _active_profile
    _active_profile = profile
    _set_gpu(profile)   # GPU ceiling follows the profile; CPU handled below
    _set_ddr(profile)
    _set_cpu_idle(profile)
    _set_cpu_floor(profile)
    govs = PROFILE_GOVERNORS.get(profile, PROFILE_GOVERNORS["balanced"])
    for path in glob.glob(f"{CPU_SYS}/cpufreq/policy*/scaling_governor"):
        pol = os.path.basename(os.path.dirname(path))
        gov = govs["big"] if pol in BIG_POLICIES else govs["little"]
        try:
            with open(path, "w") as f:
                f.write(gov)
            if gov == "schedutil":
                _tune_schedutil(pol)
        except OSError:
            pass
    _set_cpu_max(profile)


def _set_cpu_max(profile):
    """Every apply sets scaling_max_freq: top OPP, except big cores capped by tune.conf outside performance
    and per-cluster caps of CPU_MAX_CAP (lower one wins)."""
    tune = None if profile == "performance" else _tune_cap_khz()
    pcap = CPU_MAX_CAP.get(profile, {})
    for pol in glob.glob(f"{CPU_SYS}/cpufreq/policy*"):
        try:
            with open(f"{pol}/scaling_available_frequencies") as f:
                avail = sorted(int(x) for x in f.read().split() if x.isdigit())
        except OSError:
            continue
        if not avail:
            continue
        target = avail[-1]
        big = os.path.basename(pol) in BIG_POLICIES
        cap = min([c for c in ((tune if big else None), pcap.get("big" if big else "little")) if c] or [0])
        if cap:
            target = max([a for a in avail if a <= cap] or [avail[0]])   # nearest OPP <= cap
        try:   # floor may sit above a low cap: lower it first
            if int(open(f"{pol}/scaling_min_freq").read()) > target:
                _wr(f"{pol}/scaling_min_freq", target)
        except (OSError, ValueError):
            pass
        _wr(f"{pol}/scaling_max_freq", target)


def _dbus_profiles():
    return dbus.Array([
        dbus.Dictionary({dbus.String(k): dbus.String(v) for k, v in p.items()}, signature="sv")
        for p in _PROFILES
    ], signature="a{sv}")


def _pp_props():
    return {
        "ActiveProfile":        dbus.String(_active_profile),
        "Profiles":             _dbus_profiles(),
        "PerformanceDegraded":  dbus.String(""),
        "PerformanceInhibited": dbus.String(""),
        "ActiveProfileHolds":   dbus.Array([
            dbus.Dictionary({"ApplicationId": dbus.String(h["app"]),
                             "Profile": dbus.String(h["profile"]),
                             "Reason": dbus.String(h["reason"])}, signature="sv")
            for h in _holds.values()], signature="a{sv}"),
        "Version":              dbus.String("0.20"),
        "Actions":              dbus.Array([], signature="s"),
    }


def _effective():
    profs = {h["profile"] for h in _holds.values()}
    if "power-saver" in profs:
        return "power-saver"
    if "performance" in profs:
        return "performance"
    return _base_profile


def _notify():
    if _effective() != _active_profile:
        _set_governors(_effective())
    ch = {"ActiveProfile": dbus.String(_active_profile),
          "ActiveProfileHolds": _pp_props()["ActiveProfileHolds"]}
    for obj, iface in _objs:
        obj.PropertiesChanged(iface, ch, [])


def _caller_uid(sender):
    dbi = dbus.Interface(_bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus"),
                         "org.freedesktop.DBus")
    return int(dbi.GetConnectionUnixUser(sender))


def _hold(profile, reason, app, sender):
    global _next_cookie
    if profile not in ("performance", "power-saver"):
        raise dbus.exceptions.DBusException(
            "Only profiles 'performance' and 'power-saver' can be a hold",
            name="org.freedesktop.UPower.PowerProfiles.InvalidArgs")
    cookie = _next_cookie
    _next_cookie += 1

    # caller exit or crash drops its bus name; release its holds then
    def _gone(owner, c=cookie):
        if not owner:
            _release(c)
    try:
        uid = _caller_uid(sender) if sender else None
    except dbus.exceptions.DBusException:
        uid = None
    _holds[cookie] = {"profile": str(profile), "reason": str(reason), "app": str(app),
                      "sender": str(sender or ""), "uid": uid, "watch": None}
    if sender:
        _holds[cookie]["watch"] = _bus.watch_name_owner(sender, _gone)
    print(f"h96-power-profiles: hold {cookie} {profile} by {app} ({sender} uid {uid})", flush=True)
    _notify()
    return dbus.UInt32(cookie)


def _release(cookie, notify=True):
    h = _holds.pop(int(cookie), None)
    if h is None:
        return
    if h["watch"] is not None:
        h["watch"].cancel()
    print(f"h96-power-profiles: release {cookie}", flush=True)
    for obj, _ in _objs:
        obj.ProfileReleased(dbus.UInt32(cookie))
    if notify:
        _notify()


def _release_checked(cookie, sender):
    """Release only by the bus name that made the hold, or root."""
    h = _holds.get(int(cookie))
    if h is None:
        return
    if sender and sender != h["sender"]:
        try:
            uid = _caller_uid(sender)
        except dbus.exceptions.DBusException:
            uid = None
        if uid != 0:
            print(f"h96-power-profiles: denied release {cookie} for {sender} (uid {uid})", flush=True)
            raise dbus.exceptions.DBusException(
                f"Hold {int(cookie)} was not requested by this sender",
                name="org.freedesktop.DBus.Error.AccessDenied")
    _release(cookie)


def _user_set(profile):
    """Explicit profile change drops all holds, as power-profiles-daemon does."""
    global _base_profile
    _base_profile = str(profile)
    for c in list(_holds):
        _release(c, notify=False)
    _set_governors(_base_profile)
    _notify()


ACT_SWITCH = "switch-profile"
ACT_HOLD   = "hold-profile"
GRAPHICAL  = {"x11", "wayland"}
LOGIN1     = "org.freedesktop.login1"


def _deny(err, msg):
    err(dbus.exceptions.DBusException(msg, name="org.freedesktop.DBus.Error.AccessDenied"))


def _props(path, iface):
    return _bus.get_object(LOGIN1, path).GetAll(iface, dbus_interface="org.freedesktop.DBus.Properties")


def _graphical_session_of(pid, uid):
    """Caller's own logind session; for user-manager services (plasmashell) the user's display session."""
    mgr = dbus.Interface(_bus.get_object(LOGIN1, "/org/freedesktop/login1"), LOGIN1 + ".Manager")
    try:
        spath = mgr.GetSessionByPID(dbus.UInt32(pid))
    except dbus.exceptions.DBusException:
        spath = _props(mgr.GetUserByPID(dbus.UInt32(pid)), LOGIN1 + ".User")["Display"][1]
        if spath == "/":
            return None
    s = _props(spath, LOGIN1 + ".Session")
    if (int(s["User"][0]) == uid and str(s["Type"]) in GRAPHICAL
            and bool(s["Active"]) and not bool(s["Remote"])):
        return str(s["Id"])
    return None


def _authorize(sender, action, ok, err):
    """Allow root, or a caller in an active local x11/wayland session; deny anything else."""
    try:
        dbi = dbus.Interface(_bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus"),
                             "org.freedesktop.DBus")
        uid = int(dbi.GetConnectionUnixUser(sender))
        if uid == 0:
            return ok()
        pid = int(dbi.GetConnectionUnixProcessID(sender))
        sid = _graphical_session_of(pid, uid)
    except dbus.exceptions.DBusException as e:
        print(f"h96-power-profiles: session lookup failed for {sender}: {e}", flush=True)
        sid = None
    if sid is None:
        print(f"h96-power-profiles: denied {action} for {sender}", flush=True)
        return _deny(err, f"{action} needs root or the active desktop session")
    ok()


def _set_property(iface, prop, value, sender, ok, err):
    if prop != "ActiveProfile":
        return ok()
    if str(value) not in {p["Profile"] for p in _PROFILES}:
        return err(dbus.exceptions.DBusException(
            f"Invalid profile '{value}'", name="org.freedesktop.DBus.Error.InvalidArgs"))

    def _apply():
        _user_set(value)
        print(f"h96-power-profiles: profile -> {_active_profile}", flush=True)
        ok()
    _authorize(sender, ACT_SWITCH, _apply, err)


def _hold_checked(profile, reason, app, sender, ok, err):
    if profile not in ("performance", "power-saver"):
        return err(dbus.exceptions.DBusException(
            "Only profiles 'performance' and 'power-saver' can be a hold",
            name="org.freedesktop.UPower.PowerProfiles.InvalidArgs"))
    _authorize(sender, ACT_HOLD, lambda: ok(_hold(profile, reason, app, sender)), err)


PP_XML = """<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
  "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.UPower.PowerProfiles">
    <method name="HoldProfile">
      <arg name="profile" type="s" direction="in"/>
      <arg name="reason" type="s" direction="in"/>
      <arg name="application_id" type="s" direction="in"/>
      <arg name="cookie" type="u" direction="out"/>
    </method>
    <method name="ReleaseProfile"><arg name="cookie" type="u" direction="in"/></method>
    <signal name="ProfileReleased"><arg name="cookie" type="u"/></signal>
    <property name="ActiveProfile" type="s" access="readwrite"/>
    <property name="PerformanceInhibited" type="s" access="read"/>
    <property name="PerformanceDegraded" type="s" access="read"/>
    <property name="Profiles" type="aa{sv}" access="read"/>
    <property name="Actions" type="as" access="read"/>
    <property name="ActiveProfileHolds" type="aa{sv}" access="read"/>
    <property name="Version" type="s" access="read"/>
  </interface>
</node>"""

LEG_XML = """<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
  "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="net.hadess.PowerProfiles">
    <method name="HoldProfile">
      <arg name="parameters" type="a{sv}" direction="in"/>
      <arg name="cookie" type="u" direction="out"/>
    </method>
    <method name="ReleaseProfile"><arg name="cookie" type="u" direction="in"/></method>
    <signal name="ProfileReleased"><arg name="cookie" type="u"/></signal>
    <property name="ActiveProfile" type="s" access="readwrite"/>
    <property name="PerformanceInhibited" type="s" access="read"/>
    <property name="PerformanceDegraded" type="s" access="read"/>
    <property name="Profiles" type="aa{sv}" access="read"/>
    <property name="Actions" type="as" access="read"/>
    <property name="ActiveProfileHolds" type="aa{sv}" access="read"/>
    <property name="Version" type="s" access="read"/>
  </interface>
</node>"""


class PowerProfilesUPower(dbus.service.Object):
    def __init__(self, conn, path):
        super().__init__(conn, path)
        _set_governors(_active_profile)
        print(f"h96-power-profiles: started, active={_active_profile}", flush=True)

    @dbus.service.method("org.freedesktop.DBus.Introspectable", out_signature="s")
    def Introspect(self): return PP_XML

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop): return self.GetAll(iface).get(prop, dbus.String(""))

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv", out_signature="",
                         sender_keyword="sender", async_callbacks=("ok", "err"))
    def Set(self, iface, prop, value, sender=None, ok=None, err=None):
        _set_property(iface, prop, value, sender, ok, err)

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface): return _pp_props()

    @dbus.service.signal("org.freedesktop.DBus.Properties", signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated): pass

    @dbus.service.method("org.freedesktop.UPower.PowerProfiles", in_signature="sss", out_signature="u",
                         sender_keyword="sender", async_callbacks=("ok", "err"))
    def HoldProfile(self, profile, reason, application_id, sender=None, ok=None, err=None):
        _hold_checked(profile, reason, application_id, sender, ok, err)

    @dbus.service.method("org.freedesktop.UPower.PowerProfiles", in_signature="u", out_signature="",
                         sender_keyword="sender")
    def ReleaseProfile(self, cookie, sender=None): _release_checked(cookie, sender)

    @dbus.service.signal("org.freedesktop.UPower.PowerProfiles", signature="u")
    def ProfileReleased(self, cookie): pass


class PowerProfilesLegacy(dbus.service.Object):
    @dbus.service.method("org.freedesktop.DBus.Introspectable", out_signature="s")
    def Introspect(self): return LEG_XML

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop): return self.GetAll(iface).get(prop, dbus.String(""))

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv", out_signature="",
                         sender_keyword="sender", async_callbacks=("ok", "err"))
    def Set(self, iface, prop, value, sender=None, ok=None, err=None):
        _set_property(iface, prop, value, sender, ok, err)

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface): return _pp_props()

    @dbus.service.signal("org.freedesktop.DBus.Properties", signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated): pass

    @dbus.service.method("net.hadess.PowerProfiles", in_signature="a{sv}", out_signature="u",
                         sender_keyword="sender", async_callbacks=("ok", "err"))
    def HoldProfile(self, parameters, sender=None, ok=None, err=None):
        _hold_checked(parameters.get("Profile", ""), parameters.get("Reason", ""),
                      parameters.get("ApplicationId", ""), sender, ok, err)

    @dbus.service.method("net.hadess.PowerProfiles", in_signature="u", out_signature="",
                         sender_keyword="sender")
    def ReleaseProfile(self, cookie, sender=None): _release_checked(cookie, sender)

    @dbus.service.signal("net.hadess.PowerProfiles", signature="u")
    def ProfileReleased(self, cookie): pass


def main():
    global _bus
    # --apply <profile>: write the profile's sysfs state and exit (unit ExecStartPre, before the desktop)
    if len(sys.argv) == 3 and sys.argv[1] == "--apply":
        if sys.argv[2] not in {p["Profile"] for p in _PROFILES}:
            sys.exit(f"h96-power-profiles: unknown profile {sys.argv[2]}")
        _set_governors(sys.argv[2])
        return
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = _bus = dbus.SystemBus()
    _pp_name  = dbus.service.BusName(PP_BUS,  bus)
    _leg_name = dbus.service.BusName(LEG_BUS, bus)
    _objs.append((PowerProfilesUPower(bus, PP_PATH), PP_BUS))
    _objs.append((PowerProfilesLegacy(bus, LEG_PATH), LEG_BUS))
    print("h96-power-profiles: running", flush=True)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
