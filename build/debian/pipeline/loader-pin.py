#!/usr/bin/env python3
# Pinned loader step on a built image file (laptop only): FIT at 16384, spare FIT at 20480 (old for A1, A1 for B sets), idbloader at 64 for B sets.
# Usage: loader-pin.py IMG SET RUNBOOK_DIR CHECKER   (SET: old | A1 | B1 | B2; B sets need H96_LOADER_ALLOW_B=1)
import hashlib, os, subprocess, sys, tempfile

S = 512
AREA = 32768                      # loader area read back and checked (16 MiB)
FORBID = [(0, 33), (7168, 7679)]  # GPT and vendor storage: never written
ALLOW = [(64, 7167), (16384, 32703)]  # 32704..32767 = U-Boot env slot, left alone
CHECKER_SHA = '113908b30102ba54fbdca00c5c64e492a50ef064472d31fce4e18e013b848629'
F = {  # name: (sha256, sectors)
    'old-idbloader.img': ('5b26987186343051b3a2a3f12f6710e4f12e5d8629eba534e642b90b5816e8d4', 556),
    'old-u-boot.itb': ('5cd0e166332355fcf4c540b3e16a4655452b2ab3803499f99c0f7fbde4d0ef0d', 2638),
    'A1-u-boot.itb': ('05dca3609fb4698afc67ee9ffe2ca8d1919cd4c4a5b7772f61bd566227e0686d', 2638),
    'B1-idbloader.img': ('8f56ba4a317c0b1a35f5d6ddf70821c5fdd0caface79b9a54d6fc9013296fdf4', 576),
    'B1-u-boot.itb': ('bfb15b9273adff9a971c68eab29b2cc43019e4abf8f5d15ee390f2db931ab03c', 2674),
    'B2-idbloader.img': ('9af4d0f64cf500a151d6f063a7d07a94deaba3a1d6bbbfc7f34fff3da802b83f', 584),
    'B2-u-boot.itb': ('401f14f4128306937d1bb9bf46356eb0edc42dc3ec3fc11e20426b8255cbec52', 2565),
}
# set: idbloader at 64, FIT at 16384, slot at 20480 (None = zero)
SETS = {
    'old': ('old-idbloader.img', 'old-u-boot.itb', None),
    'A1': ('old-idbloader.img', 'A1-u-boot.itb', 'old-u-boot.itb'),
    'B1': ('B1-idbloader.img', 'B1-u-boot.itb', 'A1-u-boot.itb'),
    'B2': ('B2-idbloader.img', 'B2-u-boot.itb', 'A1-u-boot.itb'),
}
BASE = SETS['old']  # loader area of a built image before this step


def sha(b): return hashlib.sha256(b).hexdigest()


def die(m): print(f'FAIL {m}'); sys.exit(1)


def load(d, name):
    want, n = F[name]
    b = open(os.path.join(d, name), 'rb').read()
    if len(b) != n * S: die(f'{name} length {len(b)}, want {n * S}')
    if sha(b) != want: die(f'{name} sha {sha(b)}, want {want}')
    return b


def image_sums(path):
    full, tail = hashlib.sha256(), hashlib.sha256()
    with open(path, 'rb') as f:
        head = f.read(AREA * S); full.update(head)
        while (c := f.read(1 << 24)): full.update(c); tail.update(c)
    return head, full.hexdigest(), tail.hexdigest()


def check(head, gpt, s, label, quiet=False):
    idb, fit, slot = s
    with tempfile.TemporaryDirectory(prefix='h96-loader-') as t:
        hp, gp = os.path.join(t, 'head16M.bin'), os.path.join(t, 'gpt34.bin')
        open(hp, 'wb').write(head); open(gp, 'wb').write(gpt)
        cmd = [sys.executable, '-I', CHECKER, hp, '--image', '--gpt', gp,
               '--fit', F[fit][0], '--fit-sectors', str(F[fit][1]),
               '--idb', F[idb][0], '--idb-sectors', str(F[idb][1]),
               '--slot', {None: 'zero', 'old-u-boot.itb': 'oldfit', 'A1-u-boot.itb': 'a1fit'}[slot]]
        r = subprocess.run(cmd, capture_output=True, text=True)
    if quiet: return r.returncode == 0
    print(f'== checker ({label}): {" ".join(cmd[2:3] + cmd[4:])}')
    print(r.stdout.rstrip()); r.stderr and print(r.stderr.rstrip())
    return r.returncode == 0


def writes(s):
    idb, fit, slot = s
    out = []  # (sector, file or None, sectors): None = zero tail of base content
    for at, new, old in ((64, idb, BASE[0]), (16384, fit, BASE[1]), (20480, slot, BASE[2])):
        n = F[new][1] if new else 0
        if new and new != old: out.append((at, new, n))  # same file as base: already in place
        o = F[old][1] if old else 0
        if o > n: out.append((at + n, None, o - n))
    return out


if len(sys.argv) != 5: print(open(__file__).read().splitlines()[2]); sys.exit(2)
IMG, SET, RB, CHECKER = sys.argv[1:]
if SET not in SETS: die(f'loader set {SET} unknown ({" ".join(SETS)})')
if SET.startswith('B') and os.environ.get('H96_LOADER_ALLOW_B') != '1':
    die(f'loader set {SET} not box-proven (stage B); H96_LOADER_ALLOW_B=1 only after stage B passes on box')
if sha(open(CHECKER, 'rb').read()) != CHECKER_SHA: die(f'checker sha differs from pin {CHECKER_SHA[:16]}')
if os.path.realpath(IMG).startswith('/boot'): die('refuse /boot path')
blobs = {n: load(RB, n) for n in {x for x in SETS[SET] + BASE if x}}
print(f'PASS files: {" ".join(sorted(blobs))} (length + sha pins)')

head, full0, tail0 = image_sums(IMG)
gpt = head[:34 * S]
print(f'image {IMG}: sha {full0}, gpt34 sha {sha(gpt)[:16]}')
if check(head, gpt, SETS[SET], f'target {SET}, before', quiet=True):
    print(f'PASS image already carries loader set {SET}; nothing written'); sys.exit(0)
print(f'loader set {SET} not present yet')
if not check(head, gpt, BASE, 'base (old set), before'): die('image loader area is neither base nor target; nothing written')

plan = writes(SETS[SET])
for at, name, n in plan:
    lo, hi = at, at + n - 1
    if any(lo <= fh and hi >= fl for fl, fh in FORBID): die(f'write {lo}..{hi} hits forbidden range')
    if not any(al <= lo and hi <= ah for al, ah in ALLOW): die(f'write {lo}..{hi} outside allowed ranges')
with open(IMG, 'r+b') as f:
    for at, name, n in plan:
        data = blobs[name] if name else bytes(n * S)
        assert len(data) == n * S
        f.seek(at * S); f.write(data)
        print(f'wrote {at}..{at + n - 1} ({n} sectors) {name or "zero (base tail)"}')
    f.flush(); os.fsync(f.fileno())

head1, full1, tail1 = image_sums(IMG)
ok = check(head1, gpt, SETS[SET], f'target {SET}, after')
if head1[:34 * S] != gpt: ok = False; print('FAIL GPT changed')
if head1[7168 * S:7680 * S] != head[7168 * S:7680 * S]: ok = False; print('FAIL vendor storage range changed')
if tail1 != tail0: ok = False; print('FAIL image beyond sector 32767 changed')
else: print('PASS image beyond sector 32767 unchanged')
if not ok: die('post-write check; image left as written, rebuild from pull')
print(f'PASS loader set {SET} pinned; image sha {full0} -> {full1}')
print(f'SHA {full1}')
