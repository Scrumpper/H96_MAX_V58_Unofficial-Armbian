#!/usr/bin/env python3
"""Each deb must be listed (Package, Version, SHA256) in an apt list whose InRelease verifies with the given keyring(s)
and whose Packages file sha256 is in that InRelease. Usage: debian-provenance.py LISTSDIR KEYRING[,KEYRING] DEB...
LISTSDIR = copy of /var/lib/apt/lists after apt-get update (uncompressed Packages)."""
import glob, hashlib, os, re, subprocess, sys

lists, krs, debs = sys.argv[1], sys.argv[2].split(","), sys.argv[3:]
known, bad = {}, 0
for ir in sorted(glob.glob(f"{lists}/*_InRelease")):
    base = ir[:-len("InRelease")]
    # good: one Good signature from a given keyring and no BAD one (Armbian signs with two keys, one not given)
    res = [subprocess.run(["gpgv", "--keyring", k, ir], capture_output=True, text=True).stderr for k in krs]
    if not any("Good signature" in e and "BAD signature" not in e for e in res):
        print(f"INFO {os.path.basename(ir)}: no good signature from given keyrings, its lists not used"); continue
    txt = open(ir, encoding="utf-8", errors="replace").read()
    sums = dict((p, h) for h, _, p in re.findall(r"^ ([0-9a-f]{64})\s+(\d+)\s+(\S+)$", txt.split("SHA256:", 1)[1], re.M))
    for pk in glob.glob(base + "*_Packages"):
        rel = pk[len(base):].replace("_", "/")
        data = open(pk, "rb").read()
        if sums.get(rel) != hashlib.sha256(data).hexdigest():
            print(f"FAIL {os.path.basename(pk)} sha not in signed InRelease ({rel})"); bad = 1; continue
        for s in data.decode("utf-8", "replace").split("\n\n"):
            f = dict(re.findall(r"^(Package|Version|SHA256): (.+)$", s, re.M))
            if "SHA256" in f:
                known[f["SHA256"]] = (f["Package"], f["Version"], os.path.basename(pk))
n = 0
for d in debs:
    h = hashlib.sha256(open(d, "rb").read()).hexdigest()
    pv = subprocess.run(["dpkg-deb", "-f", d, "Package", "Version"], capture_output=True, text=True).stdout.split("\n")
    pv = (pv[0].split(": ", 1)[1], pv[1].split(": ", 1)[1])
    k = known.get(h)
    if k and k[:2] == pv:
        n += 1
    else:
        print(f"FAIL {os.path.basename(d)} not in signed index"); bad = 1
print(f"provenance: {n} of {len(debs)} debs listed in signed indexes")
sys.exit(bad)
