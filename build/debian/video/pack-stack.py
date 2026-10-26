#!/usr/bin/env python3
"""Debian h96-video-stack.tar.gz: member list and modes of Ubuntu stack (r21 payload), four rebuilt binaries replaced, root-owned,
fixed mtime, gzip without name/time. Usage: pack-stack.py UBUNTU_TGZ STAGE_DIR OUT_TGZ"""
import gzip, hashlib, io, sys, tarfile
old, st, out = sys.argv[1:4]
MTIME = 1792540800  # 2026-10-21 00:00 UTC
NEW = {"usr/bin/ffmpeg": "ffmpeg", "usr/bin/ffprobe": "ffprobe", "usr/bin/mpv": "mpv",
       "usr/lib/aarch64-linux-gnu/libmpv.so.2.5.0": "libmpv.so.2.5.0"}
raw = io.BytesIO()
with tarfile.open(old, "r:gz") as o, tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as n:
    for m in o.getmembers():
        t = tarfile.TarInfo(m.name); t.uid = t.gid = 0; t.uname = t.gname = "root"
        t.mode, t.type, t.linkname = m.mode, m.type, m.linkname
        t.mtime = MTIME if m.name in NEW or m.isdir() else m.mtime
        if m.isfile():
            d = open(f"{st}/{NEW[m.name]}", "rb").read() if m.name in NEW else o.extractfile(m).read()
            t.size = len(d); n.addfile(t, io.BytesIO(d))
        else:
            n.addfile(t)
with open(out, "wb") as f, gzip.GzipFile(fileobj=f, mode="wb", mtime=MTIME, compresslevel=9, filename="") as g:
    g.write(raw.getvalue())
assert [m.name for m in tarfile.open(out).getmembers()] == [m.name for m in tarfile.open(old).getmembers()]
print(hashlib.sha256(open(out, "rb").read()).hexdigest(), out)
