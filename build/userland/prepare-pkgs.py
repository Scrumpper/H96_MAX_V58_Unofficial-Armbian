#!/usr/bin/env python3
"""Check pkgs/ against pkgs.manifest, set modes, fill blobs (binary files not in git) from an image root tree.
Usage: prepare-pkgs.py --check | --blobs-from ROOT
ROOT: v8.0 image partition 2 as ext4 file (read with debugfs) or tree (blob at ROOT/<path below pkgs/<name>/root/>)."""
import hashlib, os, shutil, subprocess, sys

H = os.path.dirname(os.path.abspath(__file__))
P = os.path.join(H, "pkgs")
if len(sys.argv) < 2 or sys.argv[1] not in ("--check", "--blobs-from") or (sys.argv[1] == "--blobs-from" and len(sys.argv) != 3):
    sys.exit(__doc__)
root = sys.argv[2] if sys.argv[1] == "--blobs-from" else None
bad = missing = 0
n = {"f": 0, "b": 0, "l": 0}
for line in open(os.path.join(H, "pkgs.manifest"), encoding="utf-8"):
    if line.startswith("#"):
        continue
    kind, mode, sha, size, target, rel = line.rstrip("\n").split("\t")
    dst = os.path.join(P, rel)
    n[kind] += 1
    if kind == "l":
        if not (os.path.islink(dst) and os.readlink(dst) == target):
            print(f"FAIL symlink {rel}"); bad += 1
        continue
    if kind == "b" and root:
        ip = rel.split("/root/", 1)[1]
        src = os.path.join(root, ip)
        if os.path.isfile(root):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            subprocess.run(["debugfs", "-R", f"dump /{ip} {dst}", root], capture_output=True)
        elif os.path.isfile(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copyfile(src, dst)
    if not os.path.isfile(dst):
        if kind == "b":
            missing += 1
        else:
            print(f"FAIL missing {rel}"); bad += 1
        continue
    if hashlib.sha256(open(dst, "rb").read()).hexdigest() != sha:
        print(f"FAIL sha {rel}"); bad += 1; continue
    os.chmod(dst, int(mode, 8))
print(f"text {n['f']} blobs {n['b']} (missing {missing}) symlinks {n['l']} fail {bad}")
sys.exit(1 if bad or (root and missing) else 0)
