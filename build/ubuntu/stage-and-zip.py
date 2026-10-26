#!/usr/bin/env python3
"""
stage-and-zip.py - stage the freshly sealed ship image into the UPLOAD folder and
zip it, refusing to proceed if they do not match.

WHY THIS EXISTS
---------------
On 2026-08-21 a v3.2 zip was uploaded containing an image that was three builds
old. The image was rebuilt several times that day (rfkill fix, kio-extras, nvtop,
online-extras retry), but each rebuild wrote to tvboox/v3.2-ship-release/ and was
flashed straight from there. Nothing re-staged it into the UPLOAD folder, so that
folder silently kept the FIRST build while the docs beside it kept being updated.

The failure was invisible for the worst possible reason: the CHANGELOG in the zip
described the WiFi fix, and the image in the same zip did not contain it. Docs and
binary drifted apart with nothing comparing them.

So: never copy by hand again. This script is the only supported path from a sealed
build to a zip, and it fails loudly rather than shipping a mismatch.
"""
import hashlib
import os
import re
import re as re_mod
import shutil
import subprocess
import sys

TVBOOX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Release folders moved under PRODUCTION/ on 2026-09-06 (older versions live in
# "Old Versions/"); the zip lands beside the release folder.
# H96_UPLOAD_ROOT: folder holding "Unofficial Armbian v<VER>/" (docs) and the zip; H96_RELEASE_DIR: sealed build folder
UPLOAD_ROOT = os.environ.get("H96_UPLOAD_ROOT", os.path.join(os.getcwd(), "PRODUCTION"))

# Version is an argument so this stays the single supported path for every release
# rather than being copy-pasted per version (a copy would drift, and drift between
# the docs and the binary is exactly the failure this script exists to prevent).
# --dry-run: doc gate on the UPLOAD folder only; no build dir needed, nothing copied or zipped
DRY_RUN = "--dry-run" in sys.argv[1:]
# --edition=debian: Debian Edition release folders under "H96 Armbian Debian Edition/" (same gates, same CARRY list)
EDITIONS = {"debian": "Debian Edition"}
EDITION = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--edition=")), "")
if EDITION and EDITION not in EDITIONS:
    sys.exit(f"unknown edition {EDITION!r}; known: {', '.join(EDITIONS)}")
ED_TITLE = EDITIONS.get(EDITION, "")
_args = [a for a in sys.argv[1:] if not a.startswith(("--asset=", "--edition=")) and a != "--dry-run"]
EXTRA_ASSETS = [a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--asset=")]
VER = _args[0] if _args else "3.3"
if not re_mod.fullmatch(r"\d+\.\d+(\.\d+)?", VER):
    sys.exit(f"usage: stage-and-zip.py <version> [--asset=PATH ...] [--dry-run]   e.g. 3.3 or 6.1.1   (got {VER!r})")

# v3.2 sealed into v3.2-ship-release; later lines seal into v<VER>-release.
_cands = [f"{TVBOOX}/v{VER}-release", f"{TVBOOX}/v{VER}-ship-release"]
BUILD_DIR = os.environ.get("H96_RELEASE_DIR") or next((d for d in _cands if os.path.isdir(d)), _cands[0])
UPLOAD_DIR = f"{UPLOAD_ROOT}/Unofficial Armbian v{VER}"
ZIP_PATH = f"{UPLOAD_ROOT}/Unofficial Armbian v{VER}.zip"

IMG_XZ = f"H96-MAX-V58_Unofficial-Armbian_v{VER}.img.xz"
if EDITION:
    # edition project: sealed build in release/v<VER> (seal-release.sh), zip and docs under its PRODUCTION
    _proj = os.environ.get("H96_EDITION_ROOT", os.path.join(os.getcwd(), f"H96 Armbian {ED_TITLE}"))
    UPLOAD_ROOT = os.environ.get("H96_UPLOAD_ROOT", f"{_proj}/PRODUCTION")
    BUILD_DIR = os.environ.get("H96_RELEASE_DIR", f"{_proj}/release/v{VER}")
    UPLOAD_DIR = f"{UPLOAD_ROOT}/Unofficial Armbian v{VER} {ED_TITLE}"
    ZIP_PATH = f"{UPLOAD_ROOT}/Unofficial Armbian v{VER} {ED_TITLE}.zip"
    IMG_XZ = f"H96-MAX-V58_Unofficial-Armbian_v{VER}-{EDITION}.img.xz"
CARRY = [IMG_XZ, f"{IMG_XZ}.sha256", f"{IMG_XZ[:-3]}.sha256", "flash.py", "MiniLoaderAll.bin",
         "FLASHER-SHA256SUMS.txt", "SHA256SUMS"]
# Docs are authored in the UPLOAD folder (hand-cleaned: de-versioned, no em-dashes,
# no qualitative language) and are deliberately NOT overwritten from the build dir,
# whose copies are auto-rebranded and still contain em-dashes.
DOCS = ["README.md", "CHANGELOG.md", "FLASHING.md", "COMMANDS.md",
        "UNDERVOLT_README.md"] + ([f"{EDITION.upper()}-EDITION.md"] if EDITION else [])
# Every other .md in the folder (CHANGELOG-v<VER>.md, ON-DEMAND-LIBRARIES.md, KERNEL-COMPARISON.md ...)
# is zipped too, so every .md present is gated like DOCS.
# The kernel version the docs legitimately name (release strings 6.1.115-h96,
# 6.1.115-h96v58v1, 6.1.115-h96v58v2, the bare vendor 6.1.115). From v6.1 on it collides with the
# image version pattern (v6.1 + ".\\d+"), so it is blanked before the sub-version
# check below; a stray "v6.1.2" still trips the gate.
# Reviewed for v7.x: the v7.x patterns (7.N.d) never match 6.1.115, so the blanking is inert there;
# kept so v6.x zips rebuild unchanged.
KERNEL_VERSION = "6.1.115"
# The v6.1.1 image build was renamed v6.2 before release (never shipped under
# the v6.1.1 name), but the separate h96-v6.1.1-fix / h96-v6.1.1-HOTfix.zip
# hotfix (for boxes already on v6.1) keeps the v6.1.1 name and stays published.
# v6.2-and-later docs legitimately mention it ("h96-v6.1.1-HOTfix.zip", "the
# v6.1.1 hotfix"), so that exact string is blanked before the sub-version check
# the same way the kernel version is; any OTHER 6.1.x string still trips the
# gate. Docs staged AS v6.1.1 itself (rebuilding the hotfix's own zip) already
# pass through the "m.lstrip('v') != VER" exception below, so no blanking is
# needed in that one case.
# h96-v6.2.1-fix / h96-v6.2.1-HOTfix.zip (boxes on v6.2) is named in v6.2 docs the same way.
HOTFIX_VERSIONS = ("6.1.1", "6.2.1")
# v7.0 on, the kernel release string carries the image version: 6.1.172-h96v58-<VER>. Only the
# current one is blanked before the sub-version check. A historical one may appear only in history
# context (its own release named on the line or in an enclosing heading); any other one fails.
# v8.0 on, image also carries a 6.12 kernel: 6.12.N-h96v58-<VER>. A build suffix (8.0r17) is never current.
KREL_RE = re.compile(r"(?<![\w.-])6\.(?:1\.172|12\.\d+)-h96v58-(\d+\.\d+(?:r\d+)?)(?!\.?\d)")
HISTORICAL_KRELS = ("6.1.172-h96v58-7.0", "6.1.172-h96v58-7.1")
# Clinical gate (release-tools/clinical_gate.py) applies from this release on; older zips predate it.
CLINICAL_FROM = (7, 1)


# image version -> kernel build it carries, when a release keeps the previous kernel (no rebuild)
KERNEL_OF = {"7.2": "7.1"}
# image version -> 6.12 kernel version it carries beside 6.1.172
KERNEL_612_OF = {"8.0": "6.12.69"}


def current_krel(ver):
    mm = '.'.join(ver.split('.')[:2])
    return f"6.1.172-h96v58-{KERNEL_OF.get(mm, mm)}"


def kernel_releases(ver):
    if tuple(int(x) for x in ver.split(".")[:2]) < (7, 0):
        return ()
    mm = '.'.join(ver.split('.')[:2])
    k612 = KERNEL_612_OF.get(mm)
    return (current_krel(ver),) + ((f"{k612}-h96v58-{mm}",) if k612 else ())


def find_leaked_subversions(body, ver, kernel_version=KERNEL_VERSION,
                             hotfix_versions=HOTFIX_VERSIONS):
    """Return the sub-version strings in `body` that do not belong in a v<ver>
    doc. A point release (6.1.1) names itself; the kernel version and the
    standing hotfix name are also allowed; any other 6.1.x-style string is a
    leak.
    """
    major, minor = ver.split(".")[:2]
    # (?<!\d) so a library version such as "Mesa 26.0.1" cannot match "6.0.1".
    pats = [rf"(?<![\d.])v?{major}\.{minor}\.\d+",
            rf"(?<![\d.])v?{major}\.{int(minor) - 1}\.\d+"]
    for kr in kernel_releases(ver):
        # a trailing ".N" is not this release string and stays visible to the check
        body = re.sub(rf"(?<![\w.-]){re.escape(kr)}(?!\.?\d)", "", body)
    chk = re.sub(rf"(?<![\d.v]){re.escape(kernel_version)}(?![\d.])", "", body)
    for hv in hotfix_versions:
        if ver != hv:
            # end of sentence or file suffix may follow (CHANGELOG-v6.2.1.md); a further digit may not
            chk = re.sub(rf"(?<![\d.])v?{re.escape(hv)}(?!\d|\.\d)", "", chk)
    return sorted({m for pat in pats for m in re.findall(pat, chk)
                   if m.lstrip("v") != ver})


def find_stale_kernel_releases(body, ver):
    """Kernel release strings of another image version that sit outside their own history context."""
    cur = kernel_releases(ver) or (current_krel(ver),)
    stale, heads, fenced = [], [], False
    for n, line in enumerate(body.split("\n"), 1):
        if line.strip().startswith("```"):
            fenced = not fenced
        h = None if fenced else re.match(r"(#{1,6}) ", line)
        if h:
            heads = [x for x in heads if x[0] < len(h.group(1))] + [(len(h.group(1)), line)]
        for m in KREL_RE.finditer(line):
            kr = m.group(0)
            if kr in cur:
                continue
            ctx = re.compile(rf"(?<![\w.])v{re.escape(m.group(1))}(?![\w]|\.\d)")
            if kr in HISTORICAL_KRELS and (ctx.search(line) or any(ctx.search(t) for _, t in heads)):
                continue
            stale.append(f"{n}: {kr}")
    return stale


def clinical_hits(name, body):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "release-tools"))
    from clinical_gate import style_hits
    return style_hits(name, body)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def die(msg):
    sys.exit(f"\n  REFUSING TO SHIP: {msg}\n")


def doc_failures(d, body, clinical):
    """Gate failures of one doc: dashes, sub-version leaks, stale kernel strings, clinical style."""
    out = []
    if "\u2014" in body or "\u2013" in body:
        out.append(f"{d} contains an em-dash or en-dash")
    # Catch a sub-version from THIS line and from the previous one: a v3.3 doc
    # naming "v3.2" as the base it builds on is legitimate, "v3.2.13" is not.
    ph = sorted(set(re.findall(r"<[A-Z][A-Z0-9-]{3,}>", body)))
    if ph:
        out.append(f"{d} has unfilled placeholders: {ph}")
    leaked = find_leaked_subversions(body, VER)
    if leaked:
        out.append(f"{d} leaked a sub-version string: {leaked}")
    stale = find_stale_kernel_releases(body, VER)
    if stale:
        out.append(f"{d} names a kernel release of another version outside its history section: {stale[:5]}")
    if clinical:
        hits = clinical_hits(d, body)
        if hits:
            out.append(f"{d} fails the clinical gate ({len(hits)}): " +
                       "; ".join(f"{n} {rule} {w!r}" for n, rule, w, _ in hits[:8]))
    return out


def gate_docs(fail):
    """Gate every .md in UPLOAD_DIR; fail(msg) on the first failure (die) or per failure (dry run)."""
    for d in DOCS:
        if not os.path.isfile(f"{UPLOAD_DIR}/{d}"):
            fail(f"{d} missing from the UPLOAD folder")
    if os.path.exists(f"{UPLOAD_DIR}/PENDING-BEFORE-PUBLISH.md"):
        fail("PENDING-BEFORE-PUBLISH.md (internal tracker) still in the UPLOAD folder")
    gated = sorted(n for n in os.listdir(UPLOAD_DIR) if n.endswith(".md"))
    if os.path.isfile(f"{UPLOAD_DIR}/CHANGELOG.md") and tuple(int(x) for x in VER.split(".")[:2]) >= CLINICAL_FROM \
            and f"CHANGELOG-v{VER}.md" not in gated:
        fail(f"CHANGELOG-v{VER}.md missing from the UPLOAD folder")
    clinical = tuple(int(x) for x in VER.split(".")[:2]) >= CLINICAL_FROM
    bad = 0
    for d in gated:
        p = f"{UPLOAD_DIR}/{d}"
        errs = doc_failures(d, open(p, encoding="utf-8").read(), clinical)
        for e in errs:
            fail(e)
        bad += bool(errs)
        if not errs:
            print(f"  ok  {d}  sha256 {sha256(p)[:16]}...")
    if not bad:
        print(f"  ok  {len(gated)} docs gated: no dashes, no sub-version leaks, no stale kernel string"
              + (", clinical style" if clinical else ""))
    return bad


def dry_run():
    """Doc gate only; prints every failure, exit 1 when any doc fails."""
    print(f"  version      : v{VER} (dry run: doc gate only, nothing copied or zipped)")
    if not os.path.isdir(UPLOAD_DIR):
        die(f"{UPLOAD_DIR} does not exist")
    fails = []
    gate_docs(lambda m: (fails.append(m), print(f"  FAIL {m}")))
    print(f"  {len(fails)} gate failure(s)")
    sys.exit(1 if fails else 0)


def main():
    if not os.path.isdir(BUILD_DIR):
        die(f"{BUILD_DIR} does not exist. Build first.")
    built = f"{BUILD_DIR}/{IMG_XZ}"
    if not os.path.isfile(built):
        die(f"{built} missing. The build did not seal.")

    print(f"  version      : v{VER}" + (f" {ED_TITLE}" if EDITION else ""))
    print(f"  sealed build : {BUILD_DIR}")
    built_sha = sha256(built)
    print(f"  sha256       : {built_sha[:24]}...")

    # 1. The build's own .sha256 sidecar must agree with the file on disk. If it
    #    does not, the image was modified after sealing and nothing else can be
    #    trusted.
    side = f"{built}.sha256"
    if os.path.isfile(side):
        recorded = open(side).read().split()[0]
        if recorded != built_sha:
            die(f"{IMG_XZ} does not match its own .sha256 sidecar.\n"
                f"    sidecar: {recorded}\n    actual : {built_sha}")
        print("  ok  image matches its sealed sidecar")

    os.makedirs(UPLOAD_DIR, exist_ok=True)

    # 2. Report what is being replaced, so a stale stage is visible rather than silent.
    staged = f"{UPLOAD_DIR}/{IMG_XZ}"
    if os.path.isfile(staged):
        old = sha256(staged)
        if old == built_sha:
            print("  ok  UPLOAD folder already holds this exact build")
        else:
            print(f"  !!  UPLOAD folder held a DIFFERENT build ({old[:24]}...), replacing it")

    for name in CARRY:
        src = f"{BUILD_DIR}/{name}"
        if not os.path.isfile(src):
            die(f"{name} missing from the sealed build")
        shutil.copy2(src, f"{UPLOAD_DIR}/{name}")
    print(f"  staged {len(CARRY)} files into the UPLOAD folder")

    # 3. Re-verify AFTER the copy. A copy that silently truncated must not ship.
    if sha256(staged) != built_sha:
        die("staged image does not match the sealed build after copying")
    print("  ok  staged image sha256 == sealed build sha256")

    # 4. The hand-cleaned docs must be present and must not have regressed to
    #    carrying em-dashes or a sub-version string. Every .md in the folder is gated.
    gate_docs(die)

    # 5. Zip, then verify the zip's own copy of the image byte-for-byte. The whole
    #    point of this script is that the thing uploaded is the thing built.
    if os.path.isfile(ZIP_PATH):
        os.unlink(ZIP_PATH)
    print("  zipping...", flush=True)
    # zipfile rather than the `zip` binary: it is not installed everywhere, and a
    # missing tool must not be the reason a release does not get published.
    # ZIP_STORED because the payload is already xz-compressed; deflating 1.4 GB of
    # compressed data costs minutes and saves nothing.
    import zipfile
    base = os.path.basename(UPLOAD_DIR)
    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        for name in sorted(os.listdir(UPLOAD_DIR)):
            z.write(f"{UPLOAD_DIR}/{name}", f"{base}/{name}")

    # Read the image back OUT of the finished zip and hash it in chunks. This is
    # the check that would have caught the 2026-08-21 stale upload.
    with zipfile.ZipFile(ZIP_PATH) as z:
        h = hashlib.sha256()
        with z.open(f"{base}/{IMG_XZ}") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    if h.hexdigest() != built_sha:
        die("the image INSIDE the zip does not match the sealed build")

    size_gb = os.path.getsize(ZIP_PATH) / 1e9
    print(f"  ok  image inside the zip matches the sealed build")
    print(f"\n  {ZIP_PATH}\n  {size_gb:.2f} GB  image sha256 {built_sha[:24]}...\n")
    write_assets(built_sha)


ASSETS_MARK = "# generated by stage-and-zip.py"


def write_assets(xz_sha):
    """Upload v<VER>/ASSETS.txt from computed shas; draft-release.sh reads the asset lines."""
    up = os.path.join(os.path.dirname(UPLOAD_ROOT), f"Upload v{VER}" + (f" {ED_TITLE}" if EDITION else ""))
    os.makedirs(up, exist_ok=True)
    out = f"{up}/ASSETS.txt"
    if os.path.isfile(out) and ASSETS_MARK not in open(out, encoding="utf-8").read():
        os.replace(out, f"{out}.hand-written")
        print(f"  !!  hand-written ASSETS.txt kept as ASSETS.txt.hand-written")
    rows = [(ZIP_PATH, os.path.basename(ZIP_PATH).replace(" ", "."))]
    cl_up, cl_zip = f"{up}/CHANGELOG-v{VER}.md", f"{UPLOAD_DIR}/CHANGELOG-v{VER}.md"
    if os.path.isfile(cl_zip):
        if not os.path.isfile(cl_up) or sha256(cl_up) != sha256(cl_zip):
            die(f"{cl_up} missing or != the zip copy {cl_zip}")
        rows.append((cl_up, f"CHANGELOG-v{VER}.md"))
    for extra in EXTRA_ASSETS:
        rows.append((extra, os.path.basename(extra).replace(" ", ".")))
    img = f"{BUILD_DIR}/{IMG_XZ[:-3]}"
    img_sha = open(f"{img}.sha256").read().split()[0] if os.path.isfile(f"{img}.sha256") else "unknown"
    with open(out, "w", encoding="utf-8") as f:
        f.write(f"{ASSETS_MARK} v{VER}; DRAFT only, owner publishes\n")
        f.write(f"# image .img.xz sha256 {xz_sha}\n# image .img    sha256 {img_sha}\n")
        f.write("# asset <upload-name> <sha256> <size> <source path>\n")
        for path, name in rows:
            f.write(f"asset {name} {sha256(path)} {os.path.getsize(path)} {path}\n")
    print(f"  ok  {out}: {len(rows)} asset(s)")


if __name__ == "__main__":
    dry_run() if DRY_RUN else main()
