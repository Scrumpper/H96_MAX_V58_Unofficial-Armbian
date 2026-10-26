#!/bin/bash
# Inside image chroot, after final-check: drop apt caches (binary caches, downloaded debs) and blkid cache left by chroot work.
set -uo pipefail
L=/root/f5-log/final; fail=0
rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin
find /var/cache/apt/archives -maxdepth 2 -type f \( -name '*.deb' -o -path '*/partial/*' \) -delete 2>/dev/null
rm -rf /run/blkid; rm -f /etc/blkid.tab /etc/blkid.tab.old
ls -la /var/cache/apt /run > "$L/clean-after.txt" 2>&1
ls /var/cache/apt/*.bin >/dev/null 2>&1 && { echo "FAIL apt bin caches left"; fail=1; } || echo "PASS no apt bin caches"
find /var/cache/apt/archives -type f \( -name '*.deb' -o -path '*/partial/*' \) 2>/dev/null | grep -q . && { echo "FAIL apt archives left"; fail=1; } || echo "PASS no apt archives"
[ -e /run/blkid ] || [ -e /etc/blkid.tab ] && { echo "FAIL blkid cache left"; fail=1; } || echo "PASS no blkid cache"
[ -e /usr/sbin/policy-rc.d ] && { echo "FAIL policy-rc.d"; fail=1; } || echo "PASS policy-rc.d absent"
echo "fail=$fail"; exit $fail
