#!/usr/bin/env python3
"""h96-bt-a2dp-heal (H96 Max V58): reconnect a Bluetooth headset's stereo (A2DP) link when it
drops while the device stays connected.

When the audio session manager (WirePlumber) restarts, it withdraws its A2DP endpoints and
many headsets close their A2DP stream. BlueZ only reconnects profiles after a full link loss,
so the headset stays connected with Handsfree only (or no audio at all).

Every 5 s: for each connected device that advertises A2DP Audio Sink (0000110b) but has no
remote A2DP endpoint (org/bluez/hciN/dev_X/sepN) for two checks in a row, call
Device1.ConnectProfile(A2DP). Uses busctl only (no Python D-Bus bindings needed)."""
import re, subprocess, sys, time

A2DP_SINK = "0000110b-0000-1000-8000-00805f9b34fb"
INTERVAL = 5
missing = {}      # device path -> consecutive checks with no endpoint
last_try = {}     # device path -> time of last reconnect attempt


def busctl(*args):
    r = subprocess.run(["busctl", "--system", *args], capture_output=True, text=True, timeout=20)
    return r.returncode, r.stdout, r.stderr


def objects():
    rc, out, _ = busctl("tree", "--list", "org.bluez")
    return out.split() if rc == 0 else []


def prop(path, iface, name):
    rc, out, _ = busctl("get-property", "org.bluez", path, iface, name)
    return out.strip() if rc == 0 else ""


def log(*a):
    print("h96-bt-a2dp-heal:", *a, flush=True)


while True:
    objs = objects()
    devices = [o for o in objs if re.fullmatch(r"/org/bluez/hci\d+/dev_[0-9A-F_]{17}", o)]
    for dev in devices:
        if prop(dev, "org.bluez.Device1", "Connected") != "b true":
            missing.pop(dev, None)
            continue
        if A2DP_SINK not in prop(dev, "org.bluez.Device1", "UUIDs"):
            continue
        has_ep = any(o.startswith(dev + "/sep") for o in objs)
        if has_ep:
            missing.pop(dev, None)
            continue
        missing[dev] = missing.get(dev, 0) + 1
        if missing[dev] < 2 or time.time() - last_try.get(dev, 0) < 30:
            continue
        last_try[dev] = time.time()
        rc, _, err = busctl("call", "org.bluez", dev, "org.bluez.Device1", "ConnectProfile", "s", A2DP_SINK)
        log("A2DP missing on", dev.rsplit("/", 1)[-1], "- reconnect", "ok" if rc == 0 else "failed: " + err.strip())
    time.sleep(INTERVAL)
