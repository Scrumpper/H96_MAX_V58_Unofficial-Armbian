#!/bin/bash
# Run inside private mount namespace holder: scratch rw, host / and /boot ro (checked by mount flags, no write), image partitions on offset loops, chroot mounts.
set -euo pipefail
B=/root/rc-scratch; M=$B/mnt; IMG=$B/work.img
P1_OFF=16777216; P1_SZ=$((1046528*512)); P2_OFF=553648128; P2_SZ=$((6141952*512))
isro() { findmnt -no OPTIONS -M "$1" | tr , '\n' | grep -qx ro; }
mount --bind "$B" "$B"
mount -o remount,bind,ro /
mount -o remount,bind,ro /boot
isro /boot && echo "host /boot ro ok" || { echo "HOST /boot not ro: abort"; exit 1; }
isro / && echo "host / ro ok" || { echo "HOST / not ro: abort"; exit 1; }
isro "$B" && { echo "scratch ro: abort"; exit 1; }
L2=$(losetup --find --show --offset $P2_OFF --sizelimit $P2_SZ "$IMG"); L1=$(losetup --find --show --offset $P1_OFF --sizelimit $P1_SZ "$IMG")
echo "$L1 $L2" > "$B/loops"
blkid -c /dev/null "$L1" "$L2"
# superblock before first mount, for last-mounted reset
dumpe2fs -h "$L1" > "$B/log/sb-p1-pre.txt" 2>/dev/null; dumpe2fs -h "$L2" > "$B/log/sb-p2-pre.txt" 2>/dev/null
grep -h 'Last mounted on' "$B/log/sb-p1-pre.txt" "$B/log/sb-p2-pre.txt"
mkdir -p "$M"; mount "$L2" "$M"; mount "$L1" "$M/boot"
ls -la "$M/run" "$M/etc/blkid.tab" "$M/var/cache/apt" > "$B/log/base-leaks.txt" 2>&1 || true
mount -t proc proc "$M/proc"
mount --bind "$M/proc/sys" "$M/proc/sys"; mount -o remount,bind,ro "$M/proc/sys"
mount -t sysfs -o ro sysfs "$M/sys"
mount --bind /dev "$M/dev"; mount --bind /dev/pts "$M/dev/pts"
mkdir -p "$M/root/f5-in" "$M/root/f5-log"; mount --bind "$B/in" "$M/root/f5-in"; mount --bind "$B/log" "$M/root/f5-log"
findmnt -R -o TARGET,SOURCE,OPTIONS "$M"; findmnt -no TARGET,OPTIONS -M /; findmnt -no TARGET,OPTIONS -M /boot
