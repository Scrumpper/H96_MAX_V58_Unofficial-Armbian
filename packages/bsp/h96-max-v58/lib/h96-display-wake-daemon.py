#!/usr/bin/env python3
# h96-display-wake-daemon: watch every input device; when a key or button is
# pressed while the HDMI connector is connected but not enabled, run
# h96-display-wake.sh to re-drive the output.
#
# Why: this BSP kernel does not re-initialise the HDMI PHY/VOP path after
# DPMS-off on its own, so a blanked screen never returns on keypress. The
# desktop still blanks normally; this daemon only acts in the broken state
# (connected + disabled), so it never prevents blanking.
#
# Cost: blocking select() on the event devices; the sysfs check is rate-limited
# to once per 3 s and only runs on an actual key/button press.

import glob
import os
import select
import struct
import subprocess
import time

CON = "/sys/class/drm/card0-HDMI-A-1"
WAKE = "/usr/local/sbin/h96-display-wake.sh"
EV_FMT = "llHHi"
EV_SIZE = struct.calcsize(EV_FMT)
EV_KEY = 1


def output_dead():
    try:
        with open(CON + "/status") as f:
            if f.read().strip() != "connected":
                return False
        with open(CON + "/enabled") as f:
            return f.read().strip() == "disabled"
    except OSError:
        return False


def scan(fds):
    present = set(fds.values())
    for path in glob.glob("/dev/input/event*"):
        if path in present:
            continue
        try:
            fds[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
        except OSError:
            pass


def main():
    fds = {}
    scan(fds)
    last_fix = 0.0
    last_scan = time.monotonic()
    while True:
        r, _, _ = select.select(list(fds), [], [], 30)
        now = time.monotonic()
        if now - last_scan >= 60:
            last_scan = now
            scan(fds)  # pick up keyboards plugged in since the last scan
        pressed = False
        for fd in r:
            try:
                data = os.read(fd, EV_SIZE * 64)
            except OSError:
                os.close(fd)
                fds.pop(fd, None)
                continue
            for off in range(0, len(data) - EV_SIZE + 1, EV_SIZE):
                _, _, etype, _, value = struct.unpack_from(EV_FMT, data, off)
                if etype == EV_KEY and value == 1:
                    pressed = True
        if pressed and now - last_fix >= 3.0 and output_dead():
            last_fix = now
            try:
                subprocess.run([WAKE], timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if not fds:
            time.sleep(5)
            scan(fds)


if __name__ == "__main__":
    main()
