#!/usr/bin/env python3
"""Check published docs against project style rules. Exit 1 on any problem.

    check-docs.py FILE.md ...

Checks prose outside fenced code, inline code, URLs and link targets:
dashes, sentence-opening articles, ship/our/we, filler words, internal revision labels
(allowed in package Version fields only),
LAN addresses, home paths and webmail addresses, unbalanced code fences,
dangling internal links. Private name denylist stays in local pre-commit gate.
"""
import re, sys

FILES = [a for a in sys.argv[1:] if not a.startswith("--")]
if not FILES:
    sys.exit(__doc__)

PROTECT = re.compile(r"`[^`]*`|<[^>]*>|\]\([^)]*\)|https?://\S+")
RULES = [
    ("em/en dash", re.compile(r"[—–]")),
    ("article opens sentence", re.compile(r"(^\s*(?:#{1,6} |[-*] |\d+\. |> |\| )?(?:\*\*)?|[.!?](?:\*\*)?\s+(?:\*\*)?)(The|A|An) [a-z]")),
    ("ship wording", re.compile(r"\bship(s|ped|ping)?\b", re.I)),
    ("our/we", re.compile(r"\b(our|ours|we|we're|we've|us)\b", re.I)),
    ("filler word", re.compile(r"\b(real|really|actual|actually|very|simply|just)\b", re.I)),
    ("internal revision label", re.compile(r"\bv\d+(\.\d+)*[-_ ]?r\d+[a-z]?\b|\br[1-9]\d*[a-c]?\b(?![-\w])")),
    ("LAN address / home path / email", re.compile(
        r"(192\.168|10\.\d{1,3}|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}|/home/\w+"
        r"|[\w.%+-]+@(gmail|yahoo|hotmail|outlook|proton(mail)?|icloud)\.[a-z]+")),
]
# proper names that contain a flagged word
ALLOW = re.compile(r"ravu-lite-ar-r4|Keep a Changelog|Real-?time|realtime|Real-ESRGAN", re.I)
# package Version field may carry build round (owner rule: rN in versions)
VERSION_FIELD = re.compile(r"\bVersion:\s*\d+(\.\d+)*~r\d+\b")


def slug(h):
    s = re.sub(r"[^\w\- ]", "", h.lstrip("#").strip().lower())
    return s.replace(" ", "-")


bad = 0
for path in FILES:
    lines = open(path, encoding="utf-8").read().split("\n")
    fenced, fences, hits = False, 0, []
    for n, line in enumerate(lines, 1):
        if line.strip().startswith("```"):
            fenced = not fenced; fences += 1; continue
        if fenced:
            continue
        prose = VERSION_FIELD.sub(" ", ALLOW.sub(" ", PROTECT.sub(" ", line)))
        for name, rx in RULES:
            for m in rx.finditer(prose):
                hits.append((n, name, m.group(0).strip(), line.strip()[:100]))
    heads = {slug(l) for l in lines if l.startswith("#")}
    for a in sorted(set(re.findall(r"\]\(#([^)]+)\)", "\n".join(lines))) - heads):
        hits.append((0, "dangling internal link", "#" + a, ""))
    if fences % 2:
        hits.append((0, "unbalanced code fence", f"{fences} fences", ""))
    print(f"{'ok  ' if not hits else 'FAIL'} {path}  ({len(hits)} issues)")
    for n, name, word, ctx in hits[:60]:
        print(f"     {n:5d}  {name:26s} {word!r:16s} {ctx}")
    bad += len(hits)
sys.exit(1 if bad else 0)
