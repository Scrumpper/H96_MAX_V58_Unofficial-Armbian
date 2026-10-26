#!/usr/bin/env python3
"""sha256 of every regular file of an ext4 image through debugfs cat (read only). Usage: e2sums.py IMAGE?offset=N INV.tsv"""
import hashlib, subprocess, sys
img, inv = sys.argv[1:3]
for line in open(inv, errors="surrogateescape"):
    p, t = line.split("\t")[:2]
    if t != "f": continue
    r = subprocess.run(["debugfs", "-R", 'cat "%s"' % p.replace('"', '\\"'), img], capture_output=True)
    print(hashlib.sha256(r.stdout).hexdigest(), p)
