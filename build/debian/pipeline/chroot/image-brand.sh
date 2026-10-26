#!/bin/bash
# Inside image chroot after F5 and kernel stage (Debian edition): issue, issue.net, os-release VARIANT through h96-branding.sh.
set -uo pipefail
L=/root/f5-log/brand; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
for f in /etc/issue /etc/issue.net /etc/os-release /etc/armbian-release /etc/h96-release; do cp -p "$f" "$L/pre-$(basename "$f")" 2>/dev/null; done
bash /usr/lib/h96/h96-branding.sh > "$L/branding.txt" 2>&1; echo "h96-branding.sh rc=$?"
bash /usr/lib/h96/h96-branding.sh > /dev/null 2>&1
for f in /etc/issue /etc/issue.net /etc/os-release /etc/armbian-release; do cp -p "$f" "$L/post-$(basename "$f")"; done
rel=$(sed -n 's/^H96_RELEASE=//p' /etc/h96-release); ed=$(sed -n 's/^H96_EDITION=//p' /etc/h96-release)
echo "H96_RELEASE=$rel H96_EDITION=$ed"
[ "$rel" = v8.0 ] && ok "h96-release $rel" || bad "h96-release '$rel'"
[ "$ed" = debian ] && ok "H96_EDITION debian" || bad "H96_EDITION '$ed'"
cmp -s /etc/h96-issue /etc/issue && ok "/etc/issue = h96-issue" || bad "/etc/issue"
cmp -s /etc/h96-issue.net /etc/issue.net && ok "/etc/issue.net = h96-issue.net" || bad "/etc/issue.net"
for f in /etc/issue /etc/issue.net; do
  grep -q 'Unofficial Port v8\.0 Debian Edition)' "$f" && ! grep -q 'v7\.\|beta\|26\.05' "$f" && ok "$f: $(head -1 "$f")" || bad "$f text: $(head -1 "$f")"
done
[ -f /etc/os-release ] && [ ! -L /etc/os-release ] && ok "os-release regular file" || bad "os-release not regular file"
[ "$(grep -c '^VARIANT=' /etc/os-release)" = 1 ] && grep -qxF 'VARIANT="H96 Max V58 Unofficial Port v8.0 Debian Edition"' /etc/os-release && ok "os-release VARIANT Debian Edition" || bad "VARIANT: $(grep '^VARIANT=' /etc/os-release)"
grep -qx 'VARIANT_ID=h96-max-v58' /etc/os-release && ok "VARIANT_ID" || bad "VARIANT_ID"
grep -qx 'ID=debian' /etc/os-release && grep -qx 'VERSION_CODENAME=trixie' /etc/os-release && ok "os-release ID=debian trixie" || bad "os-release ID/codename"
grep -qx 'BOARD_NAME="H96 Max V58"' /etc/armbian-release && ok "BOARD_NAME" || bad "BOARD_NAME"
grep -qx 'DISTRIBUTION_CODENAME=trixie' /etc/armbian-release && ok "armbian-release trixie" || bad "armbian-release codename"
diff "$L/pre-os-release" "$L/post-os-release" | grep '^[<>]' | sed 's/^/os-release diff: /'
diff "$L/pre-armbian-release" "$L/post-armbian-release" | grep '^[<>]' | sed 's/^/armbian-release diff: /'
dpkg -V base-files h96-base > "$L/dpkg-V.txt" 2>&1; echo "dpkg -V base-files h96-base lines=$(wc -l < "$L/dpkg-V.txt")"; cat "$L/dpkg-V.txt"
echo "fail=$fail"; exit $fail
