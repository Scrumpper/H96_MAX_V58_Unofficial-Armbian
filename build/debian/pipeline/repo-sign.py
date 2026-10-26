#!/usr/bin/env python3
"""Release + InRelease + Release.gpg over Packages/Packages.gz; private key stays on build host."""
import hashlib, os, subprocess, sys
ONLY = "--release-only" in sys.argv  # write Release, skip signing
W = [a for a in sys.argv[1:] if a != "--release-only"][0]
KD = os.environ.get("H96_REPO_GNUPG", "")  # owner key dir: gnupg/, FINGERPRINT, h96-local-archive-keyring.gpg (never in repo)
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
if ONLY:
    sys.exit(0)
env = dict(os.environ, GNUPGHOME=f"{KD}/gnupg")
fpr = open(f"{KD}/FINGERPRINT").read().strip()
for args in (["--clearsign", "-o", f"{W}/InRelease", rel], ["-abs", "-o", f"{W}/Release.gpg", rel]):
    subprocess.run(["gpg", "--batch", "-q", "--yes", "--faked-system-time", "20260101T000100!", "--local-user", fpr,
                    "--digest-algo", "SHA256", *args], env=env, check=True)
for p in ([f"{W}/InRelease"], [f"{W}/Release.gpg", rel]):
    r = subprocess.run(["gpgv", "--keyring", f"{KD}/h96-local-archive-keyring.gpg", *p], capture_output=True, text=True)
    if r.returncode or "Good signature" not in r.stderr:
        sys.exit(f"gpgv failed {p}: {r.stderr}")
print("signed and verified")
