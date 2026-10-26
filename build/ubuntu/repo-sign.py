#!/usr/bin/env python3
"""Release + InRelease + Release.gpg over Packages/Packages.gz; private key stays on build host.
H96_REPO_KEYDIR: gnupg/, FINGERPRINT, keyring (owner). H96_REPO_SIG_FROM: published Release, InRelease, Release.gpg (rebuild)."""
import hashlib, os, shutil, subprocess, sys
W = sys.argv[1]
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
KD = os.environ.get("H96_REPO_KEYDIR", "")
PUB = os.path.join(REPO, "keys", "offline-repo-public.gpg")
HEAD = ("Origin: H96 Max V58\nLabel: H96 offline packages\nSuite: ./\nArchitectures: arm64 all\n"
        "Date: Thu, 01 Jan 2026 00:00:00 UTC\n"
        "Description: Packages the H96 Max V58 image installs on first boot without network\n")
files = {n: open(f"{W}/{n}", "rb").read() for n in ("Packages", "Packages.gz")}
out = [HEAD.rstrip("\n")]
for field, alg in (("MD5Sum", "md5"), ("SHA256", "sha256")):
    out.append(f"{field}:")
    out += [f" {hashlib.new(alg, d).hexdigest()} {len(d)} {n}" for n, d in files.items()]
rel = f"{W}/Release"
open(rel, "w").write("\n".join(out) + "\n")
SIG = os.environ.get("H96_REPO_SIG_FROM", "")
if SIG:
    # rebuild without private key: rebuilt Release must equal published one; published signatures reused
    if open(f"{SIG}/Release", "rb").read() != open(rel, "rb").read():
        sys.exit("rebuilt Release differs from published Release")
    for n in ("InRelease", "Release.gpg"):
        shutil.copyfile(f"{SIG}/{n}", f"{W}/{n}")
    KD = ""
if not SIG and not KD:
    sys.exit("set H96_REPO_KEYDIR (signing key) or H96_REPO_SIG_FROM (published signatures)")
env = dict(os.environ, GNUPGHOME=f"{KD}/gnupg")
fpr = open(f"{KD}/FINGERPRINT").read().strip() if KD else ""
for args in ([] if SIG else (["--clearsign", "-o", f"{W}/InRelease", rel], ["-abs", "-o", f"{W}/Release.gpg", rel])):
    subprocess.run(["gpg", "--batch", "-q", "--yes", "--faked-system-time", "20260101T000100!", "--local-user", fpr,
                    "--digest-algo", "SHA256", *args], env=env, check=True)
for p in ([f"{W}/InRelease"], [f"{W}/Release.gpg", rel]):
    r = subprocess.run(["gpgv", "--keyring", f"{KD}/h96-local-archive-keyring.gpg" if KD else PUB, *p], capture_output=True, text=True)
    if r.returncode or "Good signature" not in r.stderr:
        sys.exit(f"gpgv failed {p}: {r.stderr}")
if SIG:
    r = subprocess.run(["gpgv", "--keyring", PUB, "--output", "-", f"{W}/InRelease"], capture_output=True)
    if r.stdout != open(rel, "rb").read():
        sys.exit("published InRelease body differs from rebuilt Release")
print("published signature verified" if SIG else "signed and verified")
