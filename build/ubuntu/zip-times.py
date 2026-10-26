#!/usr/bin/env python3
"""Copy member mtimes and modes from a published release zip onto the staged release folder, so stage-and-zip.py
writes a byte-equal zip. Run this and stage-and-zip.py under the same TZ. Usage: zip-times.py PUBLISHED.zip FOLDER [--partial]
--partial: folder holds a subset (sealed build folder: stage-and-zip.py copies its files with their mtimes)."""
import os, sys, time, zipfile

if len(sys.argv) not in (3, 4) or sys.argv[3:] not in ([], ["--partial"]):
    sys.exit(__doc__)
z, d, part = sys.argv[1], sys.argv[2], sys.argv[3:] == ["--partial"]
n = 0
for i in zipfile.ZipFile(z).infolist():
    p = os.path.join(d, i.filename.split("/", 1)[1])
    if not os.path.isfile(p):
        if part:
            continue
        sys.exit(f"missing {p}")
    os.chmod(p, (i.external_attr >> 16) & 0o7777)
    t = time.mktime(i.date_time + (0, 0, -1))
    os.utime(p, (t, t)); n += 1
extra = set(os.listdir(d)) - {i.filename.split("/", 1)[1] for i in zipfile.ZipFile(z).infolist()}
if extra and not part:
    sys.exit(f"files not in published zip: {sorted(extra)}")
print(f"set mtime and mode on {n} files")
