#!/bin/bash
# Light recipe gate (no inputs, no build): syntax, pin table vs stage pins, repo copies vs pins, public key, pkgs manifest.
# Usage: check-recipe.sh
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../.." && pwd); TSV=$R/build/pins/ubuntu-inputs.tsv
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
n=0; for f in "$H"/*.sh "$R"/build/userland/*.sh "$R"/build/kernel/*.sh "$R"/build/*.sh; do [ -f "$f" ] || continue; bash -n "$f" && n=$((n + 1)) || bad "bash -n $f"; done
ok "bash -n: $n scripts"
n=0; for f in "$H"/*.py "$R"/build/userland/*.py "$R"/build/kernel/*.py; do [ -f "$f" ] || continue; python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" && n=$((n + 1)) || bad "parse $f"; done
ok "python parse: $n scripts"
if command -v shellcheck >/dev/null; then (cd "$H" && shellcheck -S warning -e SC1090,SC1091 ./*.sh) >/dev/null && ok "shellcheck -S warning clean (build/ubuntu)" || bad "shellcheck build/ubuntu"; fi
awk -F'\t' 'NR>1 && (NF!=5 || $3 !~ /^[0-9a-f]{64}$/)' "$TSV" | grep -q . && bad "ubuntu-inputs.tsv rows not 5 columns with sha256" || ok "ubuntu-inputs.tsv: $(($(wc -l < "$TSV") - 1)) rows, 5 columns, sha256 format"
s=$(grep -vc '^#' "$H/inputs.src"); p=$(grep -c . "$H/inputs.sha256")
[ "$s" = "$p" ] && ok "inputs.src rows = inputs.sha256 rows ($p)" || bad "inputs.src $s rows, inputs.sha256 $p"
m=0; while read -r h f; do awk -F'\t' -v f="$f" -v h="$h" '$1==f && $3==h {x=1} END {exit !x}' "$TSV" && m=$((m + 1)) || bad "pin $f $h not in ubuntu-inputs.tsv"; done < "$H/inputs.sha256"
ok "stage pins in ubuntu-inputs.tsv: $m of $p"
for x in "f5-rows.sh build/userland/f5-rows.sh" "h96-selftest.py tools/h96-selftest.py"; do
  set -- $x; [ "$(sha256sum < "$R/$2" | cut -d' ' -f1)" = "$(awk -v f="$1" '$2==f {print $1}' "$H/inputs.sha256")" ] && ok "$2 = pin" || bad "$2 differs from pin (check out tagged commit)"
done
c=$(sed -n "s/^CHECKER_SHA = '\([0-9a-f]*\)'/\1/p" "$H/loader-pin.py")
[ "$(sha256sum < "$H/preflight_check.py" | cut -d' ' -f1)" = "$c" ] && ok "preflight_check.py = loader-pin.py pin" || bad "preflight_check.py sha"
K=$R/keys/offline-repo-public.gpg
fp=$(gpg --show-keys --with-colons "$K" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
[ "$fp" = "$(cat "$R/keys/offline-repo-public.fingerprint")" ] && ok "public keyring fingerprint $fp" || bad "keyring fingerprint $fp"
gpg --show-keys --with-colons "$K" 2>/dev/null | grep -q '^sec' && bad "secret key in public keyring" || ok "public keyring holds no secret key"
python3 -I "$R/build/userland/prepare-pkgs.py" --check | sed 's/^/  /'; [ "${PIPESTATUS[0]}" = 0 ] && ok "pkgs tree = pkgs.manifest (text and symlinks)" || bad "pkgs tree vs manifest"
grep -q PLACEHOLDER "$H/inputs.sha256" && bad "inputs.sha256 holds PLACEHOLDER" || ok "no PLACEHOLDER pin"
"$H/stage.sh" > /dev/null 2>&1; [ $? = 2 ] && ok "stage.sh usage rc=2" || bad "stage.sh usage"
"$H/build.sh" > /dev/null 2>&1; [ $? = 2 ] && ok "build.sh usage rc=2" || bad "build.sh usage"
echo "check-recipe fail=$fail"; exit $fail
