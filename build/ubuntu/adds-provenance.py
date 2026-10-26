#!/usr/bin/env python3
"""Each add deb must be listed (Package, Version, SHA256) in an Ubuntu arm64 Packages index whose InRelease verifies
with ubuntu-archive-keyring. Usage: adds-provenance.py IDXDIR DEB... (IDXDIR: InRelease-<suite>, P-<suite>-<comp>.xz)."""
import glob, hashlib, lzma, os, re, subprocess, sys

idx, debs = sys.argv[1], sys.argv[2:]
KR = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
known, bad = {}, 0
for ir in sorted(glob.glob(f"{idx}/InRelease-*")):
    suite = ir.split("InRelease-", 1)[1]
    r = subprocess.run(["gpgv", "--keyring", KR, ir], capture_output=True, text=True)
    if r.returncode:
        print(f"FAIL gpgv {os.path.basename(ir)}"); bad = 1; continue
    txt = open(ir, encoding="utf-8").read()
    sums = dict((p, h) for h, _, p in re.findall(r"^ ([0-9a-f]{64})\s+(\d+)\s+(\S+)$", txt.split("SHA256:", 1)[1], re.M))
    for px in sorted(glob.glob(f"{idx}/P-{suite}-*.xz")):
        comp = px[len(f"{idx}/P-{suite}-"):-3]
        if comp.count("-"):
            continue
        data = open(px, "rb").read()
        if sums.get(f"{comp}/binary-arm64/Packages.xz") != hashlib.sha256(data).hexdigest():
            print(f"FAIL {os.path.basename(px)} not in signed InRelease"); bad = 1; continue
        for s in lzma.decompress(data).decode("utf-8").split("\n\n"):
            f = dict(re.findall(r"^(Package|Version|SHA256): (.+)$", s, re.M))
            if "SHA256" in f:
                known[f["SHA256"]] = (f["Package"], f["Version"], f"{suite}/{comp}")
for d in debs:
    h = hashlib.sha256(open(d, "rb").read()).hexdigest()
    pv = subprocess.run(["dpkg-deb", "-f", d, "Package", "Version"], capture_output=True, text=True).stdout.split("\n")
    pv = (pv[0].split(": ", 1)[1], pv[1].split(": ", 1)[1])
    k = known.get(h)
    if k and k[:2] == pv:
        print(f"ok {os.path.basename(d)} in {k[2]}")
    else:
        print(f"FAIL {os.path.basename(d)} not in signed Ubuntu index"); bad = 1
sys.exit(bad)
