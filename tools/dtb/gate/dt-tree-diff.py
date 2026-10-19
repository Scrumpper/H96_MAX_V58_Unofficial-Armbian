#!/usr/bin/env python3
"""Tree-diff gate for overlay-built DTB.

dt-tree-diff.py <reference.sorted.dts> <candidate.sorted.dts> <allowed-residual.txt>

1. Raw line diff of both sorted decompiles.
2. Phandle check: every node whose phandle value differs must be same node
   path in both trees, and every reference line that differs only by that value
   must point at same node path. Such lines are reported as phandle
   renumbering and removed from diff.
3. Residual lines must equal allowed-residual.txt exactly (one line per entry,
   "+ " for candidate-only, "- " for reference-only, then "<node path>: <line>").
Exit 0 on pass, 1 on fail.
"""
import difflib, re, sys

NODE = re.compile(r'^(?:[\w,.-]+:\s*)?(\S+) \{$')
PH = re.compile(r'^phandle = <(0x[0-9a-f]+)>;$')


def parse(path):
    lines = open(path).read().splitlines()
    stack, paths, ph = [], [], {}
    for raw in lines:
        s = raw.strip()
        m = NODE.match(s)
        if m:
            stack.append(m.group(1))
        elif s == '};' and stack:
            stack.pop()
        node = '/' + '/'.join(stack[1:])
        paths.append(node)
        m = PH.match(s)
        if m:
            ph[int(m.group(1), 16)] = node
    return lines, paths, ph


def main():
    ref_f, cand_f, allow_f = sys.argv[1:4]
    a, apath, aph = parse(ref_f)
    b, bpath, bph = parse(cand_f)
    allowed = [l.rstrip('\n') for l in open(allow_f)
               if l.strip() and not l.startswith('#')]
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    renum, residual = [], []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        if tag == 'replace' and (i2 - i1) == (j2 - j1):
            for i, j in zip(range(i1, i2), range(j1, j2)):
                la, lb = a[i].strip(), b[j].strip()
                ta = re.findall(r'0x[0-9a-f]+', la)
                tb = re.findall(r'0x[0-9a-f]+', lb)
                skel_a = re.sub(r'0x[0-9a-f]+', 'N', la)
                skel_b = re.sub(r'0x[0-9a-f]+', 'N', lb)
                ok = (skel_a == skel_b and apath[i] == bpath[j]
                      and len(ta) == len(tb))
                if ok:
                    for xa, xb in zip(ta, tb):
                        if xa == xb:
                            continue
                        pa = aph.get(int(xa, 16))
                        pb = bph.get(int(xb, 16))
                        if pa is None or pa != pb:
                            ok = False
                if ok:
                    renum.append(f'{apath[i]}: {la}  ->  {lb}  '
                                 f'(both resolve to {aph[int(ta[-1],16)] if ta else "?"})')
                else:
                    residual += [f'- {apath[i]}: {la}', f'+ {bpath[j]}: {lb}']
            continue
        residual += [f'- {apath[i]}: {a[i].strip()}' for i in range(i1, i2)]
        residual += [f'+ {bpath[j]}: {b[j].strip()}' for j in range(j1, j2)]
    print(f'reference: {ref_f}\ncandidate: {cand_f}')
    print(f'phandle renumbering lines (same target node in both trees): {len(renum)}')
    for r in renum:
        print('  ' + r)
    print(f'residual difference lines: {len(residual)}')
    for r in residual:
        print('  ' + r)
    if residual == allowed:
        print('GATE: PASS (residual equals allowed list'
              f' of {len(allowed)} lines; phandle renumbering verified)')
        return 0
    print('GATE: FAIL (residual differs from allowed list)')
    for l in difflib.unified_diff(allowed, residual, 'allowed', 'residual',
                                  lineterm=''):
        print('  ' + l)
    return 1


if __name__ == '__main__':
    sys.exit(main())
