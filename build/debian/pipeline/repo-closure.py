#!/usr/bin/env python3
"""Debian edition copy of rc-r15 repo-closure.py (None-version guard).
Depends closure against dpkg status plus flat repo Packages (arm64/all; Conflicts not checked).
Usage: repo-closure.py STATUS PACKAGES [--deb X.deb ...] [--want NAME ...] [--files]
--deb: control of local debs (their Depends are wanted, they count as available). --want: package names.
Prints 'missing ...' lines (rc 1) or the repo packages to install (--files: their Filename, dependencies first)."""
import re, subprocess, sys

a = sys.argv[1:]
status, packages = a[0], a[1]
debs, wants, files, mode = [], [], False, None
for x in a[2:]:
    if x in ("--deb", "--want"):
        mode = x
    elif x == "--files":
        files = True
    elif mode == "--deb":
        debs.append(x)
    elif mode == "--want":
        wants.append(x)


def stanzas(text):
    for s in text.split("\n\n"):
        d, k = {}, None
        for ln in s.splitlines():
            if ln[:1] in (" ", "\t") and k:
                continue
            if ":" in ln:
                k, v = ln.split(":", 1)
                d[k] = v.strip()
        if d.get("Package"):
            yield d


def vcmp(v1, op, v2):
    o = {">=": "ge", "<=": "le", ">>": "gt", "<<": "lt", "=": "eq"}[op]
    return subprocess.run(["dpkg", "--compare-versions", v1, o, v2]).returncode == 0


def deps(d):
    out = []
    for f in ("Pre-Depends", "Depends"):
        for grp in filter(None, (g.strip() for g in d.get(f, "").split(","))):
            alts = []
            for alt in grp.split("|"):
                m = re.match(r"\s*([^\s(:]+)(?::\S+)?\s*(?:\(\s*(>=|<=|>>|<<|=)\s*([^)\s]+)\s*\))?", alt)
                alts.append((m.group(1), m.group(2), m.group(3)))
            out.append(alts)
    return out


def provides(d):
    for p in filter(None, (x.strip() for x in d.get("Provides", "").split(","))):
        m = re.match(r"([^\s(:]+)(?:\s*\(\s*=\s*([^)\s]+)\s*\))?", p)
        yield m.group(1), m.group(2)


inst, repo = {}, {}
for d in stanzas(open(status, encoding="utf-8").read()):
    if d.get("Status", "").endswith(" installed"):
        inst.setdefault(d["Package"], []).append((d["Version"], d))
        for n, v in provides(d):
            inst.setdefault(n, []).append((v, None))
local = []
for deb in debs:
    c = subprocess.run(["dpkg-deb", "-f", deb], capture_output=True, text=True, check=True).stdout
    d = next(stanzas(c)); d["Filename"] = deb; local.append(d)
for d in list(stanzas(open(packages, encoding="utf-8").read())) + local:
    if d.get("Architecture") not in ("arm64", "all"):
        continue
    repo.setdefault(d["Package"], []).append((d["Version"], d))
    for n, v in provides(d):
        repo.setdefault(n, []).append((v, d))


def ok(cands, op, ver):
    return [(v, d) for v, d in cands if not op or (v is not None and vcmp(v, op, ver))]


chosen, order, missing = {}, [], []


def need(alts, why):
    for n, op, ver in alts:
        if ok(inst.get(n, []), op, ver):
            return
    for n, op, ver in alts:
        if any(d is not None and d["Package"] in chosen for _, d in ok(repo.get(n, []), op, ver)):
            return
    for n, op, ver in alts:
        c = ok(repo.get(n, []), op, ver)
        if c:
            v, d = max(c, key=lambda t: t[0] or "")
            for v2, d2 in c:  # Debian copy: unversioned Provides (None) never win over a real version
                if v2 is not None and (v is None or vcmp(v2, ">>", v)):
                    v, d = v2, d2
            add(d)
            return
    missing.append(f"missing {' | '.join(n + (f' ({op} {ver})' if op else '') for n, op, ver in alts)} (for {why})")


def add(d):
    if d["Package"] in chosen:
        return
    chosen[d["Package"]] = d
    for alts in deps(d):
        need(alts, d["Package"])
    order.append(d)


for d in local:
    for alts in deps(d):
        need(alts, d["Package"])
for w in wants:
    need([(w, None, None)], "want")
for m in missing:
    print(m)
for d in order:
    if d in local:
        continue
    print(d["Filename"].removeprefix("./") if files else f"{d['Package']} {d['Version']}")
sys.exit(1 if missing else 0)
