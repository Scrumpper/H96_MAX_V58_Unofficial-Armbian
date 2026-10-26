#!/bin/bash
# Light dry-run from a repo checkout (no inputs, no network, no root): syntax of every script, pins file format,
# pins agree with pipeline/inputs.sha256, repo-sig signatures against keys/offline-repo-public.gpg, no host paths.
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/env.sh"
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
n=0; for s in $(find "$H" -name '*.sh' | sort) "$H/pipeline/f5-rows-debian.sh"; do bash -n "$s" || bad "bash -n $s"; n=$((n+1)); done; ok "bash -n: $n scripts"
n=0; for s in $(find "$H" -name '*.py' | sort); do python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$s" || bad "python parse $s"; n=$((n+1)); done; ok "python parse: $n files"
if command -v shellcheck > /dev/null; then
  (cd "$H" && shellcheck -S warning -e SC1090,SC1091 ./*.sh pipeline/*.sh pipeline/chroot/*.sh pipeline/prep-in/*.sh pipeline/repo-in/*.sh userland/*.sh tools/*.sh video/run.sh wp/run.sh) > "${TMPDIR:-/tmp}/h96-deb-shellcheck.txt" 2>&1 && ok "shellcheck -S warning clean" || bad "shellcheck: $(grep -c '^In ' "${TMPDIR:-/tmp}/h96-deb-shellcheck.txt") findings (${TMPDIR:-/tmp}/h96-deb-shellcheck.txt)"
else echo "SKIP shellcheck not installed"; fi
awk -F'\t' 'NR>1 && (NF!=5 || $3 !~ /^[0-9a-f]{64}$/ || ($4 !~ /^[0-9]+$/ && $4!="-")) {print "bad row " NR ": " $1; e=1} END{exit e}' "$PINS" && ok "pins file: $(($(wc -l < "$PINS") - 1)) rows, 5 columns, sha256 and size format" || bad "pins file format"
[ -z "$(cut -f1 "$PINS" | sort | uniq -d)" ] && ok "pins names unique" || bad "duplicate pins names"
m=0; while read -r s b; do case "$b" in *.deb) [ "$(pin "debs/$b")" = "$s" ] || { bad "inputs.sha256 $b not in pins"; m=1; } ;; *.py|*.sh) [ "$(sha256sum < "$(compgen -G "$H96_REPO/build/debian/pipeline/$b" || echo "$H96_REPO/tools/$b")" | cut -d' ' -f1)" = "$s" ] || { bad "$b in repo differs from inputs.sha256"; m=1; } ;; esac; done < "$H/pipeline/inputs.sha256"
[ "$m" = 0 ] && ok "pipeline/inputs.sha256 ($(wc -l < "$H/pipeline/inputs.sha256") lines) = pins file and repo files"
if [ -f "$KEYRING" ]; then
  gpgv --keyring "$KEYRING" "$H/repo-sig/InRelease" > /dev/null 2>&1 && ok "repo-sig/InRelease good signature" || bad "repo-sig/InRelease gpgv"
  sed -n '/^Origin:/,/^-----BEGIN PGP SIGNATURE/p' "$H/repo-sig/InRelease" | sed '$d' > "${TMPDIR:-/tmp}/h96-deb-Release"
  [ "$(sha256sum < "${TMPDIR:-/tmp}/h96-deb-Release" | cut -d' ' -f1)" = "$(pin repo/Release)" ] && ok "InRelease body = pinned Release" || bad "InRelease body vs pinned Release"
  gpgv --keyring "$KEYRING" "$H/repo-sig/Release.gpg" "${TMPDIR:-/tmp}/h96-deb-Release" > /dev/null 2>&1 && ok "repo-sig/Release.gpg good signature over pinned Release" || bad "Release.gpg gpgv"
else echo "SKIP $KEYRING missing (keys/offline-repo-public.gpg)"; fi
for f in InRelease Release.gpg; do [ "$(sha256sum < "$H/repo-sig/$f" | cut -d' ' -f1)" = "$(pin "repo/$f")" ] || bad "repo-sig/$f vs pins"; done
out=$(grep -rnE '/home/|~/Desktop|Desktop/H96|192\.168\.|\.cache/h96|BEGIN PGP PRIVATE' "$H" "$PINS" | grep -v 'check.sh:' | grep -v 'pipeline/t11-in/t11-firstlogin.sh:.*/home/h96test' | grep -v 'skel/Desktop\|/Desktop/COMMANDS\|RealUserName' | grep -v 'generator/userland-edition.patch:.*v72-rootfs.tar.zst' )
# generator patch keeps two context lines of upstream generator (v7.2 tarball path); context must match to apply
[ -z "$out" ] && ok "no host paths, LAN addresses or private key blocks" || { echo "$out" | head; bad "host path or key text"; }
echo "check fail=$fail"; exit $fail
