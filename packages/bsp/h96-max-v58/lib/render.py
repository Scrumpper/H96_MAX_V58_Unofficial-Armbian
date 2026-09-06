#!/usr/bin/env python3
"""
h96 subtitle renderer - draws live text over mpv via its JSON IPC socket.

THE TRAP THIS IS BUILT AROUND
-----------------------------
mpv destroys every overlay owned by an IPC client when that client disconnects. So the
obvious shape -- one `socat` per caption -- draws nothing at all: each connection dies
immediately and takes its overlay with it. This class therefore opens ONE socket and holds
it open for the whole session.

Uses `osd-overlay` with ASS events, which is the only route that gives styling control and
does not fight with mpv's own subtitle track.
"""
import json, os, socket, time


class MpvOverlay:
    def __init__(self, sock_path, overlay_id=63, font_size=42):
        self.path = sock_path
        self.id = overlay_id
        self.font_size = font_size
        self.sock = None
        self._req = 0

    def connect(self, timeout=10.0):
        end = time.time() + timeout
        last = None
        while time.time() < end:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(2.0)
                s.connect(self.path)
                self.sock = s
                return True
            except OSError as e:
                last = e
                time.sleep(0.3)
        raise RuntimeError(f"could not connect to mpv IPC at {self.path}: {last}")

    def _send(self, cmd):
        if not self.sock:
            return None
        self._req += 1
        payload = json.dumps({"command": cmd, "request_id": self._req}) + "\n"
        try:
            self.sock.sendall(payload.encode("utf-8"))
        except OSError:
            return None
        # drain whatever is available; mpv also pushes unsolicited events
        try:
            self.sock.recv(65536)
        except (socket.timeout, OSError):
            pass
        return True

    @staticmethod
    def _escape(text):
        # ASS treats these specially; a stray brace silently eats the caption
        return text.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}").replace("\n", "\\N")

    def show(self, text):
        """Draw a caption. Bottom-centred, outlined, readable on any picture."""
        if not text:
            return self.clear()
        style = (f"{{\\an2\\fs{self.font_size}\\bord3\\shad1"
                 f"\\1c&HFFFFFF&\\3c&H000000&}}")
        data = style + self._escape(text)
        return self._send(["osd-overlay", self.id, "ass-events", data,
                           0, 0, 0, "no", "no"])

    def clear(self):
        return self._send(["osd-overlay", self.id, "none", "", 0, 0, 0, "no", "no"])

    def close(self):
        try:
            self.clear()
        finally:
            if self.sock:
                try:
                    self.sock.close()
                except OSError:
                    pass
                self.sock = None

    def __enter__(self):
        self.connect(); return self

    def __exit__(self, *a):
        self.close()


def srt_cues(path):
    """Yield (start, end, text) from an .srt, for replaying a finished file."""
    import re
    def sec(x):
        h, m, rest = x.split(":")
        s, ms = rest.split(",")
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000
    txt = open(path, encoding="utf-8", errors="replace").read()
    for m in re.finditer(
            r"\d+\s*\n(\d\d:\d\d:\d\d,\d+)\s*-->\s*(\d\d:\d\d:\d\d,\d+)\s*\n(.+?)(?=\n\s*\n|\Z)",
            txt, re.S):
        yield sec(m.group(1)), sec(m.group(2)), " ".join(m.group(3).split())
