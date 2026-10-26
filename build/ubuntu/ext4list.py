#!/usr/bin/env python3
# r14-laptop: metadata listings of an ext4 image (debugfs, read only) or a tree (in user namespace), compare, fix up rdump trees.
# Usage: ext4list.py img IMG OUT [--content] [--xattr-dir D] | tree ROOT OUT [--content] | cmp A B [--no-ns] [--skip-xattr-from FILE]
#        | fixup ROOT LISTING XATTRDIR DEVOUT | settimes IMG TREELIST | mkdev IMG LISTING  (debugfs -w)
import hashlib, os, re, shutil, stat, subprocess, sys, tempfile

COLS = "path type perm uid gid size target mtime mtime_ns hl xattrs sha".split()
TYP = {0o140000: 's', 0o120000: 'l', 0o100000: 'f', 0o060000: 'b', 0o040000: 'd', 0o020000: 'c', 0o010000: 'p'}
SKIP = ()  # lost+found included: mke2fs -d reuses it and copies tree attributes
ENV = dict(os.environ, DEBUGFS_PAGER='__none__', PAGER='__none__')


def skip(p):
    return any(p == s or p.startswith(s + '/') for s in SKIP)


def debugfs(img, cmds, write=False):
    with tempfile.NamedTemporaryFile('w', delete=False) as f:
        f.write('\n'.join(cmds) + '\n')
    try:
        r = subprocess.run(['debugfs'] + (['-w'] if write else []) + ['-f', f.name, img], capture_output=True, env=ENV)
    finally:
        os.unlink(f.name)
    return r.stdout.decode('utf-8', 'surrogateescape'), r.stderr.decode('utf-8', 'surrogateescape')


def split_out(out):
    # debugfs echoes each command as "debugfs: cmd"; blocks in command order
    blocks, cur = [], None
    for line in out.split('\n'):
        if line.startswith('debugfs: '):
            cur = []; blocks.append(cur)
        elif cur is not None:
            cur.append(line)
    return blocks


def sha_file(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def xsig(items):
    return ';'.join('%s=%s' % (n, hashlib.sha256(v).hexdigest()[:16]) for n, v in sorted(items)) or '-'


def img_list(img, content=False, xdir=None):
    ents = {}  # path -> ino
    q = [('/', 2)]; ents['/'] = 2
    while q:
        out, _ = debugfs(img, ['ls -p <%d>' % i for _, i in q])
        blocks = split_out(out); nq = []
        assert len(blocks) == len(q), 'ls block count'
        for (dp, _), bl in zip(q, blocks):
            for line in bl:
                if not line.startswith('/'):
                    continue
                parts = line[1:-1].split('/')
                if len(parts) != 6:
                    raise SystemExit('bad ls line %r' % line)
                ino, mode, name = int(parts[0]), int(parts[1], 8), parts[4]
                if name in ('.', '..') or ino == 0:  # empty dirent
                    continue
                p = (dp.rstrip('/') + '/' + name)
                if skip(p):
                    continue
                ents[p] = ino
                if stat.S_ISDIR(mode):
                    nq.append((p, ino))
        q = nq
    inos = sorted(set(ents.values()))
    st = {}
    for k in range(0, len(inos), 5000):
        chunk = inos[k:k + 5000]
        out, _ = debugfs(img, ['stat <%d>' % i for i in chunk])
        for i, bl in zip(chunk, split_out(out)):
            t = '\n'.join(bl); d = {}
            m = re.search(r'Type: (\S+)\s+Mode:\s+(\d+)', t); d['perm'] = int(m.group(2), 8)
            d['typ'] = {'regular': 'f', 'directory': 'd', 'symlink': 'l', 'character': 'c', 'block': 'b', 'FIFO': 'p', 'socket': 's'}.get(m.group(1), '?')
            m = re.search(r'User:\s+(\d+)\s+Group:\s+(\d+).*Size: (\d+)', t); d['uid'], d['gid'], d['size'] = m.groups()
            d['links'] = int(re.search(r'Links: (\d+)', t).group(1))
            m = re.search(r'\n mtime: 0x([0-9a-f]+)(?::([0-9a-f]+))?', t)
            sec = int(m.group(1), 16); ex = int(m.group(2) or '0', 16)
            sec = sec - (1 << 32) if sec >= 1 << 31 else sec
            d['mtime'] = sec + ((ex & 3) << 32); d['ns'] = ex >> 2
            m = re.search(r'Fast link dest: "(.*)"', t); d['fast'] = m.group(1) if m else None
            m = re.search(r'Device major/minor number: (\d+):(\d+)', t); d['dev'] = '%s:%s' % m.groups() if m else None
            d['hasx'] = 'Extended attributes:' in t
            st[i] = d
    tmp = tempfile.mkdtemp(prefix='e4l.', dir=os.environ.get('E4L_TMP'))
    try:
        return _finish(img, ents, st, tmp, content, xdir)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _finish(img, ents, st, tmp, content, xdir):
    # slow symlinks, xattrs, content: per inode via dump / ea_get to temp files
    typ = {i: d['typ'] for i, d in st.items()}
    slow = [i for i in st if typ[i] == 'l' and st[i]['fast'] is None]
    tgt = {}
    if slow:
        debugfs(img, ['dump <%d> %s/l%d' % (i, tmp, i) for i in slow])
        for i in slow:
            with open('%s/l%d' % (tmp, i), 'rb') as f:
                tgt[i] = f.read().decode('utf-8', 'surrogateescape')
    xs = {}
    xin = [i for i in st if st[i]['hasx']]
    if xin:
        out, _ = debugfs(img, ['ea_list <%d>' % i for i in xin])
        names = {}
        for i, bl in zip(xin, split_out(out)):
            names[i] = [m.group(1) for m in (re.match(r'Extended attributes:', l) or re.match(r'\s+(\S+) \(\d+\)', l) for l in bl) if m and m.groups()]
        cmds, keys = [], []
        for i in xin:
            for n in names[i]:
                fn = '%s/x%d.%d' % (tmp, i, len(keys)); keys.append((i, n, fn)); cmds.append('ea_get -f %s <%d> %s' % (fn, i, n))
        debugfs(img, cmds)
        for i, n, fn in keys:
            with open(fn, 'rb') as f:
                v = f.read()
            xs.setdefault(i, []).append((n, v))
            if xdir:
                os.makedirs(xdir, exist_ok=True)
                with open('%s/%d.%s' % (xdir, i, n), 'wb') as f:
                    f.write(v)
    shas = {}
    if content:
        regs = sorted(i for i in st if typ[i] == 'f')
        for k in range(0, len(regs), 2000):
            chunk = regs[k:k + 2000]
            debugfs(img, ['dump <%d> %s/f%d' % (i, tmp, i) for i in chunk])
            for i in chunk:
                fn = '%s/f%d' % (tmp, i); shas[i] = sha_file(fn); os.unlink(fn)
    groups = {}
    for p, i in ents.items():
        if typ[i] == 'f' and st[i]['links'] > 1:
            groups.setdefault(i, []).append(p)
    rows = []
    for p, i in ents.items():
        d, t = st[i], typ[i]
        target = d['fast'] if d['fast'] is not None else tgt.get(i, '-') if t == 'l' else d['dev'] if t in 'cb' else '-'
        rows.append([p, t, '%04o' % (d['perm'] & 0o7777), d['uid'], d['gid'], d['size'] if t in 'fl' else '-', target,
                     str(d['mtime']), str(d['ns']), min(groups[i]) if i in groups and len(groups[i]) > 1 else '-',
                     xsig(xs.get(i, [])), shas.get(i, '-') if t == 'f' else '-', str(i)])
    return rows


def tree_list(root, content=False):
    rows, groups, recs = [], {}, []
    for dp, dns, fns in os.walk(root):
        dns.sort()
        for n in [None] + sorted(dns + fns):
            full = dp if n is None else os.path.join(dp, n)
            if n is None and dp != root:
                continue
            rel = '/' + os.path.relpath(full, root) if full != root else '/'
            rel = rel.replace('/./', '/') if rel != '/.' else '/'
            if skip(rel):
                if n in dns:
                    dns.remove(n)
                continue
            s = os.lstat(full); t = TYP[stat.S_IFMT(s.st_mode)]
            try:
                xn = os.listxattr(full, follow_symlinks=False)
            except OSError:
                xn = []
            xv = [(x, os.getxattr(full, x, follow_symlinks=False)) for x in xn]
            target = os.readlink(full) if t == 'l' else '%d:%d' % (os.major(s.st_rdev), os.minor(s.st_rdev)) if t in 'cb' else '-'
            sha = sha_file(full) if content and t == 'f' else '-'
            size = str(len(os.fsencode(target))) if t == 'l' else str(s.st_size) if t == 'f' else '-'
            if t == 'f' and s.st_nlink > 1:
                groups.setdefault((s.st_dev, s.st_ino), []).append(rel)
            recs.append([rel, t, '%04o' % stat.S_IMODE(s.st_mode), str(s.st_uid), str(s.st_gid), size, target,
                         str(s.st_mtime_ns // 10**9), str(s.st_mtime_ns % 10**9), (s.st_dev, s.st_ino) if t == 'f' and s.st_nlink > 1 else None,
                         xsig(xv), sha, '-'])
    for r in recs:
        g = r[9]; r[9] = min(groups[g]) if g and len(groups[g]) > 1 else '-'
        rows.append(r)
    return rows


def write(rows, out):
    rows.sort(key=lambda r: r[0].encode('utf-8', 'surrogateescape'))
    with open(out, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write('#' + '\t'.join(COLS + ['ino']) + '\n')
        for r in rows:
            f.write('\t'.join(r) + '\n')
    print('%s: %d entries' % (out, len(rows)))


def read(fn):
    d = {}
    with open(fn, encoding='utf-8', errors='surrogateescape') as f:
        for line in f:
            if line.startswith('#'):
                continue
            r = line.rstrip('\n').split('\t'); d[r[0]] = r
    return d


def cmp(a, b, no_ns=False, quiet=False):
    A, B = read(a), read(b); bad = 0
    idx = range(1, 12)
    for p in sorted(set(A) | set(B)):
        if p not in A or p not in B:
            print('%s %s' % ('ONLY-A' if p in A else 'ONLY-B', p)); bad += 1; continue
        ra, rb = A[p], B[p]
        diffs = [COLS[k] for k in idx if not (COLS[k] == 'mtime_ns' and no_ns) and not (COLS[k] == 'sha' and '-' in (ra[k], rb[k]))
                 and ra[k] != rb[k]]
        if diffs:
            bad += 1
            if not quiet or bad <= 50:
                print('DIFF %s %s' % (p, ' '.join('%s:%s|%s' % (c, ra[COLS.index(c)], rb[COLS.index(c)]) for c in diffs)))
    print('cmp %s vs %s: entries %d/%d bad=%d' % (os.path.basename(a), os.path.basename(b), len(A), len(B), bad))
    return bad


def fixup(root, listing, xdir, devout):
    L = read(listing); devs = []
    j = lambda p: root + p if p != '/' else root
    # pass 1: specials and hard links
    for p, r in sorted(L.items()):
        t = r[1]
        if t in 'cb':
            devs.append(r); continue
        if t in 'ps' and not os.path.lexists(j(p)):
            os.mknod(j(p), (stat.S_IFIFO if t == 'p' else stat.S_IFSOCK) | 0o600)
        if t == 'f' and r[9] != '-' and r[9] != p:
            os.unlink(j(p)); os.link(j(r[9]), j(p))
    # pass 2: owner, mode (after chown: chown clears setuid), xattrs
    for p, r in sorted(L.items()):
        if r[1] in 'cb':
            continue
        f = j(p)
        os.chown(f, int(r[3]), int(r[4]), follow_symlinks=False)
        if r[1] != 'l':
            os.chmod(f, int(r[2], 8))
        if r[10] != '-':
            for n in [x.split('=')[0] for x in r[10].split(';')]:
                with open('%s/%s.%s' % (xdir, r[12], n), 'rb') as fh:
                    os.setxattr(f, n, fh.read(), follow_symlinks=False)
    # pass 3: times, deepest first so directory mtimes stick
    for p, r in sorted(L.items(), key=lambda kv: -kv[0].count('/')):
        if r[1] in 'cb':
            continue
        ns = int(r[7]) * 10**9 + int(r[8])
        os.utime(j(p), ns=(ns, ns), follow_symlinks=False)
    with open(devout, 'w') as f:
        for r in devs:
            f.write('\t'.join(r) + '\n')
    print('fixup: %d entries, %d device nodes deferred' % (len(L), len(devs)))


def settimes(img, tree):
    # mke2fs -d drops mtime nanoseconds and root dir mtime; set both from tree listing
    T = read(tree); cmds = []
    for r in img_list(img):
        t = T.get(r[0])
        if t is None or (t[7], t[8]) == (r[7], r[8]):
            continue
        sec, ns = int(t[7]), int(t[8])
        cmds += ['sif <%s> mtime @%d' % (r[12], sec), 'sif <%s> mtime_extra %d' % (r[12], (ns << 2) | ((sec - ((sec + 2**31) % 2**32 - 2**31)) >> 32 & 3))]
    if cmds:
        out, err = debugfs(img, cmds, write=True)
        if err.strip().count('\n') > 1:
            print(err[-2000:])
    print('settimes: %d inodes' % (len(cmds) // 2))


def mkdev(img, devfile):
    cmds = []
    for line in open(devfile):
        r = line.rstrip('\n').split('\t'); p, t = r[0], r[1]; ma, mi = r[6].split(':')
        cmds += ['mknod "%s" %s %s %s' % (p, t, ma, mi), 'sif "%s" uid %s' % (p, r[3]), 'sif "%s" gid %s' % (p, r[4]),
                 'sif "%s" mode 0%o' % (p, (stat.S_IFCHR if t == 'c' else stat.S_IFBLK) | int(r[2], 8)),
                 'sif "%s" mtime %s' % (p, r[7])]
    if cmds:
        out, err = debugfs(img, cmds, write=True); print(out, err)
    print('mkdev: %d nodes' % (len(cmds) // 5))


if __name__ == '__main__':
    a = sys.argv[1:]; m = a[0]
    opt = lambda k: a[a.index(k) + 1] if k in a else None
    if m == 'img':
        write(img_list(a[1], '--content' in a, opt('--xattr-dir')), a[2])
    elif m == 'tree':
        write(tree_list(a[1], '--content' in a), a[2])
    elif m == 'cmp':
        sys.exit(1 if cmp(a[1], a[2], '--no-ns' in a, '--quiet' in a) else 0)
    elif m == 'fixup':
        fixup(a[1], a[2], a[3], a[4])
    elif m == 'settimes':
        settimes(a[1], a[2])
    elif m == 'mkdev':
        mkdev(a[1], a[2])
    else:
        sys.exit(2)
