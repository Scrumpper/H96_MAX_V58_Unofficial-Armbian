#!/usr/bin/env python3
"""Offline repo index for image: base Packages minus libmali, plus add debs. Usage: repo-build.py BASE_PACKAGES OUTDIR [ADD.deb ...]
Writes OUTDIR/Packages, Packages.gz, drop.list (files to delete), add.sha256 (files to copy). Release signed by repo-sign.py."""
import gzip, hashlib, os, re, subprocess, sys

base, out, adds = sys.argv[1], sys.argv[2], sys.argv[3:]
body = open(base, encoding="utf-8").read()
stz = [s.strip("\n") for s in body.split("\n\n") if s.strip()]


def field(s, k):
    m = re.search(rf"^{k}: (.+)$", s, re.M)
    return m.group(1) if m else ""


drop = [s for s in stz if field(s, "Package").startswith("libmali")]
keep = [s for s in stz if s not in drop]
for s in keep:
    if re.search(r"^(Depends|Pre-Depends):.*\blibmali", s, re.M):
        sys.exit("kept stanza depends on libmali")
have = {(field(s, "Package"), field(s, "Architecture")): s for s in keep}
added = []
for deb in adds:
    # dpkg-scanpackages stanza, Filename rewritten to flat ./name
    r = subprocess.run(["dpkg-scanpackages", "-m", deb, "/dev/null"], capture_output=True, text=True, check=True)
    s = r.stdout.strip("\n")
    s = re.sub(r"^Filename: .*$", f"Filename: ./{os.path.basename(deb)}", s, flags=re.M)
    key = (field(s, "Package"), field(s, "Architecture"))
    old = have.get(key)
    if old and field(old, "SHA256") == field(s, "SHA256"):
        print(f"skip {os.path.basename(deb)}: already in repo")
        continue
    if old:
        sys.exit(f"{key[0]} {field(old, 'Version')} in repo differs from add {field(s, 'Version')}")
    keep.append(s); have[key] = s; added.append(deb)
sorted_in = [field(s, "Package") for s in stz] == sorted(field(s, "Package") for s in stz)
if added and sorted_in:
    keep.sort(key=lambda s: field(s, "Package"))
pk = ("\n\n".join(keep) + "\n").encode()
if body.endswith("\n\n"):
    pk += b"\n"
os.makedirs(out, exist_ok=True)
open(f"{out}/Packages", "wb").write(pk)
open(f"{out}/Packages.gz", "wb").write(gzip.compress(pk, 9, mtime=0))
open(f"{out}/drop.list", "w").write("".join(field(s, "Filename")[2:] + "\n" for s in drop))
with open(f"{out}/add.sha256", "w") as f:
    for d in added:
        f.write(f"{hashlib.sha256(open(d, 'rb').read()).hexdigest()}  {os.path.basename(d)}\n")
print(f"stanzas {len(stz)} -> {len(keep)}; dropped {len(drop)}; added {len(added)}; "
      f"Packages {hashlib.sha256(pk).hexdigest()}")
