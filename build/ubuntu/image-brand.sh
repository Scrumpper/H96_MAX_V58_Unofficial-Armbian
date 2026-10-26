#!/bin/bash
# Inside image chroot after F5 and kernel stage: first-console branding at image time (issue, issue.net, os-release VARIANT).
set -uo pipefail
L=/root/f5-log/brand; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
for f in /etc/issue /etc/issue.net /etc/os-release /etc/armbian-release /etc/h96-release; do cp -p "$f" "$L/pre-$(basename "$f")" 2>/dev/null; done
bash /usr/lib/h96/h96-branding.sh > "$L/branding.txt" 2>&1; echo "h96-branding.sh rc=$?"
bash /usr/lib/h96/h96-branding.sh > /dev/null 2>&1
for f in /etc/issue /etc/issue.net /etc/os-release /etc/armbian-release; do cp -p "$f" "$L/post-$(basename "$f")"; done
rel=$(sed -n 's/^H96_RELEASE=//p' /etc/h96-release)
echo "H96_RELEASE=$rel"
case "$rel" in v8.0) ok "h96-release $rel" ;; *) bad "h96-release '$rel' (want v8.0)" ;; esac
cmp -s /etc/h96-issue /etc/issue && ok "/etc/issue = h96-issue" || bad "/etc/issue"
cmp -s /etc/h96-issue.net /etc/issue.net && ok "/etc/issue.net = h96-issue.net" || bad "/etc/issue.net"
grep -q 'Unofficial Port v8\.0)' /etc/issue && ! grep -q 'v7\.\|beta' /etc/issue && ok "issue names v8.0" || bad "issue text: $(head -1 /etc/issue)"
grep -q 'Unofficial Port v8\.0)' /etc/issue.net && ! grep -q 'v7\.\|beta' /etc/issue.net && ok "issue.net names v8.0" || bad "issue.net text"
[ -f /etc/os-release ] && [ ! -L /etc/os-release ] && ok "os-release regular file" || bad "os-release not regular file"
[ "$(grep -c '^VARIANT=' /etc/os-release)" = 1 ] && grep -qxF "VARIANT=\"H96 Max V58 Unofficial Port $rel\"" /etc/os-release && ok "os-release VARIANT $rel" || bad "os-release VARIANT: $(grep '^VARIANT=' /etc/os-release)"
grep -qx 'VARIANT_ID=h96-max-v58' /etc/os-release && ok "VARIANT_ID" || bad "VARIANT_ID"
grep -qx 'BOARD_NAME="H96 Max V58"' /etc/armbian-release && ok "BOARD_NAME" || bad "BOARD_NAME"
diff "$L/pre-os-release" "$L/post-os-release" | grep '^[<>]' | sed 's/^/os-release diff: /'
diff "$L/pre-armbian-release" "$L/post-armbian-release" | grep '^[<>]' | sed 's/^/armbian-release diff: /'
dpkg -V base-files h96-base > "$L/dpkg-V.txt" 2>&1; echo "dpkg -V base-files h96-base lines=$(wc -l < "$L/dpkg-V.txt")"; cat "$L/dpkg-V.txt"
echo "fail=$fail"; exit $fail
