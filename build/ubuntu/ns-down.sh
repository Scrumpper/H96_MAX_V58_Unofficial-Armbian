#!/bin/bash
# Inside namespace: unmount chroot mounts and image, clear last-mounted, restore mount count, read-only fsck, detach loops.
set -uo pipefail
B=/root/rc-scratch; M=$B/mnt; read -r L1 L2 < "$B/loops"
for m in root/f5-log root/f5-in dev/pts dev sys proc/sys proc boot; do umount "$M/$m" || exit 1; done
rmdir "$M/root/f5-in" "$M/root/f5-log"
umount "$M" || exit 1
sync
for n in 1 2; do
  L=$L1; [ $n = 2 ] && L=$L2; P=$B/log/sb-p$n-pre.txt
  lm=""  # base value names build host paths
  mc=$(sed -n 's/^Mount count: *//p' "$P")
  tune2fs -M "$lm" -C "$mc" "$L" > /dev/null && echo "p$n last-mounted '${lm}' mount-count $mc restored" || echo "p$n tune2fs failed"
  dumpe2fs -h "$L" > "$B/log/sb-p$n-post.txt" 2>/dev/null
  diff "$P" "$B/log/sb-p$n-post.txt" | grep '^[<>]' | sed "s/^/p$n sb diff: /"
done
e2fsck -fn "$L1"; r1=$?; e2fsck -fn "$L2"; r2=$?; echo "e2fsck p1 rc=$r1 p2 rc=$r2"
losetup -d "$L1" "$L2"; losetup -a | grep -c rc-scratch || true
