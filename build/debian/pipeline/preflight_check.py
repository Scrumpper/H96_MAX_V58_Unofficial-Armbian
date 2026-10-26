#!/usr/bin/env python3
# Laptop-side check of a 16 MiB eMMC read (`rkdeveloptool rl 0 32768`) or image head against the loader-trial expectations; read only.
import sys, hashlib, argparse

SECTOR = 512
EXPECT = {  # inclusive sector ranges: (sha256 of the range, label); None = must be all zero
    (0, 33): (None, 'GPT (compared with --gpt file)'),
    (34, 63): ('zero', 'gap before idbloader'),
    (64, 619): ('5b26987186343051b3a2a3f12f6710e4f12e5d8629eba534e642b90b5816e8d4', 'idbloader (old, 556 sectors)'),
    (620, 7167): ('zero', 'gap after idbloader'),
    (7168, 7679): ('vendor', 'Rockchip vendor storage (saved, never compared, never written)'),
    (7680, 16383): ('zero', 'gap before FIT'),
    (16384, 19021): ('5cd0e166332355fcf4c540b3e16a4655452b2ab3803499f99c0f7fbde4d0ef0d', 'U-Boot FIT (old, 2638 sectors)'),
    (19022, 20479): ('zero', 'gap after FIT'),
    (20480, 23117): ('zero-or-oldfit', 'SPL second-copy slot (zero, old FIT after stage A, A1 FIT after stage B rehearsal)'),
    (23118, 32767): ('zero', 'rest of loader area (U-Boot env slot 32704..32767 inside)'),
}
OLDFIT = '5cd0e166332355fcf4c540b3e16a4655452b2ab3803499f99c0f7fbde4d0ef0d'
A1FIT = '05dca3609fb4698afc67ee9ffe2ca8d1919cd4c4a5b7772f61bd566227e0686d'
ZERO_0XCC = bytes([0xcc]) * SECTOR

def sha(b): return hashlib.sha256(b).hexdigest()

def ranges(secs):
    out = []
    for s in secs:
        if out and out[-1][1] == s - 1: out[-1][1] = s
        else: out.append([s, s])
    return out

ap = argparse.ArgumentParser()
ap.add_argument('read16m', help='file from `rkdeveloptool rl 0 32768` (16777216 B)')
ap.add_argument('--gpt', help='same-box 34-sector GPT backup to compare sectors 0..33 against')
ap.add_argument('--vendor-ref', help='earlier same-box copy of sectors 7168..7679 (512 sectors) for the record')
ap.add_argument('--save-vendor', help='write sectors 7168..7679 of the read to this file')
ap.add_argument('--fit', help='expected sha256 of sectors 16384.. (after a stage write); length from --fit-sectors', default=None)
ap.add_argument('--fit-sectors', type=int, default=2638)
ap.add_argument('--idb', help='expected sha256 of sectors 64.. (after a stage B write)', default=None)
ap.add_argument('--idb-sectors', type=int, default=556)
ap.add_argument('--slot', choices=('any', 'zero', 'oldfit', 'a1fit'), default='any', help='sector 20480 slot: zero, old FIT or A1 FIT (any), or exactly one')
ap.add_argument('--image', action='store_true', help='fresh image head: --gpt required (image GPT), vendor storage must be all zero')
a = ap.parse_args()
if a.image and not a.gpt: ap.error('--image needs --gpt (sectors 0..33 of the same image)')

b = open(a.read16m, 'rb').read()
ok = True
print(f'{a.read16m}: {len(b)} B, sha256 {sha(b)}')
if len(b) != 32768 * SECTOR:
    print(f'FAIL: size is not 16777216 B'); sys.exit(2)
cc = [s for s in range(32768) if b[s*SECTOR:(s+1)*SECTOR] == ZERO_0XCC]
if cc:
    print(f'FAIL: {len(cc)} sectors read as 0xCC fill (failed read / outside window): {ranges(cc)[:5]}'); ok = False

expect = dict(EXPECT)
if a.fit:  # after a stage write the FIT range changes length
    for k in [k for k in expect if k[0] in (16384, 19022)]: del expect[k]
    end = 16384 + a.fit_sectors - 1
    expect[(16384, end)] = (a.fit, f'U-Boot FIT (candidate, {a.fit_sectors} sectors)')
    expect[(end + 1, 20479)] = ('zero', 'gap after FIT')
if a.idb:
    for k in [k for k in expect if k[0] in (64, 620)]: del expect[k]
    end = 64 + a.idb_sectors - 1
    expect[(64, end)] = (a.idb, f'idbloader (candidate, {a.idb_sectors} sectors)')
    expect[(end + 1, 7167)] = ('zero', 'gap after idbloader')

for (lo, hi), (want, label) in sorted(expect.items()):
    data = b[lo*SECTOR:(hi+1)*SECTOR]
    h = sha(data)
    nz = [lo + i for i in range(hi - lo + 1) if any(data[i*SECTOR:(i+1)*SECTOR])]
    if want is None:
        if a.gpt:
            g = open(a.gpt, 'rb').read()
            good = (g == data)
            st = 'OK' if good else 'DIFFERS from --gpt file'
        else:
            good = True; st = 'not compared (no --gpt)'
        print(f'  {lo:>6}..{hi:<6} {label}: sha {h[:16]} {st}')
    elif want == 'zero':
        good = not nz
        print(f'  {lo:>6}..{hi:<6} {label}: {"all zero OK" if good else "NONZERO at sectors " + str(ranges(nz)[:8])}')
    elif want == 'zero-or-oldfit':
        good = {'any': (not nz) or h in (OLDFIT, A1FIT), 'zero': not nz, 'oldfit': h == OLDFIT, 'a1fit': h == A1FIT}[a.slot]
        seen = 'all zero' if not nz else {OLDFIT: 'old FIT', A1FIT: 'A1 FIT'}.get(h, 'UNEXPECTED content, sha ' + h[:16])
        print(f'  {lo:>6}..{hi:<6} {label}: {seen} {"OK" if good else "FAIL (want --slot " + a.slot + ")"}')
    elif want == 'vendor':
        good = not (a.image and nz)
        print(f'  {lo:>6}..{hi:<6} {label}: sha {h[:16]}, nonzero sectors {ranges(nz)}')
        if a.image: print(f'           image mode: {"all zero OK" if good else "NONZERO (fresh image must carry no vendor data)"}')
        if a.vendor_ref:
            r = open(a.vendor_ref, 'rb').read()
            print(f'           vs --vendor-ref: {"equal" if r == data else "different (record; owner decision, outside this trial)"}')
        if a.save_vendor:
            open(a.save_vendor, 'wb').write(data); print(f'           saved to {a.save_vendor}')
    else:
        good = (h == want)
        print(f'  {lo:>6}..{hi:<6} {label}: sha {h[:16]} {"OK" if good else "MISMATCH, want " + want[:16]}')
    ok &= good
print('PASS' if ok else ('FAIL: image loader area not as expected' if a.image else 'FAIL: stop before any write (runbook F4)'))
sys.exit(0 if ok else 1)
