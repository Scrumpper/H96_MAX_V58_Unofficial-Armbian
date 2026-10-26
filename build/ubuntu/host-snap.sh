#!/bin/bash
# Host state snapshot on box (read-only): /boot listing and sums, dpkg db sums, free space, loops, mounts.
set -uo pipefail
T=${1:?tag}; O=/root/rc-host-$T; mkdir -p "$O"
ls -laR /boot > "$O/boot-lsR.txt"; md5sum < "$O/boot-lsR.txt" | cut -d' ' -f1 > "$O/boot-lsR.md5"
find /boot -xdev -type f -print0 | sort -z | xargs -0 sha256sum > "$O/boot-sha.txt"; md5sum < "$O/boot-sha.txt" | cut -d' ' -f1 > "$O/boot-sha.md5"
md5sum /var/lib/dpkg/status /var/lib/dpkg/diversions /var/lib/dpkg/statoverride > "$O/dpkgdb.md5"
dpkg-divert --list | wc -l > "$O/diversions.count"
df -B1 / /boot > "$O/df.txt"; losetup -a > "$O/losetup.txt"; findmnt -rn -o TARGET | sort > "$O/mounts.txt"
ls -l /dev/disk/by-uuid /dev/disk/by-label > "$O/by-uuid.txt" 2>&1
echo "$T boot-lsR $(cat "$O/boot-lsR.md5") boot-sha $(cat "$O/boot-sha.md5") files $(wc -l < "$O/boot-sha.txt") divs $(cat "$O/diversions.count")"
cat "$O/dpkgdb.md5"; awk 'NR>1{print $6, $4}' "$O/df.txt"; echo "loops: $(wc -l < "$O/losetup.txt") mounts: $(wc -l < "$O/mounts.txt")"
