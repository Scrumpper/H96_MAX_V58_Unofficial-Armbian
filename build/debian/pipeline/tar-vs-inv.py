#!/usr/bin/env python3
"""Compare built rootfs tarball (owners, modes, types, link targets, xattrs) with e2inv.py lists of p2 and p1.
Usage: tar-vs-inv.py TARBALL.zst P2INV P2XATTR P1INV"""
import subprocess, sys, tarfile
tz, p2i, p2x, p1i = sys.argv[1:5]
inv = {}
for f, pre in ((p2i, ""), (p1i, "/boot")):
    for l in open(f, errors="surrogateescape"):
        p, t, m, u, g, tg = l.rstrip("\n").split("\t")
        if pre and p == "/":
            continue
        if p == "/lost+found" or p.startswith("/lost+found/"):
            continue
        inv[pre + p if p != "/" else "/"] = (t, int(m, 8), int(u), int(g), tg)
xa = {}
for l in open(p2x, errors="surrogateescape"):
    p, n, h = l.rstrip("\n").split("\t")
    xa[(p, n)] = bytes.fromhex(h)
z = subprocess.Popen(["zstd", "-dc", tz], stdout=subprocess.PIPE)
bad = seen = 0
with tarfile.open(fileobj=z.stdout, mode="r|") as t:
    for m in t:
        p = "/" + m.name.lstrip("./") if m.name not in (".", "./") else "/"
        p = p.rstrip("/") or "/"
        if p == "/lost+found" or p.startswith("/lost+found/"):
            continue  # mke2fs makes its own
        seen += 1
        e = inv.pop(p, None)
        typ = "d" if m.isdir() else "l" if m.issym() else "f" if (m.isfile() or m.islnk()) else "c" if m.ischr() else "b" if m.isblk() else "p"
        if e is None:
            print("MISSING-IN-IMAGE", p); bad += 1; continue
        if p == "/boot":
            continue  # p2 mount point, p1 root
        if e[0] != typ or e[2] != m.uid or e[3] != m.gid or (typ != "l" and e[1] != (m.mode & 0o7777)) or (typ == "l" and e[4] != m.linkname):
            print("DIFF", p, typ, oct(m.mode & 0o7777), m.uid, m.gid, m.linkname, "| image", e); bad += 1
        for k, v in (m.pax_headers or {}).items():
            if k.startswith("SCHILY.xattr."):
                n = k[len("SCHILY.xattr."):]
                if xa.get((p, n)) != v.encode("latin-1", "surrogateescape") and xa.get((p, n)) != v.encode("utf-8", "surrogateescape"):
                    print("XATTR", p, n); bad += 1
left = [p for p in inv if p not in ("/boot",)]
for p in left[:20]:
    print("EXTRA-IN-IMAGE", p)
bad += len(left)
print(f"tar entries {seen}, image entries left {len(left)}, bad {bad}")
sys.exit(1 if bad else 0)
