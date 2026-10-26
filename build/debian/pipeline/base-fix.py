#!/usr/bin/env python3
"""Inside podman unshare: owners, modes and xattrs of an rdump tree set from e2inv.py lists, then compared.
Usage: base-fix.py TREE INV.tsv XATTR.tsv"""
import os, stat, sys

tree, inv, xat = sys.argv[1:4]
ents = [l.rstrip("\n").split("\t") for l in open(inv, errors="surrogateescape")]
bad = 0
for p, t, mo, u, g, tg in sorted(ents, key=lambda e: -e[0].count("/")):
    fp = tree + p if p != "/" else tree
    if not os.path.lexists(fp):
        print("MISSING", p); bad += 1; continue
    os.lchown(fp, int(u), int(g))
    if t != "l":
        os.chmod(fp, int(mo, 8))
for l in open(xat, errors="surrogateescape"):
    p, n, h = l.rstrip("\n").split("\t")
    os.setxattr(tree + p, n, bytes.fromhex(h), follow_symlinks=False)
for p, t, mo, u, g, tg in ents:
    fp = tree + p if p != "/" else tree
    if not os.path.lexists(fp):
        continue
    s = os.lstat(fp)
    tt = {stat.S_IFDIR: "d", stat.S_IFREG: "f", stat.S_IFLNK: "l", stat.S_IFCHR: "c", stat.S_IFBLK: "b", stat.S_IFIFO: "p", stat.S_IFSOCK: "s"}[stat.S_IFMT(s.st_mode)]
    ok = tt == t and s.st_uid == int(u) and s.st_gid == int(g) and (t == "l" or stat.S_IMODE(s.st_mode) == int(mo, 8))
    if t == "l" and os.readlink(fp) != tg:
        ok = False
    if not ok:
        print("DIFF", p, tt, oct(s.st_mode), s.st_uid, s.st_gid, "| inv", t, mo, u, g); bad += 1
for l in open(xat, errors="surrogateescape"):
    p, n, h = l.rstrip("\n").split("\t")
    if os.getxattr(tree + p, n, follow_symlinks=False) != bytes.fromhex(h):
        print("XATTR", p, n); bad += 1
n = sum(len(fs) + len(ds) for _, ds, fs in os.walk(tree))
print(f"bad {bad} inventory {len(ents)} tree {n + 1}")
sys.exit(1 if bad else 0)
