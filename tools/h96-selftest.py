#!/usr/bin/env python3
"""h96-selftest: read-only health checks for H96 MAX V58 images.

Subcommands: boot, hw, invariants, report, self-test; media, menus, soak are stubs.
Standard library only; syntax kept to Python 3.11.
Read-only: the only file it can create is a report under /tmp (report --out).
"""

import argparse
import datetime
import fnmatch
import glob
import json
import os
import re
import socket
import subprocess
import sys

VERSION = "0.1.0"
PASS, WARN, FAIL, INFO, SKIP = "PASS", "WARN", "FAIL", "INFO", "SKIP"
ORDER = {FAIL: 0, WARN: 1, PASS: 2, INFO: 3, SKIP: 4}
STUB_MSG = "not implemented in this build"
EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_STUB = 0, 1, 2, 3

# Child processes: no Mesa shader cache writes, no pyc writes, C locale.
CHILD_ENV_EXTRA = {
    "MESA_SHADER_CACHE_DISABLE": "true",
    "MESA_GLSL_CACHE_DISABLE": "true",
    "PYTHONDONTWRITEBYTECODE": "1",
    "LANG": "C",
    "LC_ALL": "C",
    "SYSTEMD_PAGER": "",
    "SYSTEMD_COLORS": "0",
}

# Journal and dmesg allowlist for this release (7.2 baseline, draft for owner review).
# kind "ignore": known benign probe noise. kind "warn": known open item, counted as WARN.
# Lines matching no entry count against the error budget (budget is zero).
ALLOWLIST = [
    # BSP 6.1 probe noise, present on every boot of 7.x
    ("bsp-probe-rk806", "ignore", r"^rk806 spi\d+\.\d+: no (sleep|reset|power-off|dvs)-setting|^rk806 spi\d+\.\d+: no power-off pinctrl state"),
    ("bsp-probe-scmi", "ignore", r"^arm-scmi firmware:scmi: Failed\. SCMI protocol \d+ not active"),
    ("bsp-probe-cacheinfo", "ignore", r"^Early cacheinfo failed, ret = -22"),
    ("bsp-probe-rknpu-region", "ignore", r"^RKNPU [0-9a-f]+\.npu: (error -EBUSY: )?can't request region for resource"),
    ("bsp-probe-rkvdec-shared-niu", "ignore", r"^mpp_rkvdec2 [0-9a-f]+\.rkvdec-core: shared_niu_[ah] is not found"),
    ("bsp-probe-remotectl", "ignore", r"^\.\. rk pwm remotectl v[\d.]+ init"),
    ("bt-le-cmd-enosys", "ignore", r"^Bluetooth: hci\d+: Opcode 0x2037 failed: -38"),
    # bluetoothd: controller rejects LE privacy mode at power-on
    ("bt-privacy-rejected", "ignore", r"^Failed to set privacy: Rejected \(0x0b\)$"),
    # bluetoothd: adapter powered down before adv monitor manager exists (early boot race)
    ("bt-adv-monitor-race", "ignore", r"^src/adv_monitor\.c:btd_adv_monitor_power_down\(\) Unexpected NULL btd_adv_monitor_manager object upon power down$"),
    ("bsp-probe-gmac", "ignore", r"^rk_gmac-dwmac [0-9a-f]+\.ethernet: (cannot get clock|Can not read property: rx_delay|set rx_delay to)"),
    ("bsp-probe-vop2-opp", "ignore", r"^rockchip-vop2 [0-9a-f]+\.vop: failed to init opp info"),
    ("bsp-probe-dfi", "ignore", r"^rockchip-dfi [0-9a-f]+\.dfi: Failed to get pclk_ddr_mon"),
    ("bsp-probe-rkvdec-niu", "ignore", r"^rkvdec2_init:\d+: No niu [ah]clk reset resource define"),
    ("bsp-probe-rkvenc-opp", "ignore", r"(rkvenc_init:\d+: failed to add venc devfreq|mpp_rkvenc2 [0-9a-f]+\.rkvenc-core: failed to init.?opp)"),
    ("bsp-probe-npu-debugfs", "ignore", r"^debugfs: Directory '[0-9a-f]+\.npu-rknpu' with parent 'vdd_npu_s0' already present"),
    ("bsp-probe-sdhci-hs200", "ignore", r"^sdhci-dwcmshc [0-9a-f]+\.mmc: Can't reduce the clock below 52MHz in HS200/HS400"),
    # 6.12 kernel probe noise (8.0 RC boot 2026-10-22, post-flash/02-selftest-boot-errlines.txt)
    # vendor DT drm-logo and drm-cubic-lut nodes left at size 0 by boot loader: nothing to reserve
    ("612-reserved-mem-empty", "ignore", r"^OF: reserved mem: Reserved memory: failed to reserve memory for node 'drm-(logo|cubic-lut)@0': base 0x0+, size 0 MiB$"),
    # vendor cpufreq probes before CPU clock provider; deferred probe binds policies (hw check reads them)
    ("612-cpufreq-clk-defer", "ignore", r"^(cpu cpu0: (failed to get cpu0 clk|cpu0 clk is not ready)|failed to init cpufreq)$"),
    # BT wake_host pin is IRQ input in board DT; vendor rfkill driver tries output direction once, BT works
    ("612-bt-wake-host-irq", "ignore", r"^gpio-\d+ \(BT,wake_host\): gpiod_direction_output: tried to set a GPIO tied to an IRQ as output$"),
    # optional DDR DVFS inputs absent (no VOP latency table, BL31 without stall time call); DVFS runs (8 h soak)
    ("612-dmc-optional", "ignore", r"^rockchip-dmc dmc: (failed to get vop pn to msch rl|Current ATF unsupported get_stall_time)$"),
    # MPP client probe deferral, repeats until each codec core binds
    ("bsp-probe-mpp-defer", "ignore", r"^mpp_platform: client \d+ driver is not ready!?$"),
    # hot-unplug of a USB pad
    ("usb-pad-unplug", "ignore", r"^xpad \S+: xpad_try_sending_next_out_packet - usb_submit_urb failed with result -19"),
    # runtime items that are known and open on 7.2
    ("vop2-cursor-invisible", "warn", r"^\[drm:vop2_plane_atomic_check\] \*ERROR\* Cluster\d-win\d is invisible"),
    ("gpu-job-fault", "warn", r"^(panthor [0-9a-f]+\.gpu: \[drm\] \*ERROR\* Unhandled Page fault in AS\d+|raw fault status: 0x|decoded fault status: |exception type 0x|access type 0x|source id 0x)"),
    ("row24-hdmi0p-recover", "warn", r"^spa\.alsa: hdmi:\d+p: (recover from error state|snd_pcm_mmap_begin error)"),
    ("bt-peer-gone", "warn", r"(src/profile\.c:(record_cb|ext_io_disconnected)\(\) Unable to get|pw\.node: \(bluez_(input|output)\.\S+\) \S+ -> error|node_set_param\(Spa:Enum:ParamId:PortConfig\) failed: Input/output error)"),
    ("pulse-profile-mismatch", "warn", r"^mod\.protocol-pulse: 0x[0-9a-f]+: card \d+ port \d+ profiles inconsistent"),
    ("desktop-eds-missing", "warn", r"Unit evolution-source-registry\.service not found"),
]
_ALLOW_RE = [(i, k, re.compile(p)) for i, k, p in ALLOWLIST]

TAINT_FLAGS = [
    (0, "P", "proprietary module"), (1, "F", "forced module load"), (2, "S", "out-of-spec system"),
    (3, "R", "forced module unload"), (4, "M", "machine check"), (5, "B", "bad page"),
    (6, "U", "user taint"), (7, "D", "kernel died (oops)"), (8, "A", "ACPI table override"),
    (9, "W", "kernel warning"), (10, "C", "staging driver"), (11, "I", "firmware workaround"),
    (12, "O", "out-of-tree module"), (13, "E", "unsigned module"), (14, "L", "soft lockup"),
    (15, "K", "live patched"), (16, "X", "auxiliary"), (17, "T", "randstruct"), (18, "N", "test"),
]
TAINT_FAIL_BITS = {4, 5, 7, 9, 14}

# Invariant scan scope: every file under SCAN_DIRS, plus every file under H96_ROOTS whose path
# below that root has a component containing "h96" (covers /opt/h96-*, units, drop-ins, READMEs).
# 8.0 packages install to /usr/bin, /usr/sbin, /usr/lib/h96 and /usr/share/h96; files they own are scanned too.
SCAN_DIRS = ["/usr/local/bin", "/usr/local/sbin", "/usr/local/lib/h96", "/usr/lib/h96"]
SCAN_GLOBS = ["/usr/local/lib/*.py", "/usr/local/lib/steam-arm-*"]
H96_ROOTS = ["/etc", "/usr/lib/systemd", "/lib/systemd", "/usr/lib/sysctl.d", "/usr/lib/udev", "/usr/local/share",
             "/usr/local/lib", "/usr/share/h96", "/opt", "/usr/bin", "/usr/sbin"]
H96_PKG_LISTS = "/var/lib/dpkg/info/h96-*.list"
SCAN_MAX_BYTES = 4 * 1024 * 1024
# Files written at run time with the local account name by design; excluded from the username and
# home-path rules and reported as INFO rows.
RUNTIME_STATE = {
    "/etc/lightdm/lightdm.conf.d/70-h96-autologin.conf": "written at run time by h96-autologin-setup",
}
# Files the Steam ARM installer generates with the local account name baked in at install (for example
# steam-arm-compatmap); published installer output, accepted like RUNTIME_STATE.
INSTALLER_STATE = ["/usr/local/bin/steam-arm*", "/usr/local/sbin/steam-arm*", "/usr/local/lib/steam-arm*",
                   "/usr/local/share/steam-arm/*"]
INSTALLER_WHY = "generated by Steam ARM installer with local account name"


def runtime_state(path):
    """Reason a scanned file may hold the local account name by design, else None."""
    if path in RUNTIME_STATE:
        return RUNTIME_STATE[path]
    if any(fnmatch.fnmatchcase(path, g) for g in INSTALLER_STATE):
        return INSTALLER_WHY
    return None
# Optional private list of earlier box usernames; never published. One name per line, '#' comments.
DENYLIST_DEFAULT = "/etc/h96/selftest-denylist"
HOME_PLACEHOLDERS = {"user", "username", "yourname", "name", "you", "me", "foo"}

# sysctl.d search path in systemd-sysctl priority (same basename: earlier directory wins).
SYSCTL_DIRS = ["/etc/sysctl.d", "/run/sysctl.d", "/usr/local/lib/sysctl.d", "/usr/lib/sysctl.d", "/lib/sysctl.d"]
# Known writer of the 150 value: h96-perf-tune.sh section 3.
PERF_SWAPPINESS_FILES = {"90-h96-zram.conf"}

# Invariant patterns (module level so self-test can exercise them).
_ZONE = r"(UTC|GMT|Etc/[A-Za-z0-9_+-]+|[A-Z][A-Za-z_]+(/[A-Za-z_+-]+){1,2})"
RX_TZ = re.compile(r"set-timezone\s+[\"']?" + _ZONE + r"\b|"
                   r"zoneinfo/[A-Z][A-Za-z_]+(/[A-Za-z_+-]+){0,2}|"
                   r"echo\s+[\"']?" + _ZONE + r"[\"']?\s*>\s*/etc/timezone|"
                   r"\bTZ=[\"']?:?" + _ZONE + r"(?![\w/])")
RX_UID1000 = re.compile(r"/run/user/1000\b|\b1000:1000\b|chown\s+(-\S+\s+)*1000\b")
RX_HOME = re.compile(r"/home/([a-z_][a-z0-9_.-]*)/")
# Literal uid 1000 lookups: allowed by vision as run-time resolution, reported as WARN for review.
RX_UID1000_LOOKUP = re.compile(
    r"getent\s+passwd\s+[\"']?1000\b|\bid\s+-[a-zA-Z]*[nu][a-zA-Z]*\s+[\"']?1000\b|getpwuid\(\s*1000\s*\)"
    r"|(?i:\b\w*uid\b)[\"'}]?\s*(==|-eq|!=|-ne|=)\s*[\"']?1000\b"
    r"|\bid\s+-u\)?[\"']?\s*(==|-eq|!=|-ne|=)\s*[\"']?1000\b"
    r"|\b1000\s*(==|-eq|!=|-ne)\s*[\"']?\$?\{?\(?(?i:\w*uid|id\s+-u)")
# Session-based resolution: compliant.
RX_SESSION_RESOLVE = re.compile(r"\bSUDO_(USER|UID)\b|\bPKEXEC_UID\b|\bloginctl\s+(show-session|list-sessions|show-seat|show-user|list-users)"
                                r"|\blogname\b|ActiveSession|org\.freedesktop\.login1")
# cpu0 and policy0 always exist, so reads of them are presence probes, not core-layout assumptions.
RX_CPU = re.compile(
    r"taskset\s+(-[a-z-]+\s+)*-[a-z]*c[a-z]*\s+[\"']?\d"                     # taskset -c / -pc / -apc
    r"|taskset\s+(-p\s+)?(0x)?[0-9a-fA-F]+\s+\S"                              # taskset hex mask
    r"|\b(CPUAffinity|AllowedCPUs)\s*=\s*[\"']?\d"                             # systemd unit keys
    r"|(?i:\b\w*_cores|\bbig\w*|\blittle\w*)\s*=\s*[\"'\[({]?\s*\d+\s*([-,]\s*\d+)+"   # BIG=1-4, *_CORES="4-7"
    r"|(?=.*cpuset\.(effective_)?cpus)(?=.*(?<![\w.])\d+([-,]\d+)+(?![\w.]))"       # literal list into cpuset.cpus
    r"|sched_setaffinity\([^)]*([\[{]\s*\d|range\(\s*\d)"                      # literal affinity set
    r"|/sys/devices/system/cpu/cpu[1-9]\d*/|cpufreq/policy[1-9]"
    r"|\bcpu[1-7]-[1-7]\b|\bcpus?\s*=\s*[\"']?[0-7](-[0-7]|(,[0-7])+)")


class Result:
    def __init__(self, group, name, status, evidence):
        self.group, self.name, self.status, self.evidence = group, name, status, evidence

    def as_dict(self):
        return {"group": self.group, "check": self.name, "status": self.status, "evidence": self.evidence}


# ---------- helpers ----------

def run(cmd, timeout=20, extra_env=None):
    """Run a read-only command; return (rc, stdout, stderr). rc 127 when missing."""
    env = dict(os.environ)
    env.update(CHILD_ENV_EXTRA)
    if extra_env:
        env.update(extra_env)
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, env=env)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except FileNotFoundError:
        return 127, "", "not found: " + cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timeout after %ss: %s" % (timeout, " ".join(cmd))
    except OSError as e:
        return 126, "", str(e)


def which(name):
    for d in os.environ.get("PATH", "/usr/sbin:/usr/bin:/sbin:/bin").split(":") + ["/usr/sbin", "/sbin"]:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def read(path, default=None):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return default


def listdir(path):
    try:
        return os.listdir(path)
    except OSError:
        return []


def ranges(nums):
    nums = sorted(nums)
    out, start, prev = [], None, None
    for n in nums:
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            out.append(str(start) if start == prev else "%d-%d" % (start, prev))
            start = prev = n
    if start is not None:
        out.append(str(start) if start == prev else "%d-%d" % (start, prev))
    return ",".join(out)


def classify(msg):
    """Return (allow_id, kind) or (None, None) for one log message."""
    m = msg.strip()
    for aid, kind, rx in _ALLOW_RE:
        if rx.search(m):
            return aid, kind
    return None, None


def normalize(msg):
    s = re.sub(r"0x[0-9a-fA-F]+", "0xN", msg.strip())
    s = re.sub(r"\d+", "N", s)
    return s[:160]


def decode_taint(value):
    flags = []
    for bit, letter, desc in TAINT_FLAGS:
        if value & (1 << bit):
            flags.append((bit, letter, desc))
    return flags


def human_users():
    """Names of interactive accounts (uid 1000-59999) from /etc/passwd."""
    names = []
    for line in (read("/etc/passwd", "") or "").splitlines():
        parts = line.split(":")
        if len(parts) < 7:
            continue
        try:
            uid = int(parts[2])
        except ValueError:
            continue
        if 1000 <= uid < 60000 and parts[0] not in ("nobody",):
            names.append(parts[0])
    return names


def read_denylist(path):
    """Names from a private denylist file; missing file gives an empty list."""
    names = []
    for line in (read(path, "") or "").splitlines():
        s = line.split("#", 1)[0].strip()
        if s and re.match(r"^[a-z_][a-z0-9_.-]*$", s) and s != "root":
            names.append(s)
    return names


DENYLIST = []  # set from --denylist (or DENYLIST_DEFAULT) in main()
DENYLIST_SOURCE = "none"


def uid_name(uid):
    for line in (read("/etc/passwd", "") or "").splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[2] == str(uid):
            return parts[0]
    return None


# ---------- scrubber ----------

class Scrubber:
    """Replaces personal tokens in report text."""

    LINE_DROP = re.compile(
        r"(?i)(^|\s)(USER|LOGNAME|HOME|MAIL|SSH_CONNECTION|SSH_CLIENT|SUDO_USER|STEAM_USER|STEAMID|SteamUser|"
        r"STEAM_COMPAT_CLIENT_INSTALL_PATH|FEX_\w*HOME|DISPLAY_NAME)=\S*"
        r"|logged ?(in|on) as|login (user|name)|AccountName|PersonaName|steamid\d*|\"SteamID\""
        r"|(^|\s)(wpa-)?psk\s*[=:]|\bssid\b[\"']?\s*([=:]|[\"'])|\bpassword\s*[=:]"
        r"|(^|[\s;:'\"])(export\s+)?(STEAM|FEX|XDG)_[A-Za-z0-9_]*="
    )
    IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
    MAC = re.compile(r"\b[0-9A-Fa-f]{2}([:_-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}\b")
    # compressed form (contains ::) or full eight groups; optional prefix length and zone id
    IPV6 = re.compile(r"(?<![\w:.])(?:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?"
                      r"|(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4})(?:%[\w.-]+)?(?:/\d{1,3})?(?![\w:])")
    HOME = re.compile(r"/home/[^/\s'\"]+")

    def __init__(self, hostnames=None, users=None):
        if hostnames is None:
            hostnames = set()
            hn = socket.gethostname()
            if hn:
                hostnames.add(hn)
                hostnames.add(hn.split(".")[0])
            for p in ("/etc/hostname",):
                v = (read(p, "") or "").strip()
                if v:
                    hostnames.add(v)
        if users is None:
            users = set(human_users())
            for k in ("SUDO_USER", "USER", "LOGNAME"):
                v = os.environ.get(k)
                if v and v != "root":
                    users.add(v)
            users.update(DENYLIST)
        self.hostnames = sorted({h for h in hostnames if h and h not in ("localhost",) and len(h) > 1},
                                key=len, reverse=True)
        self.users = sorted({u for u in users if u and u != "root" and len(u) > 1}, key=len, reverse=True)

    @staticmethod
    def _ip_ok(ip):
        parts = ip.split(".")
        try:
            vals = [int(x) for x in parts]
        except ValueError:
            return True
        if any(v > 255 for v in vals):
            return True  # not an address (version strings and similar)
        a, b = vals[0], vals[1]
        private = a == 10 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254) \
            or (a == 100 and 64 <= b <= 127)
        return not private

    @staticmethod
    def _ip6_sub(m):
        a = m.group(0)
        low = a.lower()
        if not re.search(r"[0-9a-f]", low.replace("::", "")):
            return a  # bare "::" (C++ scope, prose)
        if low.startswith("2001:db8:") or low.startswith("2001:0db8:") or low.split("/")[0] in ("::1", "::"):
            return a  # documentation range and loopback
        return "<ip6>"

    def text(self, s):
        if not s:
            return s
        out = []
        for line in s.split("\n"):
            if self.LINE_DROP.search(line):
                out.append("[scrubbed line]")
                continue
            line = self.HOME.sub("/home/<user>", line)
            line = self.MAC.sub("<mac>", line)
            line = self.IPV6.sub(self._ip6_sub, line)
            line = self.IPV4.sub(lambda m: m.group(0) if self._ip_ok(m.group(0)) else "<lan>", line)
            for h in self.hostnames:
                line = re.sub(r"(?<![\w-])" + re.escape(h) + r"(?![\w-])", "<host>", line)
            for u in self.users:
                line = re.sub(r"(?<![\w-])" + re.escape(u) + r"(?![\w-])", "<user>", line)
            out.append(line)
        return "\n".join(out)

    def obj(self, o):
        if isinstance(o, str):
            return self.text(o)
        if isinstance(o, list):
            return [self.obj(x) for x in o]
        if isinstance(o, dict):
            return {k: self.obj(v) for k, v in o.items()}
        return o


# ---------- boot ----------

def journal_entries(priority=3):
    rc, out, err = run(["journalctl", "-b", "-p", str(priority), "-o", "json", "--no-pager",
                        "--output-fields=MESSAGE,SYSLOG_IDENTIFIER,_TRANSPORT,PRIORITY"], timeout=60)
    if rc not in (0, 1) or (rc == 1 and not out):
        return None, (err.strip() or "journalctl rc=%d" % rc)
    entries = []
    for line in out.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        msg = e.get("MESSAGE")
        if isinstance(msg, list):  # binary payload: journal gives a byte array
            try:
                msg = bytes(msg).decode("utf-8", "replace")
            except (TypeError, ValueError):
                msg = repr(msg)
        entries.append((e.get("SYSLOG_IDENTIFIER") or "?", e.get("_TRANSPORT") or "?", str(msg or "")))
    return entries, None


def budget_results(group, label, lines):
    """lines: list of (source, message). Returns results for allowlist classes and unknown lines."""
    res = []
    unknown, warn_classes, ignored = {}, {}, {}
    for src, msg in lines:
        aid, kind = classify(msg)
        if aid is None:
            key = "%s: %s" % (src, normalize(msg))
            unknown.setdefault(key, [0, msg.strip()[:200]])
            unknown[key][0] += 1
        elif kind == "warn":
            warn_classes[aid] = warn_classes.get(aid, 0) + 1
        else:
            ignored[aid] = ignored.get(aid, 0) + 1
    total_unknown = sum(v[0] for v in unknown.values())
    n = len(lines)
    if total_unknown == 0:
        res.append(Result(group, label + " budget", PASS,
                          "%d lines, 0 outside allowlist (budget 0)" % n))
    else:
        top = sorted(unknown.items(), key=lambda kv: -kv[1][0])[:8]
        ev = "%d lines, %d outside allowlist (budget 0) in %d distinct messages; top: " % (
            n, total_unknown, len(unknown))
        ev += " | ".join("%dx %s" % (v[0], k) for k, v in top)
        res.append(Result(group, label + " budget", FAIL, ev))
    if warn_classes:
        res.append(Result(group, label + " known open items", WARN,
                          ", ".join("%s=%d" % kv for kv in sorted(warn_classes.items()))))
    if ignored:
        res.append(Result(group, label + " allowlisted noise", INFO,
                          ", ".join("%s=%d" % kv for kv in sorted(ignored.items()))))
    return res


OOPS_PATS = [("Oops", r"Internal error: Oops|\bOops\b"), ("BUG", r"\bBUG: "), ("WARN", r"WARNING: CPU: \d+"),
             ("panic", r"Kernel panic"), ("hung_task", r"blocked for more than \d+ seconds"),
             ("soft_lockup", r"soft lockup"), ("call_trace", r"Call trace:")]


def oops_counts(text):
    return {k: len(re.findall(p, text)) for k, p in OOPS_PATS}


def ring_complete(dm):
    """True when the dmesg ring still holds the first boot line."""
    first = dm.lstrip().split("\n", 1)[0] if dm else ""
    return first.startswith("Booting Linux")


def check_boot():
    g = "boot"
    res = []
    bid = (read("/proc/sys/kernel/random/boot_id", "") or "").strip()
    up = (read("/proc/uptime", "0 0") or "0 0").split()[0]
    res.append(Result(g, "boot identity", INFO, "uname -r %s, uptime %ss, boot_id %s" % (
        os.uname().release, up.split(".")[0], bid[:8] or "?")))
    model = (read("/proc/device-tree/model", "") or "").strip("\x00\n ")
    res.append(Result(g, "device-tree model", INFO if model else WARN, model or "/proc/device-tree/model missing"))

    entries, err = journal_entries(3)
    if entries is None:
        res.append(Result(g, "journal p<=3 budget", SKIP, "journalctl unavailable: " + err[:160]))
    else:
        if os.geteuid() != 0:
            res.append(Result(g, "journal scope", WARN, "not root: journal may hide system entries"))
        res.extend(budget_results(g, "journal p<=3", [(e[0], e[2]) for e in entries]))

    rc, out, err = run(["systemctl", "--failed", "--no-legend", "--plain", "--no-pager"])
    if rc == 127:
        res.append(Result(g, "failed units", SKIP, "systemctl not found"))
    else:
        units = [l.split()[0] for l in out.splitlines() if l.strip()]
        res.append(Result(g, "failed units", FAIL if units else PASS,
                          ("failed: " + ", ".join(units)) if units else "systemctl --failed: 0 units"))
        # modules-load names its module in journal; failure here hides behind udev autoload (8.0 RC: bcmdhd EINVAL)
        rc2, act, _ = run(["systemctl", "show", "-p", "ActiveState,Result", "--value", "systemd-modules-load.service"])
        st = act.split()
        if rc2 == 0 and st:
            if "failed" in st:
                _, jl, _ = run(["journalctl", "-b", "-u", "systemd-modules-load.service", "-p", "3", "-o", "cat", "--no-pager", "-q"])
                res.append(Result(g, "modules-load", FAIL, "systemd-modules-load.service failed: "
                                  + ("; ".join(l.strip() for l in jl.splitlines() if l.strip())[:200] or "no journal line")))
            else:
                res.append(Result(g, "modules-load", PASS, "systemd-modules-load.service " + " ".join(st)))

    t = (read("/proc/sys/kernel/tainted", "") or "").strip()
    if not t.isdigit():
        res.append(Result(g, "kernel taint", SKIP, "/proc/sys/kernel/tainted unreadable"))
    else:
        v = int(t)
        flags = decode_taint(v)
        if v == 0:
            res.append(Result(g, "kernel taint", PASS, "/proc/sys/kernel/tainted = 0"))
        else:
            bad = [f for f in flags if f[0] in TAINT_FAIL_BITS]
            res.append(Result(g, "kernel taint", FAIL if bad else WARN, "tainted=%d flags %s" % (
                v, ", ".join("%s(%s)" % (f[1], f[2]) for f in flags))))

    rc, dm, err = run(["dmesg", "--notime"], timeout=20)
    complete = rc == 0 and ring_complete(dm)
    src = "dmesg ring"
    note = ""
    text = dm if rc == 0 else ""
    if not complete:
        why = "dmesg unreadable (%s)" % (err.strip() or "rc=%d" % rc)[:80] if rc != 0 else \
            "ring wrapped, starts: " + (dm.splitlines()[0][:60] if dm.strip() else "(empty)")
        rcj, kj, errj = run(["journalctl", "-k", "-b", "-o", "cat", "--no-pager"], timeout=60)
        if rcj == 0 and kj.strip():
            text, src, note = kj, "journalctl -k -b", "; " + why + ", counts from journal"
        else:
            text, note = (dm if rc == 0 else None), "; " + why + ", journalctl -k -b unavailable"
    if text is None:
        res.append(Result(g, "dmesg oops/BUG/WARN", SKIP, note.lstrip("; ")))
    else:
        counts = oops_counts(text)
        st = PASS
        if counts["Oops"] or counts["BUG"] or counts["panic"] or counts["soft_lockup"]:
            st = FAIL
        elif counts["WARN"] or counts["hung_task"] or counts["call_trace"] or (rc == 0 and not complete):
            st = WARN
        first = dm.splitlines()[0][:60] if (rc == 0 and dm) else "-"
        res.append(Result(g, "dmesg oops/BUG/WARN", st, "source %s: " % src + " ".join("%s=%d" % kv for kv in counts.items()) +
                          "; ring starts: " + first + note))
    if rc != 0:
        res.append(Result(g, "dmesg err budget", SKIP, "dmesg unreadable"))
    else:
        rc2, de, err2 = run(["dmesg", "--notime", "--level=emerg,alert,crit,err"], timeout=20)
        if rc2 == 0:
            res.extend(budget_results(g, "dmesg err", [("kernel", l) for l in de.splitlines() if l.strip()]))
        else:
            res.append(Result(g, "dmesg err budget", SKIP, (err2.strip() or "rc=%d" % rc2)[:120]))

    pst, perr = None, "/sys/fs/pstore not mounted"
    if os.path.isdir("/sys/fs/pstore"):
        try:
            pst = sorted(os.listdir("/sys/fs/pstore"))
        except OSError as e:
            perr = "/sys/fs/pstore unreadable: " + e.strerror
    if pst is None:
        res.append(Result(g, "pstore", SKIP, perr))
    else:
        res.append(Result(g, "pstore", WARN if pst else PASS,
                          ("records: " + ", ".join(pst[:6])) if pst else "/sys/fs/pstore empty"))

    wds = sorted(glob.glob("/dev/watchdog*"))
    rc, out, err = run(["systemctl", "show", "-p", "RuntimeWatchdogUSec", "--value"])
    rwd = out.strip() if rc == 0 else "?"
    armed = rwd not in ("", "0", "infinity", "?") and bool(wds)
    res.append(Result(g, "watchdog armed", PASS if armed else WARN,
                      "devices %s, RuntimeWatchdogUSec=%s" % (" ".join(wds) or "none", rwd)))
    return res


# ---------- hw ----------

def x_env():
    """Display environment for glxinfo: caller's DISPLAY, else lightdm root authority on :0."""
    if os.environ.get("DISPLAY"):
        return {}, "caller DISPLAY"
    for xa in ("/var/run/lightdm/root/:0", "/run/lightdm/root/:0"):
        if os.path.exists(xa) and os.access(xa, os.R_OK):
            return {"DISPLAY": ":0", "XAUTHORITY": xa}, "lightdm :0"
    return None, "no DISPLAY and no readable lightdm authority"


def check_hw():
    g = "hw"
    res = []
    # render nodes and drivers
    drivers = {}
    for rn in sorted(glob.glob("/sys/class/drm/renderD*")):
        drv = os.path.basename(os.path.realpath(os.path.join(rn, "device", "driver")))
        drivers[os.path.basename(rn)] = drv
    gpu = [n for n, d in drivers.items() if d in ("panthor", "panfrost")]
    res.append(Result(g, "GPU kernel driver", PASS if gpu else FAIL,
                      " ".join("%s=%s" % kv for kv in drivers.items()) or "no render nodes"))

    if which("glxinfo"):
        envx, how = x_env()
        if envx is None:
            res.append(Result(g, "GL renderer", SKIP, how))
        else:
            rc, out, err = run(["glxinfo", "-B"], timeout=20, extra_env=envx)
            m = re.search(r"OpenGL renderer string: (.*)", out)
            v = re.search(r"OpenGL version string: (.*)", out)
            if not m:
                res.append(Result(g, "GL renderer", WARN, "glxinfo (%s) rc=%d: %s" % (how, rc, (err.strip() or out.strip())[:140])))
            else:
                r = m.group(1).strip()
                st = FAIL if re.search(r"llvmpipe|softpipe|swrast", r, re.I) else (
                    PASS if re.search(r"Mali|Panfrost|panthor", r, re.I) else WARN)
                res.append(Result(g, "GL renderer", st, "renderer: %s; version: %s" % (r, v.group(1).strip() if v else "?")))
    else:
        res.append(Result(g, "GL renderer", SKIP, "glxinfo not installed"))

    if which("vulkaninfo"):
        rc, out, err = run(["vulkaninfo", "--summary"], timeout=30)
        devs = re.findall(r"deviceName\s*=\s*(.*)", out)
        drvn = re.findall(r"driverName\s*=\s*(.*)", out)
        if not devs:
            res.append(Result(g, "Vulkan device", WARN, "vulkaninfo rc=%d: %s" % (rc, (err.strip() or out.strip())[-140:])))
        else:
            hw_dev = [d for d in devs if not re.search(r"llvmpipe|lavapipe", d, re.I)]
            st = PASS if any(re.search(r"Mali|panvk", d + " ".join(drvn), re.I) for d in hw_dev) else WARN
            res.append(Result(g, "Vulkan device", st, "devices: %s; drivers: %s" % (
                "; ".join(x.strip() for x in devs), ", ".join(x.strip() for x in drvn))))
    else:
        res.append(Result(g, "Vulkan device", SKIP, "vulkaninfo not installed"))

    # VPU and media nodes
    nodes = [("/dev/mpp_service", "MPP video codec service"), ("/dev/rga", "RGA 2D"), ("/dev/cec0", "HDMI CEC")]
    for path, desc in nodes:
        ok = os.path.exists(path)
        res.append(Result(g, "node " + path, PASS if ok else FAIL, "%s %s" % (desc, "present" if ok else "missing")))
    npu = [n for n, d in drivers.items() if d.upper() == "RKNPU"]
    res.append(Result(g, "NPU render node", PASS if npu else WARN, ("RKNPU on " + npu[0]) if npu else "no RKNPU render node"))

    # HDMI connectors
    conns = sorted(glob.glob("/sys/class/drm/card*-HDMI-*"))
    if not conns:
        res.append(Result(g, "HDMI connector", FAIL, "no HDMI connector in /sys/class/drm"))
    for c in conns:
        status = (read(os.path.join(c, "status"), "?") or "?").strip()
        enabled = (read(os.path.join(c, "enabled"), "?") or "?").strip()
        modes = (read(os.path.join(c, "modes"), "") or "").split()
        st = PASS if status == "connected" else WARN
        res.append(Result(g, "HDMI " + os.path.basename(c), st, "status=%s enabled=%s modes=%d first=%s" % (
            status, enabled, len(modes), modes[0] if modes else "-")))

    # audio
    cards = read("/proc/asound/cards", "") or ""
    names = re.findall(r"^\s*\d+\s+\[(\S+)\s*\]", cards, re.M)
    hdmi = [n for n in names if "hdmi" in n.lower()]
    res.append(Result(g, "audio cards", PASS if hdmi else (WARN if names else FAIL),
                      ("cards: " + ", ".join(names)) if names else "no ALSA cards"))

    # Bluetooth
    hcis = sorted(listdir("/sys/class/bluetooth"))
    hcis = [h for h in hcis if re.match(r"hci\d+$", h)]
    uptime = float((read("/proc/uptime", "0 0") or "0 0").split()[0])
    if hcis:
        ev = "controllers: " + ", ".join(hcis)
        if which("hciconfig"):
            rc, out, err = run(["hciconfig", hcis[0]])
            flags = re.search(r"\n\s+(UP|DOWN)[^\n]*", out)
            ev += "; " + (flags.group(0).strip() if flags else "state ?")
            st = PASS if flags and flags.group(1) == "UP" else WARN
        else:
            st = PASS
        res.append(Result(g, "Bluetooth controller", st, ev))
    elif uptime < 300:
        res.append(Result(g, "Bluetooth controller", WARN, "adapter not ready yet (uptime %ds, no hci device)" % uptime))
    else:
        res.append(Result(g, "Bluetooth controller", FAIL, "no hci device after %ds uptime" % uptime))

    # network
    wifi, eth = [], []
    for n in sorted(listdir("/sys/class/net")):
        base = os.path.join("/sys/class/net", n)
        state = (read(os.path.join(base, "operstate"), "?") or "?").strip()
        if os.path.isdir(os.path.join(base, "wireless")) or os.path.exists(os.path.join(base, "phy80211")):
            wifi.append("%s(%s)" % (n, state))
        elif os.path.exists(os.path.join(base, "device")):
            eth.append((n, state))
    res.append(Result(g, "Wi-Fi interface", PASS if wifi else FAIL, ("wireless: " + ", ".join(wifi)) if wifi else "no wireless interface"))
    if eth:
        up = [n for n, s in eth if s == "up"]
        res.append(Result(g, "Ethernet link", PASS if up else WARN, ", ".join("%s(%s)" % e for e in eth)))
    else:
        res.append(Result(g, "Ethernet link", WARN, "no wired interface with a device"))

    # USB
    devs = [d for d in glob.glob("/sys/bus/usb/devices/*") if os.path.exists(os.path.join(d, "idVendor"))]
    roots = [d for d in devs if os.path.basename(d).startswith("usb")]
    leaf = []
    for d in devs:
        if d in roots:
            continue
        vid = (read(os.path.join(d, "idVendor"), "") or "").strip()
        pid = (read(os.path.join(d, "idProduct"), "") or "").strip()
        spd = (read(os.path.join(d, "speed"), "") or "").strip()
        leaf.append("%s:%s@%sM" % (vid, pid, spd))
    res.append(Result(g, "USB", PASS if roots else FAIL, "%d root hubs, %d devices %s" % (
        len(roots), len(leaf), " ".join(leaf[:8]))))

    # eMMC / SD
    mmc = []
    for b in sorted(glob.glob("/sys/block/mmcblk[0-9]")):
        typ = (read(os.path.join(b, "device", "type"), "?") or "?").strip()
        size = int((read(os.path.join(b, "size"), "0") or "0").strip() or 0) * 512
        mmc.append("%s %s %.1fG" % (os.path.basename(b), typ, size / 1e9))
    root_src = "?"
    for line in (read("/proc/mounts", "") or "").splitlines():
        p = line.split()
        if len(p) > 1 and p[1] == "/":
            root_src = p[0]
    has_emmc = any(" MMC " in (m + " ") for m in mmc)
    res.append(Result(g, "eMMC/SD", PASS if has_emmc else WARN, "%s; root on %s" % ("; ".join(mmc) or "no mmcblk", root_src)))

    # thermal
    zones = []
    worst = PASS
    for z in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
        typ = (read(os.path.join(z, "type"), "?") or "?").strip()
        t = (read(os.path.join(z, "temp"), "") or "").strip()
        if not t.lstrip("-").isdigit():
            continue
        c = int(t) / 1000.0
        crit = None
        for tp in glob.glob(os.path.join(z, "trip_point_*_type")):
            if (read(tp, "") or "").strip() == "critical":
                tv = (read(tp.replace("_type", "_temp"), "") or "").strip()
                if tv.isdigit():
                    crit = int(tv) / 1000.0
        if crit and c >= crit - 5:
            worst = FAIL
        elif c >= 85 and worst != FAIL:
            worst = WARN
        zones.append("%s=%.1fC" % (typ.replace("-thermal", ""), c))
    res.append(Result(g, "thermal zones", worst if zones else WARN, " ".join(zones) or "no thermal zones"))
    return res


# ---------- invariants ----------

def scan_paths():
    """Sorted candidate paths: SCAN_DIRS trees, SCAN_GLOBS, and h96-named paths under H96_ROOTS."""
    seen = set()
    for d in SCAN_DIRS:
        if not os.path.isdir(d):
            continue
        for root, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if x not in ("__pycache__",) and not x.startswith("python3")]
            for f in files:
                seen.add(os.path.join(root, f))
    for pat in SCAN_GLOBS:
        for p in glob.glob(pat):
            if os.path.isfile(p):
                seen.add(p)
    for lst in glob.glob(H96_PKG_LISTS):
        for l in (read(lst, "") or "").splitlines():
            if os.path.isfile(l) and not os.path.islink(l):
                seen.add(l)
    for top in H96_ROOTS:
        if not os.path.isdir(top):
            continue
        for root, dirs, files in os.walk(top, onerror=lambda e: None):
            dirs[:] = [x for x in dirs if x not in ("__pycache__",)]
            rel_h96 = "h96" in os.path.relpath(root, top).lower()
            for f in files:
                if rel_h96 or "h96" in f.lower():
                    seen.add(os.path.join(root, f))
    return sorted(seen)


def scan_files():
    for p in scan_paths():
        if os.path.basename(p).startswith("h96-selftest"):
            continue  # own test vectors
        try:
            if os.path.islink(p) or os.path.getsize(p) > SCAN_MAX_BYTES:
                continue
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if b"\x00" in data[:8192]:
            continue
        yield p, data.decode("utf-8", "replace")


def grep_files(files, rx, skip_comments=True, limit=6):
    hits, count = [], 0
    for path, text in files:
        for i, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if skip_comments and (s.startswith("#") or s.startswith("//") or s.startswith(";")):
                continue
            if rx.search(line):
                count += 1
                if len(hits) < limit:
                    hits.append("%s:%d: %s" % (path, i, s[:110]))
    return count, hits


def sshd_effective(path="/etc/ssh/sshd_config", seen=None, acc=None, reader=read, globber=glob.glob):
    """First-match-wins sshd parse of PermitRootLogin and PasswordAuthentication (Match blocks ignored)."""
    if acc is None:
        acc = {}
    if seen is None:
        seen = set()
    if path in seen:
        return acc
    seen.add(path)
    for line in (reader(path, "") or "").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split(None, 1)
        key = parts[0].lower()
        val = parts[1].strip() if len(parts) > 1 else ""
        if key == "match":
            break
        if key == "include":
            for pat in val.split():
                if not pat.startswith("/"):
                    pat = os.path.join("/etc/ssh", pat)
                for inc in sorted(globber(pat)):
                    sshd_effective(inc, seen, acc, reader, globber)
            continue
        if key in ("permitrootlogin", "passwordauthentication") and key not in acc:
            acc[key] = (val.lower(), path)
    return acc


def lightdm_sessions(files=None, reader=read):
    """Effective user-session and autologin-session from [Seat*] sections, later files win."""
    if files is None:
        files = sorted(glob.glob("/usr/share/lightdm/lightdm.conf.d/*.conf")) + ["/etc/lightdm/lightdm.conf"] + \
            sorted(glob.glob("/etc/lightdm/lightdm.conf.d/*.conf"))
    eff = {}
    for f in files:
        section = None
        for line in (reader(f, "") or "").splitlines():
            s = line.strip()
            if s.startswith("["):
                section = s
                continue
            if s.startswith("#") or "=" not in s:
                continue
            k, v = [x.strip() for x in s.split("=", 1)]
            if k in ("user-session", "autologin-session") and section and section.startswith("[Seat"):
                eff[k] = (v, f)
    return eff


def x11_decision(sess, xs, ws, live):
    """sess: {key: (session, file)}; xs/ws: installed .desktop names; live: session types."""
    chosen = [v[0] for v in sess.values()]
    bad = [c for c in chosen if (c + ".desktop") in ws and (c + ".desktop") not in xs]
    if bad or "wayland" in live:
        return FAIL
    if chosen and all((c + ".desktop") in xs for c in chosen):
        return PASS
    return WARN


def sysctl_order(listing):
    """listing: (directory, basename) pairs. Returns paths in systemd-sysctl apply order: one file
    per basename (first directory in SYSCTL_DIRS wins), sorted by basename. ("/etc", "sysctl.conf")
    stands in for 99-sysctl.conf when no file of that name exists."""
    pick = {}
    rank = {d: i for i, d in enumerate(SYSCTL_DIRS)}
    for d, b in listing:
        key = "99-sysctl.conf" if (d, b) == ("/etc", "sysctl.conf") else b
        if not key.endswith(".conf"):
            continue
        r = rank.get(d, 99)
        if key not in pick or r < pick[key][0]:
            pick[key] = (r, os.path.join(d, b))
    return [pick[k][1] for k in sorted(pick)]


def sysctl_writers(key, ordered, reader=read):
    """(path, line, value) for every assignment of key in apply order; last entry wins."""
    out = []
    for f in ordered:
        for i, line in enumerate((reader(f, "") or "").splitlines(), 1):
            m = re.match(r"\s*-?([\w./-]+)\s*=\s*(\S+)", line)
            if m and m.group(1).replace("/", ".") == key:
                out.append((f, i, m.group(2)))
    return out


def swappiness_decision(live, writers):
    """live: /proc value; writers: sysctl_writers() output in apply order. Returns (status, evidence).
    Rule: 100, or 150 from h96-perf-tune (PERF_SWAPPINESS_FILES); boot-time winner must agree."""
    wtxt = ", ".join("%s:%d=%s" % w for w in writers) or "no config writer"
    winner = writers[-1] if writers else None
    perf = [w for w in writers if os.path.basename(w[0]) in PERF_SWAPPINESS_FILES and w[2] == "150"]
    win_txt = ("boot winner %s:%d=%s" % winner) if winner else "no boot winner (kernel default)"
    ev = "live=%s; %s; writers in apply order: %s" % (live, win_txt, wtxt)
    if live not in ("100", "150"):
        return FAIL, ev + " (rule: 100, or 150 from h96-perf-tune)"
    if live == "150" and not perf:
        return FAIL, ev + " (150 without h96-perf-tune writer %s)" % "/".join(sorted(PERF_SWAPPINESS_FILES))
    if perf and winner[2] != "150":
        return WARN, ev + "; h96-perf-tune 150 (%s) overridden at boot by %s" % (os.path.basename(perf[-1][0]),
                                                                              os.path.basename(winner[0]))
    if winner is None or winner[2] != live:
        return WARN, ev + "; live value differs from boot winner"
    distinct = {w[2] for w in writers}
    if len(writers) > 1:
        return WARN, ev + "; %d config writers (%s)" % (len(writers), "agree" if len(distinct) == 1 else "conflict, last wins")
    return PASS, ev


def sysctl_listing():
    listing = []
    for d in SYSCTL_DIRS:
        try:
            listing += [(d, n) for n in os.listdir(d)]
        except OSError:
            continue
    if os.path.isfile("/etc/sysctl.conf"):
        listing.append(("/etc", "sysctl.conf"))
    return listing


def home_hits(files, names_ok=HOME_PLACEHOLDERS, limit=6):
    """Literal /home/<name>/ references outside runtime_state files; HOME_PLACEHOLDERS names ignored."""
    hits, count = [], 0
    for path, text in files:
        if runtime_state(path):
            continue
        for i, line in enumerate(text.splitlines(), 1):
            st = line.strip()
            if st.startswith("#") or st.startswith("//") or st.startswith(";"):
                continue
            if any(m.group(1) not in names_ok for m in RX_HOME.finditer(line)):
                count += 1
                if len(hits) < limit:
                    hits.append("%s:%d: %s" % (path, i, st[:110]))
    return count, hits


def check_invariants():
    g = "invariants"
    res = []
    files = list(scan_files())
    res.append(Result(g, "scan scope", INFO, "%d text files: all under %s; h96-named paths under %s" % (
        len(files), ", ".join(SCAN_DIRS), ", ".join(H96_ROOTS))))
    for path, why in sorted(RUNTIME_STATE.items()):
        if os.path.exists(path):
            res.append(Result(g, "scan exception", INFO, "%s: %s; excluded from username and home-path rules" % (path, why)))
    inst = sorted(p for p, t in files if runtime_state(p) == INSTALLER_WHY)
    if inst:
        res.append(Result(g, "scan exception", INFO, "%d files %s; excluded from username and home-path rules: %s" % (
            len(inst), INSTALLER_WHY, " ".join(inst[:8]) + (" ..." if len(inst) > 8 else ""))))

    # time zone: system files agree, no installed file forces a literal zone
    tzf = (read("/etc/timezone", "") or "").strip()
    try:
        lt = os.readlink("/etc/localtime")
        ltz = lt.split("zoneinfo/", 1)[1] if "zoneinfo/" in lt else lt
    except OSError:
        ltz = "?"
    agree = bool(tzf) and tzf == ltz or (not tzf and ltz != "?")
    res.append(Result(g, "time zone consistent", PASS if agree else WARN,
                      "/etc/timezone=%s /etc/localtime->%s" % (tzf or "(absent)", ltz)))
    n, hits = grep_files(files, RX_TZ)
    res.append(Result(g, "no forced time zone", FAIL if n else PASS,
                      ("%d literal zone writes:\n" % n + "\n".join(hits)) if n else "0 literal zone assignments in scanned files"))

    # usernames (current accounts plus private denylist) and uid 1000
    users = human_users()
    deny = [d for d in DENYLIST if d not in users]
    u1000 = uid_name(1000)
    res.append(Result(g, "uid 1000 account", INFO, "uid 1000 = %s; interactive accounts %d; denylist names %d (%s)" % (
        "present" if u1000 else "absent", len(users), len(deny), DENYLIST_SOURCE)))
    names = users + deny
    ufiles = [(p, t) for p, t in files if not runtime_state(p)]
    if names:
        rx_u = re.compile(r"(?<![\w-])(" + "|".join(re.escape(u) for u in names) + r")(?![\w-])")
        n, hits = grep_files(ufiles, rx_u, skip_comments=False)
        res.append(Result(g, "no hardcoded usernames", FAIL if n else PASS,
                          ("%d lines name a local or denylisted account:\n" % n + "\n".join(hits)) if n else
                          "0 lines naming any of %d local and %d denylisted accounts" % (len(users), len(deny))))
    else:
        res.append(Result(g, "no hardcoded usernames", SKIP, "no interactive accounts and no denylist"))
    n, hits = home_hits(files)
    res.append(Result(g, "no literal home paths", FAIL if n else PASS,
                      ("%d literal /home/<name>/ paths:\n" % n + "\n".join(hits)) if n else "0 literal /home/<name>/ paths"))
    n, hits = grep_files(files, RX_UID1000)
    n2, _ = grep_files(files, RX_SESSION_RESOLVE)
    res.append(Result(g, "no uid 1000 path assumptions", WARN if n else PASS,
                      (("%d literal uid-1000 paths:\n" % n) + "\n".join(hits) + "\n" if n else "0 literal /run/user/1000 or 1000:1000; ") +
                      "%d lines resolve user from SUDO_USER, PKEXEC_UID or logind session" % n2))
    n, hits = grep_files(files, RX_UID1000_LOOKUP, limit=60)
    res.append(Result(g, "no literal uid 1000 lookups", WARN if n else PASS,
                      ("%d lines look up uid 1000 by number (getent passwd 1000, id -nu 1000, getpwuid(1000), uid == 1000):\n" % n +
                       "\n".join(hits)) if n else "0 literal uid 1000 lookups"))

    # SSH root password login as on 7.2
    eff = sshd_effective()
    prl = eff.get("permitrootlogin", ("prohibit-password (default)", "-"))
    pwa = eff.get("passwordauthentication", ("yes (default)", "-"))
    ok = prl[0].startswith("yes") and pwa[0].startswith("yes")
    res.append(Result(g, "SSH root password login", PASS if ok else WARN,
                      "PermitRootLogin=%s (%s), PasswordAuthentication=%s (%s)" % (prl[0], prl[1], pwa[0], pwa[1])))

    # swappiness: effective winner in systemd-sysctl order
    sw = (read("/proc/sys/vm/swappiness", "") or "").strip()
    st, ev = swappiness_decision(sw, sysctl_writers("vm.swappiness", sysctl_order(sysctl_listing())))
    res.append(Result(g, "vm.swappiness rule", st, ev))

    # X11 session
    sess = lightdm_sessions()
    xs = sorted(os.path.basename(p) for p in glob.glob("/usr/share/xsessions/*.desktop"))
    ws = sorted(os.path.basename(p) for p in glob.glob("/usr/share/wayland-sessions/*.desktop"))
    live = []
    rc, out, err = run(["loginctl", "list-sessions", "--no-legend"])
    if rc == 0:
        for l in out.splitlines():
            sid = l.split()[0] if l.split() else None
            if not sid:
                continue
            rc2, o2, e2 = run(["loginctl", "show-session", sid, "-p", "Type", "--value"])
            typ = o2.strip()
            if typ in ("x11", "wayland"):
                live.append(typ)
    st = x11_decision(sess, xs, ws, live)
    res.append(Result(g, "X11 session only", st, "lightdm %s; live graphical sessions %s; xsessions %s; wayland-sessions present %s" % (
        ", ".join("%s=%s" % (k, v[0]) for k, v in sorted(sess.items())) or "no session keys",
        ",".join(live) or "none", ",".join(xs), ",".join(ws) or "none")))

    # CPU cores from cpu_capacity
    caps = {}
    for f in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpu_capacity"):
        m = re.search(r"cpu(\d+)/cpu_capacity", f)
        v = (read(f, "") or "").strip()
        if m and v.isdigit():
            caps[int(m.group(1))] = int(v)
    if caps:
        mx = max(caps.values())
        big = [c for c, v in caps.items() if v == mx]
        little = [c for c, v in caps.items() if v != mx]
        res.append(Result(g, "core layout from cpu_capacity", INFO, "big=%s (cap %d) little=%s" % (ranges(big), mx, ranges(little) or "-")))
    else:
        res.append(Result(g, "core layout from cpu_capacity", WARN, "no cpu_capacity files"))
    n, hits = grep_files(files, RX_CPU)
    res.append(Result(g, "no literal core numbers", WARN if n else PASS,
                      ("%d literal core references:\n" % n + "\n".join(hits)) if n else "0 literal core numbers in scanned files"))
    return res


# ---------- output ----------

def summarize(results):
    c = {PASS: 0, WARN: 0, FAIL: 0, INFO: 0, SKIP: 0}
    for r in results:
        c[r.status] += 1
    return c


def table(results, width=200):
    lines = []
    w = max([len(r.name) for r in results] + [5])
    lines.append("%-5s  %-10s  %-*s  %s" % ("STAT", "GROUP", w, "CHECK", "EVIDENCE"))
    for r in results:
        ev = r.evidence.replace("\n", " | ")
        if width and len(ev) > width:
            ev = ev[:width - 3] + "..."
        lines.append("%-5s  %-10s  %-*s  %s" % (r.status, r.group, w, r.name, ev))
    c = summarize(results)
    lines.append("summary: %d PASS, %d WARN, %d FAIL, %d INFO, %d SKIP" % (c[PASS], c[WARN], c[FAIL], c[INFO], c[SKIP]))
    return "\n".join(lines)


REPORT_DIR = "/tmp"


def report_path_ok(path):
    """Pure check: path must name a direct child of /tmp. Returns (ok, basename or reason)."""
    if not path or "\x00" in path:
        return False, "empty or invalid path"
    if not path.startswith("/"):
        return False, "report path must be absolute under /tmp: " + path
    if ".." in path.split("/"):
        return False, "report path must not contain '..': " + path
    parent, name = os.path.split(os.path.normpath(path))
    if parent != REPORT_DIR or name in ("", "."):
        return False, "report path must be a direct child of /tmp: " + path
    return True, name


def write_report(path, text):
    """Create a new report file as a direct child of /tmp; no symlink is followed at any level."""
    ok, name = report_path_ok(path)
    if not ok:
        raise ValueError(name)
    dfd = os.open(REPORT_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    finally:
        os.close(dfd)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)


def emit(results, args, scrub=True):
    sc = Scrubber() if scrub else None
    if sc:
        for r in results:
            r.evidence = sc.text(r.evidence)
            r.name = sc.text(r.name)
    if getattr(args, "json", False):
        print(json.dumps([r.as_dict() for r in results], indent=1))
    else:
        print(table(results, 0 if getattr(args, "full", False) else 200))
    return EXIT_FAIL if any(r.status == FAIL for r in results) else EXIT_OK


def guarded(fn, group):
    """Run one check group; an unexpected exception becomes one FAIL row instead of a crash."""
    try:
        return fn()
    except Exception as e:  # noqa: BLE001
        return [Result(group, "internal error", FAIL, "%s: %s" % (type(e).__name__, e))]


def cmd_report(args):
    results = guarded(check_boot, "boot") + guarded(check_hw, "hw") + guarded(check_invariants, "invariants")
    sc = Scrubber()
    for r in results:
        r.evidence = sc.text(r.evidence)
        r.name = sc.text(r.name)
    c = summarize(results)
    doc = {
        "tool": "h96-selftest", "version": VERSION,
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kernel": os.uname().release,
        "release": sc.text((read("/etc/h96-release", "") or "").strip()),
        "summary": c, "results": [r.as_dict() for r in results],
        "not_implemented": ["media", "menus", "soak"],
    }
    doc = sc.obj(doc)
    js = json.dumps(doc, indent=1)
    human = table(results, 200)
    if args.out:
        write_report(args.out, js + "\n")
        print("report written: " + args.out)
    if not args.json_only:
        print(human)
        print("--- json ---")
    print(js)
    return EXIT_FAIL if c[FAIL] else EXIT_OK


def cmd_stub(args):
    print("h96-selftest %s: %s" % (args.cmd, STUB_MSG))
    return EXIT_STUB


# ---------- self-test (no system access) ----------

def cmd_selftest(args):
    fails = []

    def ok(cond, label):
        print("%s  %s" % ("ok  " if cond else "FAIL", label))
        if not cond:
            fails.append(label)

    sc = Scrubber(hostnames={"boxhost"}, users={"alice"})
    seeded = "\n".join([
        "Oct 14 boxhost systemd[1]: started",
        "SSH_CONNECTION=172.16.5.50 51234 172.16.5.9 22",
        "FEX env: USER=alice HOME=/home/%s" % "alice",
        "Logged in as alice on steam",
        "path /home/%s/.local/share/Steam" % "alice",
        "bluez_output.AA_BB_CC_DD_EE_FF.1 error",
        "peer 10.0.0.7 and 8.8.8.8 and version 1.2.3.4567",
        "link fe80::1ff:fe23:4567:890a",
        "ssid=HomeNet psk=hunter2",
        "user alice owns file",
    ])
    out = sc.text(seeded)
    for token in ("boxhost", "alice", "172.16.5.", "AA_BB_CC", "10.0.0.7", "fe80::1ff", "HomeNet", "hunter2"):
        ok(token not in out, "scrub removes %s" % token)
    ok("8.8.8.8" in out, "scrub keeps public address 8.8.8.8")
    ok("1.2.3.4567" in out, "scrub keeps version string 1.2.3.4567")
    ok(out.count("[scrubbed line]") == 4, "scrub drops 4 env/login/secret lines (got %d)" % out.count("[scrubbed line]"))

    ok(classify("rk806 spi2.0: no sleep-setting state")[0] == "bsp-probe-rk806", "allowlist matches rk806 probe")
    ok(classify("spa.alsa: hdmi:0p: recover from error state SETUP") == ("row24-hdmi0p-recover", "warn"), "allowlist marks row24 as warn")
    ok(classify("mpp_platform: client 18 driver is not ready!") == ("bsp-probe-mpp-defer", "ignore"), "allowlist matches mpp probe deferral")
    ok(classify("mpp_platform: client 18 driver probe failed") == (None, None), "other mpp line is outside allowlist")
    ok(classify("rk806 spi2.0: no power-off pinctrl state")[0] == "bsp-probe-rk806", "allowlist matches rk806 power-off pinctrl")
    ok(classify("Unable to handle kernel NULL pointer dereference") == (None, None), "NULL deref is outside allowlist")
    ok(classify("Failed to set privacy: Rejected (0x0b)") == ("bt-privacy-rejected", "ignore"), "allowlist matches bluetoothd privacy reject")
    ok(classify("Failed to set privacy: Failed (0x03)") == (None, None), "other privacy failure is outside allowlist")
    ok(classify("src/adv_monitor.c:btd_adv_monitor_power_down() Unexpected NULL btd_adv_monitor_manager object upon power down")
       == ("bt-adv-monitor-race", "ignore"), "allowlist matches bluetoothd adv monitor power-down race")
    ok(classify("src/adv_monitor.c:btd_adv_monitor_power_down() Unexpected NULL btd_adv_monitor object upon power down")
       == (None, None), "other adv monitor message is outside allowlist")
    ok(classify("src/adv_monitor.c:btd_adv_monitor_add() Unexpected NULL btd_adv_monitor_manager object upon power down")
       == (None, None), "adv monitor race match is function-specific")
    for msg, aid in (
            ("RKNPU fdab0000.npu: error -EBUSY: can't request region for resource [mem 0xfdad0000-0xfdadffff]", "bsp-probe-rknpu-region"),
            ("RKNPU fdab0000.npu: can't request region for resource [mem 0xfdab0000-0xfdabffff]", "bsp-probe-rknpu-region"),
            ("OF: reserved mem: Reserved memory: failed to reserve memory for node 'drm-logo@0': base 0x0000000000000000, size 0 MiB", "612-reserved-mem-empty"),
            ("OF: reserved mem: Reserved memory: failed to reserve memory for node 'drm-cubic-lut@0': base 0x0000000000000000, size 0 MiB", "612-reserved-mem-empty"),
            ("cpu cpu0: failed to get cpu0 clk", "612-cpufreq-clk-defer"),
            ("cpu cpu0: cpu0 clk is not ready", "612-cpufreq-clk-defer"),
            ("failed to init cpufreq", "612-cpufreq-clk-defer"),
            ("gpio-0 (BT,wake_host): gpiod_direction_output: tried to set a GPIO tied to an IRQ as output", "612-bt-wake-host-irq"),
            ("rockchip-dmc dmc: failed to get vop pn to msch rl", "612-dmc-optional"),
            ("rockchip-dmc dmc: Current ATF unsupported get_stall_time", "612-dmc-optional")):
        ok(classify(msg) == (aid, "ignore"), "6.12 probe line in %s" % aid)
    for msg in ("OF: reserved mem: Reserved memory: failed to reserve memory for node 'drm-logo@0': base 0x0000000010000000, size 16 MiB",
                "cpu cpu4: failed to get cpu4 clk", "rockchip-dmc dmc: failed to set rate",
                "WARNING: CPU: 3 PID: 1 at drivers/gpu/drm/drm_gem.c:100 drm_gem_object_free",
                "Internal error: Oops: 0000000096000004 [#1] PREEMPT SMP"):
        ok(classify(msg) == (None, None), "outside allowlist: %s" % msg[:40])
    r = budget_results("t", "x", [("k", "rk806 spi2.0: no sleep-setting state"), ("k", "new error 12"), ("k", "new error 13")])
    ok(r[0].status == FAIL and "2 outside" in r[0].evidence and "1 distinct" in r[0].evidence, "budget counts unknown lines and groups digits")

    ok([f[1] for f in decode_taint(4096 + 512)] == ["W", "O"], "taint 4608 decodes to W,O")
    ok(ranges([1, 2, 3, 4]) == "1-4" and ranges([0, 5, 6, 7]) == "0,5-7", "ranges compress core lists")

    # path guard tested as a pure function; no file is opened
    for pth, want in (("/tmp/h96-report.json", True), ("/tmp//h96-report.json", True),
                      ("/etc/h96-selftest-should-refuse.json", False), ("/tmp/../etc/x.json", False),
                      ("/tmp/sub/x.json", False), ("/tmp", False), ("/tmp/", False), ("/tmp/.", False),
                      ("tmp/x.json", False), ("./x.json", False), ("/nonexistent-h96/x.json", False), ("", False)):
        ok(report_path_ok(pth)[0] == want, "report path %s: %r" % ("accepted" if want else "refused", pth))
    try:
        write_report("/nonexistent-h96/x.json", "x")
        ok(False, "write_report refuses before open (nonexistent root)")
    except ValueError:
        ok(True, "write_report refuses before open (nonexistent root)")
    except OSError as e:
        ok(False, "write_report refuses before open (reached open: %s)" % e.strerror)

    # invariant helpers on synthetic input
    sshd = {"/etc/ssh/sshd_config": "Include /etc/ssh/sshd_config.d/*.conf\nPermitRootLogin no\n",
            "/etc/ssh/sshd_config.d/10-a.conf": "PermitRootLogin yes\nMatch User x\nPasswordAuthentication no\n"}
    eff = sshd_effective(reader=lambda f, d=None: sshd.get(f, d),
                         globber=lambda pat: fnmatch.filter(sorted(sshd), pat))
    ok(eff.get("permitrootlogin", ("",))[0] == "yes" and "passwordauthentication" not in eff,
       "sshd first match wins via Include, Match block ignored")
    ld = {"/a.conf": "[Seat:*]\nuser-session=plasma\n", "/b.conf": "[Seat:*]\nuser-session=plasmax11\n[Other]\nuser-session=x\n"}
    sess = lightdm_sessions(["/a.conf", "/b.conf"], reader=lambda f, d=None: ld.get(f, d))
    ok(sess.get("user-session", ("",))[0] == "plasmax11", "lightdm later file wins, non-Seat section ignored")
    ok(x11_decision(sess, ["plasmax11.desktop"], ["plasma.desktop"], ["x11"]) == PASS, "x11 decision PASS for plasmax11")
    ok(x11_decision({"user-session": ("plasma", "/a")}, ["plasmax11.desktop"], ["plasma.desktop"], []) == FAIL,
       "x11 decision FAIL for wayland session")
    ok(x11_decision(sess, ["plasmax11.desktop"], [], ["wayland"]) == FAIL, "x11 decision FAIL for live wayland")
    order = sysctl_order([("/etc/sysctl.d", "99-sysctl.conf"), ("/etc", "sysctl.conf"), ("/usr/lib/sysctl.d", "zz-a.conf"),
                          ("/etc/sysctl.d", "zz-a.conf"), ("/etc/sysctl.d", "90-h96-zram.conf"), ("/etc/sysctl.d", "README")])
    ok(order == ["/etc/sysctl.d/90-h96-zram.conf", "/etc/sysctl.d/99-sysctl.conf", "/etc/sysctl.d/zz-a.conf"],
       "sysctl order: one file per basename, /etc wins, sorted")
    files = {"/etc/sysctl.d/90-h96-zram.conf": "vm.swappiness = 150\n", "/etc/sysctl.d/99-sysctl.conf": "vm.swappiness=100\n"}
    w = sysctl_writers("vm.swappiness", sorted(files), reader=lambda f, d=None: files.get(f, d))
    ok(swappiness_decision("100", w[1:])[0] == PASS, "swappiness single writer 100 PASS")
    ok(swappiness_decision("100", w)[0] == WARN, "swappiness perf-tune 150 overridden at boot WARN")
    ok(swappiness_decision("60", w[1:])[0] == FAIL, "swappiness 60 FAIL")
    ok(swappiness_decision("150", w[1:])[0] == FAIL, "swappiness 150 without perf-tune writer FAIL")
    n, _h = home_hits([("/x", "C=/home/%s/.config\nD=/home/%s/x\n# /home/%s/y\n" % ("alice", "user", "alice"))])
    ok(n == 1, "home path rule flags names, skips placeholder and comments")
    baked = "U=%s; C=/home/%s/.local/share/steam-arm/config.vdf\n" % ("alice", "alice")
    n, _h = home_hits([("/usr/local/bin/steam-arm-compatmap", baked), ("/usr/local/lib/steam-arm-run.py", baked)])
    ok(n == 0, "home path rule accepts Steam ARM installer output")
    n, _h = home_hits([("/usr/bin/h96-steam", baked), ("/usr/local/bin/h96-steam-arm-compatmap", baked)])
    ok(n == 2, "home path rule still flags packaged and non-installer files")
    ok(runtime_state("/usr/local/share/steam-arm/titles.conf") == INSTALLER_WHY and runtime_state("/usr/lib/h96/x") is None,
       "installer state globs match installer paths only")
    for line, want in (("taskset -c 4-7 game", True), ("BIG_CORES=\"1-4\"", True), ("cat /sys/devices/system/cpu/cpu4/cpufreq", True),
                       ("cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", False), ("CPUAffinity=1 2 3 4", True),
                       ("echo $BIG > cpuset.cpus", False), ("echo 1-4 > /sys/fs/cgroup/g/cpuset.cpus", True)):
        ok(bool(RX_CPU.search(line)) == want, "core rule %s: %s" % ("flags" if want else "skips", line))
    for line, want in (("timedatectl set-timezone Europe/Berlin", True), ("timedatectl set-timezone UTC", True),
                       ("ln -sf /usr/share/zoneinfo/UTC /etc/localtime", True),
                       ("ln -sf /usr/share/zoneinfo/America/Argentina/Salta /etc/localtime", True),
                       ("TZ=UTC", True), ("export TZ=Etc/UTC", True), ("TZ=:Europe/Paris date", True), ("echo UTC > /etc/timezone", True),
                       ("timedatectl set-timezone \"$TZ\"", False), ("ln -sf \"/usr/share/zoneinfo/$Z\" /etc/localtime", False),
                       ("TZ=$ZONE date", False), ("ls /usr/share/zoneinfo/", False)):
        ok(bool(RX_TZ.search(line)) == want, "time zone rule %s: %s" % ("flags" if want else "skips", line))
    for line, want in (("GAMEUSER=${GAMEUSER:-$(getent passwd 1000 | cut -d: -f1)}", True), ("U=$(id -nu 1000)", True),
                       ("pwd.getpwuid(1000).pw_name", True), ("if uid == 1000:", True), ("[ \"$UID\" -eq 1000 ]", True),
                       ("[ \"$(id -u)\" = 1000 ]", True), ("U=${SUDO_USER:-}", False),
                       ("loginctl show-session \"$S\" -p Name --value", False), ("chown 1000:1000 x", False),
                       ("sleep 1000", False), ("MAXUID=10000", False)):
        ok(bool(RX_UID1000_LOOKUP.search(line)) == want, "uid 1000 lookup rule %s: %s" % ("flags" if want else "skips", line))
    for line, want in (("U=${SUDO_USER:-}", True), ("loginctl show-session \"$S\" -p Name --value", True),
                       ("pkexec uid ${PKEXEC_UID}", True), ("U=$(getent passwd 1000 | cut -d: -f1)", False)):
        ok(bool(RX_SESSION_RESOLVE.search(line)) == want, "session rule %s: %s" % ("counts" if want else "skips", line))
    ok(ring_complete("Booting Linux on physical CPU 0x0\nLinux version 6.1\n"), "ring with first boot line is complete")
    ok(not ring_complete("[drm] late line\nmore\n") and not ring_complete(""), "wrapped or empty ring is incomplete")
    c = oops_counts("x\nWARNING: CPU: 3 PID: 1 at foo\nCall trace:\nBUG: sleeping\n")
    ok(c["WARN"] == 1 and c["call_trace"] == 1 and c["BUG"] == 1 and c["Oops"] == 0, "oops counter on journal text")
    ok(read_denylist("/nonexistent-h96-denylist") == [], "missing denylist gives empty list")

    rc, _o, _e = run(["/nonexistent-h96-binary"])
    ok(rc == 127, "missing command maps to rc 127")
    print("self-test: %d failed" % len(fails))
    return EXIT_FAIL if fails else EXIT_OK


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="h96-selftest",
        description="Read-only health checks. Writes nothing except a report under /tmp when 'report --out' is given. "
                    "Exit codes: 0 no FAIL, 1 at least one FAIL, 2 usage error, 3 stub subcommand.")
    p.add_argument("--version", action="version", version="h96-selftest " + VERSION)
    p.add_argument("--denylist", metavar="FILE", default=DENYLIST_DEFAULT,
                   help="private list of earlier account names, one per line (default %s; missing file is fine)" % DENYLIST_DEFAULT)
    sub = p.add_subparsers(dest="cmd", metavar="COMMAND")
    for name, hlp in (("boot", "journal error budget, failed units, taint, oops/BUG/WARN, dmesg vs allowlist, pstore, watchdog"),
                      ("hw", "GPU driver and renderer, VPU/RGA/CEC/NPU nodes, HDMI, audio, BT, Wi-Fi, Ethernet, USB, eMMC/SD, thermal"),
                      ("invariants", "time zone, usernames and uid 1000, SSH root login, swappiness, X11 session, cores from cpu_capacity")):
        sp = sub.add_parser(name, help=hlp, description=hlp)
        sp.add_argument("--json", action="store_true", help="print JSON instead of the table")
        sp.add_argument("--full", action="store_true", help="do not truncate evidence in the table")
        sp.add_argument("--raw", action="store_true", help="skip scrubbing (local debugging only)")
    rp = sub.add_parser("report", help="run boot, hw and invariants; print scrubbed table and JSON",
                        description="Scrubs host names, usernames, home paths, LAN and MAC addresses, Steam/FEX env and login lines, Wi-Fi secrets.")
    rp.add_argument("--out", metavar="/tmp/FILE.json", help="also write JSON to a new file under /tmp (refuses other paths and existing files)")
    rp.add_argument("--json-only", action="store_true", help="print only the JSON document")
    for name in ("media", "menus", "soak"):
        sub.add_parser(name, help=STUB_MSG + " (stub)", description=STUB_MSG)
    sub.add_parser("self-test", help="offline unit checks of scrubber, allowlist, taint decode, invariant rules and report path guard")

    args = p.parse_args(argv)
    global DENYLIST, DENYLIST_SOURCE
    DENYLIST = read_denylist(args.denylist)
    DENYLIST_SOURCE = ("%s, %d names" % (args.denylist, len(DENYLIST))) if os.path.isfile(args.denylist) else "no denylist file"
    if not args.cmd:
        p.print_help()
        return EXIT_USAGE
    if args.cmd in ("media", "menus", "soak"):
        return cmd_stub(args)
    if args.cmd == "self-test":
        return cmd_selftest(args)
    if args.cmd == "report":
        try:
            return cmd_report(args)
        except (ValueError, OSError) as e:
            print("h96-selftest: " + str(e), file=sys.stderr)
            return EXIT_USAGE
    fn = {"boot": check_boot, "hw": check_hw, "invariants": check_invariants}[args.cmd]
    return emit(guarded(fn, args.cmd), args, scrub=not args.raw)


if __name__ == "__main__":
    sys.exit(main())
