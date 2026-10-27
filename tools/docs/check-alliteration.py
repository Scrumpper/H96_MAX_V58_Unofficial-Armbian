#!/usr/bin/env python3
"""Flag alliteration in published docs. Exit 1 on any hit.

    check-alliteration.py FILE.md ...
    check-alliteration.py --allow FILE FILE.md ...   allow-list other than alliteration-allow.txt beside this script

Hit: three or more words sharing an initial letter inside any four-word window of one sentence.
Ignored: fenced code, table rows, indented code, inline code, link targets, URLs, stopwords,
words under three letters and allow-listed names (proper, product, codec and protocol names,
one per line, `name  # justification`; a one-word entry also covers hyphen suffixes, an entry
with other characters such as `Steam Deck` or `S/PDIF` is removed from the text as a phrase).
One hit per sentence. Output `file:line: window | sentence` and a count per file.

Importable: hits(name, text, allow) -> [(line, window, sentence)]; load_allow(path) -> list.
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


def hits(name, text, allow=None):
    """[(line, window, sentence)] for every alliterating sentence of one doc."""
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
    return found


def main(argv):
    allow_path = DEFAULT_ALLOW
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--allow":
            allow_path = argv[i + 1]
            i += 2
            continue
        files.append(argv[i])
        i += 1
    if not files:
        sys.exit(__doc__)
    allow = load_allow(allow_path)
    total = 0
    for path in files:
        text = open(path, encoding="utf-8", errors="replace").read()
        found = hits(path, text, allow)
        for n, win, sent in found:
            print(f"{path}:{n}: {win}  |  {sent}")
        print(f"{'ok  ' if not found else 'FAIL'} {path}  ({len(found)} hits)")
        total += len(found)
    print(f"TOTAL {total} hits in {len(files)} files")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
