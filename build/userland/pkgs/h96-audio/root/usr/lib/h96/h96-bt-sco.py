#!/usr/bin/env python3
"""h96-bt-sco.py: route Bluetooth SCO audio over HCI (Broadcom VSC 0xFC1C) without bluez tools.

Usage: h96-bt-sco.py [--wait SEC] [--status]
  --wait SEC  ceiling for hci0 to come UP (default 90)
  --status    read the route back (VSC 0xFC1D), change nothing
Exit 0: route set (or no hci0 on this machine), 1: VSC failed, 2: usage."""
import errno, fcntl, os, select, socket, struct, sys, time

HCI_DEV = 0
HCIGETDEVINFO = 0x800448D3           # _IOR('H', 211, int)
HCI_UP = 1 << 0
SET_OP, READ_OP = 0xFC1C, 0xFC1D
ROUTE_HCI = bytes([0x01, 0x00, 0x00, 0x00, 0x00])  # routing=HCI, rate/frame/sync/clock 0
TRIES = 3


def log(msg):
    print("h96-bt-sco: " + msg, flush=True)


def dev_state():
    """None when hci0 is absent, else True/False for UP."""
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    try:
        buf = bytearray(struct.pack("<H", HCI_DEV) + bytes(90))
        try:
            fcntl.ioctl(s, HCIGETDEVINFO, buf)
        except OSError as e:
            if e.errno == errno.ENODEV:
                return None
            raise
        flags = struct.unpack_from("<I", buf, 16)[0]
        return bool(flags & HCI_UP)
    finally:
        s.close()


def open_hci():
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    s.bind((HCI_DEV,))
    # struct hci_ufilter is 14 bytes padded to 16: event packets, Command Complete + Status
    flt = struct.pack("<IIIH2x", 1 << 4, (1 << 0x0E) | (1 << 0x0F), 0, 0)
    s.setsockopt(socket.SOL_HCI, socket.HCI_FILTER, flt)
    return s


def command(s, op, params=b"", timeout=2.0):
    """Send one HCI command; return (status, return params) or None on timeout."""
    s.send(bytes([0x01, op & 0xFF, op >> 8, len(params)]) + params)
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        r, _, _ = select.select([s], [], [], max(0.0, end - time.monotonic()))
        if not r:
            break
        p = s.recv(260)
        if len(p) >= 7 and p[0] == 0x04 and p[1] == 0x0E and (p[4] | p[5] << 8) == op:
            return p[6], bytes(p[7:])
        if len(p) >= 7 and p[0] == 0x04 and p[1] == 0x0F and (p[5] | p[6] << 8) == op and p[3] != 0:
            return p[3], b""
    return None


def main(argv):
    wait, status_only = 90.0, False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--wait" and args:
            try:
                wait = float(args.pop(0))
            except ValueError:
                print(__doc__, file=sys.stderr); return 2
        elif a == "--status":
            status_only = True
        elif a in ("-h", "--help"):
            print(__doc__); return 0
        else:
            print(__doc__, file=sys.stderr); return 2
    if not hasattr(socket, "BTPROTO_HCI") or not hasattr(socket, "HCI_FILTER"):
        log("python socket module has no raw HCI support; route not set")
        return 1
    end = time.monotonic() + wait
    while True:
        try:
            st = dev_state()
        except OSError as e:
            if e.errno in (errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT):
                log("no Bluetooth support in kernel; nothing to do")
                return 0
            raise
        if st:
            break
        if time.monotonic() >= end:
            if st is None:
                log("no hci0 after %.0f s; nothing to do" % wait)
                return 0
            log("hci0 present but not UP after %.0f s; route not set" % wait)
            return 1
        time.sleep(0.5)
    s = open_hci()
    try:
        if status_only:
            r = command(s, READ_OP)
            if r is None or r[0] != 0:
                log("route read failed (%s)" % ("timeout" if r is None else "status %d" % r[0]))
                return 1
            log("SCO route %s (params %s)" % ("HCI" if r[1][:1] == b"\x01" else "PCM", r[1].hex(" ")))
            return 0
        for n in range(1, TRIES + 1):
            r = command(s, SET_OP, ROUTE_HCI)
            if r is not None and r[0] == 0:
                rb = command(s, READ_OP)
                back = rb[1].hex(" ") if rb and rb[0] == 0 else "unavailable"
                log("SCO routed over HCI (status 0, try %d, read-back %s)" % (n, back))
                return 0
            log("try %d: %s" % (n, "timeout" if r is None else "status %d" % r[0]))
            time.sleep(1)
        return 1
    finally:
        s.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
