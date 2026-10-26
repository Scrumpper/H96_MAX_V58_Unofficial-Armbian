#!/usr/bin/env python3
"""Read-only ext4 inventory through debugfs: every path with type, mode, uid, gid, link target; xattrs of files.
Usage: e2inv.py IMAGE?offset=N OUT.tsv XATTR.tsv
OUT.tsv: path type mode uid gid target ; XATTR.tsv: path name hex"""
import re, subprocess, sys, tempfile

img, out, xout = sys.argv[1:4]


def dbg(cmds):
    with tempfile.NamedTemporaryFile("w", suffix=".cmds", delete=False) as f:
        f.write("\n".join(cmds) + "\n")
        name = f.name
    r = subprocess.run(["debugfs", "-f", name, img], capture_output=True, text=True, errors="surrogateescape")
    return r.stdout


def q(p):
    return '"' + p.replace('"', '\\"') + '"'


ents, todo = [("/", "d", 0o755, 0, 0, "")], ["/"]
while todo:
    res = dbg([f"ls -p {q(d)}" for d in todo])
    blocks = re.split(r"^debugfs: ls -p (.*)$", res, flags=re.M)
    nxt = []
    for i in range(1, len(blocks), 2):
        d = blocks[i].strip()[1:-1].replace('\\"', '"')
        for ln in blocks[i + 1].splitlines():
            m = re.match(r"^/(\d+)/(\d{6})/(\d+)/(\d+)/(.*)/(\d*)/$", ln)
            if not m:
                continue
            ino, mode, uid, gid, name = m.group(1), int(m.group(2), 8), m.group(3), m.group(4), m.group(5)
            if name in (".", "..") or ino == "0":
                continue
            p = (d.rstrip("/") + "/" + name)
            t = {0o04: "d", 0o10: "f", 0o12: "l", 0o02: "c", 0o06: "b", 0o01: "p", 0o14: "s"}.get(mode >> 12, "?")
            ents.append((p, t, mode & 0o7777, int(uid), int(gid), ""))
            if t == "d":
                nxt.append(p)
    todo = nxt
links = [e[0] for e in ents if e[1] == "l"]
tgt = {}
for i in range(0, len(links), 2000):
    res = dbg([f"stat {q(p)}" for p in links[i:i + 2000]])
    for blk in re.split(r"^debugfs: stat ", res, flags=re.M)[1:]:
        p = blk.split("\n", 1)[0].strip()[1:-1].replace('\\"', '"')
        m = re.search(r'Fast link dest: "(.*)"', blk)
        tgt[p] = m.group(1) if m else "?"
slow = [p for p in links if tgt.get(p) == "?"]
for p in slow:  # target in data block: debugfs cat
    r = subprocess.run(["debugfs", "-R", f"cat {q(p)}", img], capture_output=True)
    tgt[p] = r.stdout.decode("utf-8", "surrogateescape")
ents = [(p, t, mo, u, g, tgt.get(p, "") if t == "l" else "") for p, t, mo, u, g, _ in ents]
with open(out, "w", errors="surrogateescape") as f:
    for p, t, mo, u, g, tg in ents:
        f.write(f"{p}\t{t}\t{mo:o}\t{u}\t{g}\t{tg}\n")
files = [e[0] for e in ents if e[1] in ("f", "d")]
with open(xout, "w", errors="surrogateescape") as f:
    for i in range(0, len(files), 3000):
        res = dbg([f"ea_list {q(p)}" for p in files[i:i + 3000]])
        for blk in re.split(r"^debugfs: ea_list ", res, flags=re.M)[1:]:
            p = blk.split("\n", 1)[0].strip()[1:-1].replace('\\"', '"')
            for m in re.finditer(r"^Extended attributes:\n((?:  .*\n?)*)", blk, re.M):
                for ln in m.group(1).splitlines():
                    mm = re.match(r"^  (\S+?)(?: \(\d+\))? = (.*)$", ln)
                    if mm:
                        f.write(f"{p}\t{mm.group(1)}\t{mm.group(2)}\n")
print(f"entries {len(ents)} links {len(links)} files+dirs scanned for xattrs {len(files)}")
