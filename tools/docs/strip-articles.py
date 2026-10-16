#!/usr/bin/env python3
"""Remove articles (the, a, an) from prose in published docs and capitalise the
word that follows when the article opened a sentence.

Left alone: fenced code blocks, inline code spans, URLs and autolinks, link
targets, HTML, table separator rows, comments, and the phrase "a few" (a
quantifier rather than an article in use). Table padding is not touched here;
the alignment pass re-pads the columns afterwards.

Capitalised articles are removed only where they open a sentence: at the start
of a line behind any markdown prefix, or after a full stop, exclamation or
question mark, with or without closing bold markers between. A capitalised
article anywhere else (a label such as "Type A") is reported and kept.

Internal links: a heading that loses an article gets a new auto-anchor, so every
`](#old-slug)` link is rewritten to the new slug of the same heading, and any
link left pointing at no heading is reported.

    strip-articles.py --dry FILE.md ...   report what would change, write nothing
    strip-articles.py --check FILE.md ... as --dry, exit 1 when any change is due
    strip-articles.py FILE.md ...         rewrite in place
"""
import re, sys, os

CHECK = "--check" in sys.argv
DRY = CHECK or "--dry" in sys.argv
FILES = [a for a in sys.argv[1:] if not a.startswith("--")]
if not FILES:
    sys.exit(__doc__)

# spans inside a line that must not be touched
PROTECT = re.compile(
    r"`[^`]*`"                         # inline code
    r"|<[^>]*>"                        # autolinks, html tags
    r"|\]\([^)]*\)"                    # link targets
    r"|https?://\S+"                   # bare urls
)
# the markdown prefix a sentence can start behind
PREFIX = r"(?:#{1,6} |[-*] (?:\[[ x]\] )?|\d+\. |> |\| )?(?:\*\*|\*|\(|\")?"
LINE_START = re.compile(r"^\s*" + PREFIX + r"$")
# a table cell opens a sentence wherever it sits on the line
CELL_START = re.compile(r"\|\s+(?:\*\*|\*|\(|\")?$")
# a sentence end, possibly closing bold or a bracket first, then the space, then
# possibly opening bold or a bracket for the next sentence
AFTER_STOP = re.compile(r"[.!?](?:\*\*|\*|\)|\")?\s+(?:\*\*|\*|\(|\")?$")

ART = re.compile(r"\b(the|a|an|The|A|An)\b(?= [^\s.,;:)\]}])")
# "a few" is a quantifier; "Keep a Changelog" is a proper name
KEEP_PHRASES = re.compile(r"\b[Aa] few\b|\ba Changelog\b|\b[Nn]/[Aa]\b")

kept_caps = []


# a bold label that opens the line, with no full stop of its own, still starts
# the sentence that follows it: "**Cluster scheduling** The kernel enables..."
LEAD_BOLD = re.compile(r"^\s*(?:[-*] |\d+\. |> )?\*\*[^*]+\*\*\s+$")


def sentence_start(before):
    return (bool(LINE_START.match(before)) or bool(AFTER_STOP.search(before))
            or bool(LEAD_BOLD.match(before)) or bool(CELL_START.search(before)))


def protected_spans(line):
    return [(m.start(), m.end()) for m in PROTECT.finditer(line)]


def in_protected(spans, i):
    return any(s <= i < e for s, e in spans)


def strip_line(line, path, lineno):
    if re.match(r"^\s*\|?\s*:?-{2,}", line) or line.lstrip().startswith("<!--"):
        return line
    spans = protected_spans(line)
    # walk the matches on the whole line so an article before inline code is seen
    out, pos = [], 0
    text = line
    for m in list(ART.finditer(text)):
        if in_protected(spans, m.start()):
            continue
        if KEEP_PHRASES.match(text, m.start()):
            continue
        word = m.group(1)
        capital = word[0].isupper()
        before = text[:m.start()]
        if capital and not sentence_start(before):
            kept_caps.append(f"{os.path.basename(path)}:{lineno}: ...{text[max(0, m.start()-25):m.end()+15]}...")
            continue
        out.append(text[pos:m.start()])
        nxt = m.end() + 1                  # past the article and its trailing space
        pos = nxt
        if capital:
            k = nxt
            while k < len(text) and text[k] in "*`\"(":
                k += 1
            if k < len(text) and text[k].isalpha():
                text = text[:k] + text[k].upper() + text[k+1:]
    out.append(text[pos:])
    return "".join(out)


def slug(heading):
    h = re.sub(r"`", "", heading.strip().lstrip("#").strip()).lower()
    h = re.sub(r"[^\w\s-]", "", h)
    return re.sub(r"\s+", "-", h).strip("-")


# basenames whose fenced blocks hold prose, not code
FENCE_IS_PROSE = set()


def process(path):
    src = open(path, encoding="utf-8").read()
    lines = src.split("\n")
    out, fenced, changed = [], False, 0
    samples, slugs = [], {}
    fence_matters = os.path.basename(path) not in FENCE_IS_PROSE
    for n, line in enumerate(lines, 1):
        if line.strip().startswith("```"):
            fenced = not fenced
            out.append(line); continue
        if fenced and fence_matters:
            out.append(line); continue
        new = strip_line(line, path, n)
        if line.startswith("#") and new != line:
            slugs[slug(line)] = slug(new)
        if new != line:
            changed += 1
            if len(samples) < 6:
                samples.append((n, line.strip()[:110], new.strip()[:110]))
        out.append(new)
    # Hard-wrapped prose can end a line on the article, where no space follows
    # it, so the pass above never saw it. Take it off the line end here, and
    # when it opened a sentence, capitalise the first word of the next line.
    END_ART = re.compile(r"(^|\s)(the|a|an|The|A|An)$")
    fenced = False
    for i in range(len(out) - 1):
        l = out[i]
        if l.strip().startswith("```"):
            fenced = not fenced; continue
        if (fenced and fence_matters) or in_protected(protected_spans(l), len(l) - 1):
            continue
        m = END_ART.search(l)
        if not m or KEEP_PHRASES.search(l[m.start():] + " " + out[i + 1].lstrip()[:4]):
            continue
        nxt = out[i + 1]
        if not nxt.strip() or nxt.lstrip().startswith(("```", "|", "#")):
            continue
        capital = m.group(2)[0].isupper()
        if capital and not sentence_start(l[:m.start(2)]):
            continue
        out[i] = l[:m.start()]
        if capital:
            k = len(nxt) - len(nxt.lstrip())
            while k < len(nxt) and nxt[k] in "*`\"(":
                k += 1
            if k < len(nxt) and nxt[k].isalpha():
                out[i + 1] = nxt[:k] + nxt[k].upper() + nxt[k + 1:]
        changed += 1
    result = "\n".join(out)
    # internal links follow their headings
    relinked = 0
    def fix_link(m):
        nonlocal relinked
        old = m.group(1)
        if old in slugs and slugs[old] != old:
            relinked += 1
            return f"](#{slugs[old]})"
        return m.group(0)
    result = re.sub(r"\]\(#([^)]+)\)", fix_link, result)
    # every internal link must still land on a heading
    heads = {slug(l) for l in result.split("\n") if l.startswith("#")}
    dangling = sorted({a for a in re.findall(r"\]\(#([^)]+)\)", result) if a not in heads})
    removed = (len(re.findall(r"\b(?:the|a|an|The|A|An)\b", src))
               - len(re.findall(r"\b(?:the|a|an|The|A|An)\b", result)))
    if not DRY and result != src:
        open(path, "w", encoding="utf-8").write(result)
    return changed, removed, samples, relinked, dangling


total_lines = total_removed = 0
any_dangling = False
for f in FILES:
    changed, removed, samples, relinked, dangling = process(f)
    total_lines += changed; total_removed += removed
    any_dangling = any_dangling or bool(dangling)
    note = f", {relinked} links re-pointed" if relinked else ""
    print(f"{'DRY ' if DRY else ''}{os.path.basename(f):32s} {changed:5d} lines, {removed:5d} articles removed{note}")
    if dangling:
        print(f"      DANGLING LINKS: {', '.join(dangling)}")
    if DRY:
        for n, a, b in samples:
            print(f"      {n:5d}  {a}")
            print(f"             -> {b}")
print(f"\n{total_lines} lines changed, {total_removed} articles removed across {len(FILES)} files")
if kept_caps:
    print(f"\n{len(kept_caps)} capitalised article(s) kept, not at a sentence start:")
    for k in kept_caps[:40]:
        print("   " + k)
if CHECK and (total_lines or any_dangling):
    sys.exit(1)
