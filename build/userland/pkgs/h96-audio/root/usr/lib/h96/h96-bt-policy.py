#!/usr/bin/env python3
"""/etc/bluetooth/main.conf: fast connectable + persistent reconnect. Idempotent; keeps a .orig copy."""
import os, re, shutil, stat, sys
P = sys.argv[1] if len(sys.argv) > 1 else "/etc/bluetooth/main.conf"
MARK = "# h96: reconnect policy"
s = open(P).read()
if MARK in s:
    print("already applied"); sys.exit(0)
if not os.path.exists(P + ".orig"):
    shutil.copy2(P, P + ".orig")


def set_key(s, section, key, value, comment):
    m = re.search(r"^\[%s\]\s*$" % re.escape(section), s, re.M)
    line = "%s\n%s = %s\n" % (comment, key, value)
    if not m:
        return s.rstrip("\n") + "\n\n[%s]\n%s" % (section, line)
    i = m.end() + 1
    return s[:i] + line + s[i:]


s = set_key(s, "General", "FastConnectable", "true",
            MARK + ": page scan kept fast, so a headset reconnects in about a second.")
s = set_key(s, "Policy", "ReconnectAttempts", "15",
            MARK + ": keep retrying a headset that dropped (out of range, back from case).")
s = s.replace("ReconnectAttempts = 15\n",
              "ReconnectAttempts = 15\nReconnectIntervals = 1,2,4,8,16,32,60\n", 1)
# atomic write: temp file in the same dir, fsync, rename; keep owner/mode of the original
st = os.stat(P)
tmp = P + ".h96new"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(s)
    f.flush()
    os.fsync(f.fileno())
os.chmod(tmp, stat.S_IMODE(st.st_mode))
os.chown(tmp, st.st_uid, st.st_gid)
os.replace(tmp, P)
print("applied")
