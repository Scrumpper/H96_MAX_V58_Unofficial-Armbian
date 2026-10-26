#!/usr/bin/env python3
"""Clinical-style gate for published docs (owner rules, memory docs-style-clinical).

Importable: style_hits(name, text) -> [(line, rule, match, context)]. Used by verify-strip.py and
stage-and-zip.py. Prose is everything outside fenced code (except FENCE_IS_PROSE files), inline
code, autolinks/HTML, link targets and bare URLs.

Rules: em/en dash; any article (the, a, an) in prose, sentence-opening or mid-sentence, also at a
hard-wrapped line end; ship wording; our/we; filler words; internal revision labels; personal
identifiers and LAN addresses; unbalanced fences; dangling internal links; ragged tables.
Kept: "a few", "Keep a Changelog", "N/A", capitalised A/An/The that does not open a sentence
(labels such as "Type A"), proper names in ALLOW.
"""
import os
import re

FENCE_IS_PROSE = {"ON-DEMAND-LIBRARIES.md"}
PROTECT = re.compile(r"`[^`]*`|<[^>]*>|\]\([^)]*\)|https?://\S+")
KEEP = re.compile(r"\b[Aa] few\b|\b[Kk]eep a Changelog\b|\b[Nn]/[Aa]\b")
ALLOW = re.compile(r"ravu-lite-ar-r4|Keep a Changelog|Real-?time|realtime", re.I)
OPENER = re.compile(r"(^\s*(?:#{1,6} |[-*] (?:\[[ x]\] )?|\d+\. |> |\| )?(?:\*\*|\*|\(|\")?"
                    r"|[.!?](?:\*\*|\*|\)|\")?\s+(?:\*\*|\*|\(|\")?|\|\s+(?:\*\*|\*)?)(The|A|An) [a-z]")
MID = re.compile(r"\b(the|a|an)\b(?= [^\s.,;:)\]}])")
END = re.compile(r"(?:^|\s)(the|a|an|The|A|An)$")
# private name denylist: one regex per line in file named by H96_PRIVATE_WORDS (kept out of repo)
_PW = os.environ.get("H96_PRIVATE_WORDS", "")
_PRIVATE = [l.strip() for l in open(_PW, encoding="utf-8") if l.strip() and not l.startswith("#")] if _PW else []
RULES = [
    ("em/en dash", re.compile(r"[—–]")),
    ("ship wording", re.compile(r"\bship(s|ped|ping)?\b", re.I)),
    ("our/we", re.compile(r"\b(our|ours|we|we're|we've|us)\b", re.I)),
    ("filler word", re.compile(r"\b(real|really|actual|actually|very|simply|just)\b", re.I)),
    ("internal revision label", re.compile(r"\bv\d+(\.\d+)*[-_ ]?r\d+[a-z]?\b|\br[1-9][a-c]?\b(?![-\w])")),
    ("personal identifier / LAN", re.compile("|".join(_PRIVATE + [r"192\.168\.\d+\.\d+", r"/home/\w+"]))),
]
SEP = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def slug(h):
    s = re.sub(r"`", "", h.lstrip("#").strip().lower())
    s = re.sub(r"[^\w\s-]", "", s)
    return re.sub(r"\s+", "-", s).strip("-")


def prose_lines(name, text):
    """(lineno, raw line, prose-only line) for every line outside code fences."""
    fenced, out = False, []
    fence_is_code = os.path.basename(name) not in FENCE_IS_PROSE
    for n, line in enumerate(text.split("\n"), 1):
        if line.strip().startswith("```"):
            fenced = not fenced
            continue
        if fenced and fence_is_code:
            continue
        out.append((n, line, ALLOW.sub(" ", KEEP.sub(" ", PROTECT.sub(" ", line)))))
    return out


def style_hits(name, text):
    hits = []
    lines = text.split("\n")
    pl = prose_lines(name, text)
    for idx, (n, raw, prose) in enumerate(pl):
        if SEP.match(raw) or raw.lstrip().startswith("<!--"):
            continue
        for m in OPENER.finditer(prose):
            hits.append((n, "article opens sentence", m.group(2), raw.strip()[:100]))
        for m in MID.finditer(prose):
            hits.append((n, "article in prose", m.group(1), raw.strip()[:100]))
        m = END.search(prose.rstrip())
        nxt = pl[idx + 1] if idx + 1 < len(pl) else None
        if m and nxt and nxt[0] == n + 1 and nxt[1].strip() and not nxt[1].lstrip().startswith(("|", "#", "```")):
            hits.append((n, "article at line end", m.group(1), raw.strip()[:100]))
        for rule, rx in RULES:
            for m in rx.finditer(prose):
                hits.append((n, rule, m.group(0).strip(), raw.strip()[:100]))
    if sum(1 for l in lines if l.strip().startswith("```")) % 2:
        hits.append((0, "unbalanced code fence", "```", ""))
    heads = {slug(l) for l in lines if l.startswith("#")}
    for a in sorted(set(re.findall(r"\]\(#([^)]+)\)", text)) - heads):
        hits.append((0, "dangling internal link", "#" + a, ""))
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith("|") and i + 1 < len(lines) and SEP.match(lines[i + 1]):
            start, block = i + 1, []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                block.append(lines[i])
                i += 1
            if len({len(re.split(r"(?<!\\)\|", b.strip().strip("|"))) for b in block}) > 1:
                hits.append((start, "ragged table", "|", block[0].strip()[:100]))
            continue
        i += 1
    return hits
