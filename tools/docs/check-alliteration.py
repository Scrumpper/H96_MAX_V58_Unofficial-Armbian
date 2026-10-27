#!/usr/bin/env python3
"""Flag alliteration and repeated openers in published docs. Exit 1 on any hit.

    check-alliteration.py FILE.md ...
    check-alliteration.py --allow FILE FILE.md ...           allow-list other than alliteration-allow.txt beside this script
    check-alliteration.py --openers-allow FILE FILE.md ...   opener allow-list other than openers-allow.txt beside this script

Alliteration hit: three or more words sharing an initial letter inside any four-word window of one sentence.
Ignored: fenced code, table rows, indented code, inline code, link targets, URLs, stopwords,
words under three letters and allow-listed names (proper, product, codec and protocol names,
one per line, `name  # justification`; a one-word entry also covers hyphen suffixes, an entry
with other characters such as `Steam Deck` or `S/PDIF` is removed from the text as a phrase).
One hit per sentence.

Opener hits (owner rule 2026-10-27): the same first word on two neighbouring bullets of one list,
on two neighbouring sentences of one paragraph or bullet, or on two comma/semicolon clauses of one
sentence; and slogan phrases such as `one script`, `nothing installed`, `no download needed`.
Ignored: fenced code, table rows, indented code, headings, bullets that start with a code span or
a link, list items that repeat a heading of the doc (command lists, contents indexes), function-word openers (OPENER_SKIP) and words in the
opener allow-list (`word  # justification`, proper or product names only).

Output `file:line: window | sentence` and a count per file; opener windows read
`opener 'word' x2`, `clause 'word' x2`, `phrase 'one script'`.

Importable: hits(name, text, allow, openers_allow) -> [(line, window, sentence)]; load_allow(path) -> list.
"""
import os
import re
import sys

DEFAULT_ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "alliteration-allow.txt")
STOP = set("a an the and or of to in on for with by at from as is are was be it its this that these those not "
           "no if then than when while into onto over under up out off per via each every all any some one two".split())
PROTECT = re.compile(r"`[^`]*`|\]\([^)]*\)|https?://\S+")
WORD = re.compile(r"[A-Za-z][A-Za-z'-]*")
SENT = re.compile(r"(?<=[.;:!?])\s+")

DEFAULT_OPENERS_ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "openers-allow.txt")
# slogan phrases the owner named, plus their nearest siblings
PHRASES = re.compile(r"\b(one (release|click|script|installer|command|step|file|line|run|image|place|tool|download)"
                     r"|nothing (bundled|installed|else|more|new|extra)|no (download|install|change|setup)s? needed)\b", re.I)
# function words that may open neighbouring items without reading as a refrain
OPENER_SKIP = set("a an the and or to in on for with from by of at as if when then so not no or yes none same "
                  "see run use set".split())
BULLET = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
LEAD = re.compile(r"^[\s*_~\[\]()\"'“”‘’!?]+")
OWORD = re.compile(r"[A-Za-z][\w.'/+-]*")
OSENT = re.compile(r"(?<=[.!?])\s+")
CLAUSE = re.compile(r"[;,]\s+")
# clause openers that read as a refrain when repeated ("one X, one Y"; "nothing bundled, nothing installed")
CLAUSE_WORDS = {"one", "nothing", "every", "each", "single", "all", "no", "same", "first", "zero", "only", "any"}


def load_allow(path):
    """Allow entries from a file, comments stripped, blank lines dropped."""
    if not path or not os.path.isfile(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        name = line.split("#", 1)[0].strip()
        if name:
            out.append(name)
    return out


def _words(sent, phrases, singles):
    s = PROTECT.sub(" ", sent)
    for p in phrases:
        s = p.sub(" ", s)
    out = []
    for w in WORD.findall(s):
        lw = w.lower()
        if lw in STOP or len(w) < 3:
            continue
        if any(lw == a or lw.startswith(a + "-") for a in singles):
            continue
        out.append(w)
    return out


def opener(s):
    """First word of a bullet, sentence or clause, lower case; None when it starts with code, a link or no word."""
    s = LEAD.sub("", s.strip())
    if not s or s[0] in "`[<":
        return None
    s = re.sub(r"^\*\*|^__", "", s)
    m = OWORD.match(s)
    return m.group(0).lower().rstrip(".") if m else None


def _opener_hits(text, allowed):
    """Repeated openers: neighbouring bullets, neighbouring sentences, clauses of one sentence, slogan phrases."""
    found, fenced = [], False
    prev_bullet, para = {}, []   # indent -> (opener, line); [(line, text)] of the open paragraph or bullet
    # contents index: list items that repeat a heading of the same doc are not prose
    headings = {re.sub(r"[*_`]", "", h).strip().lower() for h in re.findall(r"^\s*#+\s+(.*)$", text, re.M)}

    def flush():
        if not para:
            return
        body = PROTECT.sub("`c`", " ".join(t for _, t in para))
        line = para[0][0]
        last = None
        for sent in OSENT.split(body):
            w = opener(sent)
            if w and w == last and w not in OPENER_SKIP and w not in allowed:
                found.append((line, f"opener '{w}' x2", sent.strip()[:110]))
            last = w
            cl = [opener(c) for c in CLAUSE.split(sent)]
            cl = [c for c in cl if c in CLAUSE_WORDS and c not in allowed]
            for w in dict.fromkeys(cl):
                if cl.count(w) >= 2:
                    found.append((line, f"clause '{w}' x{cl.count(w)}", sent.strip()[:110]))
                    break
        para.clear()

    for n, line in enumerate(text.split("\n"), 1):
        if line.strip().startswith("```"):
            fenced = not fenced
            flush()
            prev_bullet.clear()
            continue
        if fenced or line.startswith("|") or line.startswith("    ") and not para:
            flush()
            continue
        plain = PROTECT.sub(" ", line)
        for m in PHRASES.finditer(plain):
            found.append((n, f"phrase '{m.group(0)}'", line.strip()[:110]))
        if not line.strip() or line.lstrip().startswith("#"):
            flush()
            prev_bullet.clear()
            continue
        b = BULLET.match(line)
        if b:
            flush()
            indent, text_b = len(b.group(1)), b.group(3)
            w = opener(PROTECT.sub("`c`", text_b))
            if re.sub(r"[*_`]", "", text_b).strip().lower() in headings:
                w = None
            prev = prev_bullet.get(indent)
            if w and prev and w == prev[0] and w not in OPENER_SKIP and w not in allowed:
                found.append((n, f"opener '{w}' x2", f"repeats line {prev[1]}: {text_b.strip()[:90]}"))
            prev_bullet[indent] = (w, n)
            for k in [k for k in prev_bullet if k > indent]:
                del prev_bullet[k]
            para.append((n, text_b))
        else:
            if not para:
                prev_bullet.clear()
            para.append((n, line.strip()))
    flush()
    return found


def hits(name, text, allow=None, openers_allow=None):
    """[(line, window, sentence)] for every alliterating sentence and repeated opener of one doc."""
    if openers_allow is None:
        openers_allow = load_allow(DEFAULT_OPENERS_ALLOW)
    allow = [a for a in (allow or [])]
    # entries that are not one plain word go first as phrases, longest first ("Steam Deck" before "Steam")
    phrases = [re.compile(r"(?<![\w-])" + re.escape(a) + r"(?![\w-])", re.I)
               for a in sorted((a for a in allow if not WORD.fullmatch(a)), key=len, reverse=True)]
    singles = {a.lower() for a in allow if WORD.fullmatch(a)}
    found, fenced = [], False
    for n, line in enumerate(text.split("\n"), 1):
        if line.strip().startswith("```"):
            fenced = not fenced
            continue
        if fenced or line.startswith("|") or line.startswith("    "):
            continue
        for sent in SENT.split(line):
            ws = _words(sent, phrases, singles)
            for i in range(len(ws) - 2):
                win = ws[i:i + 4]
                first = win[0][0].lower()
                if sum(1 for w in win if w[0].lower() == first) >= 3:
                    found.append((n, " ".join(win), sent.strip()[:110]))
                    break
    found += _opener_hits(text, {a.lower() for a in openers_allow})
    found.sort(key=lambda h: h[0])
    return found


def main(argv):
    allow_path, openers_path = DEFAULT_ALLOW, DEFAULT_OPENERS_ALLOW
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--allow":
            allow_path = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--openers-allow":
            openers_path = argv[i + 1]
            i += 2
            continue
        files.append(argv[i])
        i += 1
    if not files:
        sys.exit(__doc__)
    allow, openers_allow = load_allow(allow_path), load_allow(openers_path)
    total = 0
    for path in files:
        text = open(path, encoding="utf-8", errors="replace").read()
        found = hits(path, text, allow, openers_allow)
        for n, win, sent in found:
            print(f"{path}:{n}: {win}  |  {sent}")
        print(f"{'ok  ' if not found else 'FAIL'} {path}  ({len(found)} hits)")
        total += len(found)
    print(f"TOTAL {total} hits in {len(files)} files")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
