#!/bin/bash
# r16 (from r14-laptop): inside user+mount+pid+net namespace (build.sh chroot). Mirrors ns-up.sh, box-run.sh steps, ns-down.sh mounts:
# host / and /boot ro (flags checked, no probe write), image trees rw, p1 tree on p2/boot, chroot steps, unmount.
set -uo pipefail
W="$1"; R=$W/p2; I=$W/in; LOGD=$W/log
STEPS="repo-apply.sh f5-chroot.sh stage-kernel.sh image-brand.sh final-check.sh image-clean.sh"
isro() { findmnt -no OPTIONS -M "$1" | tr , '\n' | grep -qx ro; }
mount --bind "$W" "$W" || exit 1
mount -o remount,bind,ro / || exit 1
mount -o remount,bind,ro /boot || exit 1
isro /boot && echo "host /boot ro ok" || { echo "HOST /boot not ro: abort"; exit 1; }
isro / && echo "host / ro ok" || { echo "HOST / not ro: abort"; exit 1; }
isro "$W" && { echo "work ro: abort"; exit 1; }
mount --bind "$W/p1" "$R/boot" || exit 1
ls -la "$R/run" "$R/etc/blkid.tab" "$R/var/cache/apt" > "$LOGD/base-leaks.txt" 2>&1 || true
mount -t proc proc "$R/proc" || exit 1
mount --bind "$R/proc/sys" "$R/proc/sys" && mount -o remount,bind,ro "$R/proc/sys" || exit 1
mount -t sysfs -o ro sysfs "$R/sys" || exit 1
# chroot /dev: tmpfs with host nodes bound in (user namespace refuses plain bind of host /dev)
mount -t tmpfs -o mode=755,nosuid tmpfs "$R/dev" || exit 1
for n in null zero full random urandom tty; do touch "$R/dev/$n" && mount --bind "/dev/$n" "$R/dev/$n" || exit 1; done
mkdir "$R/dev/pts" "$R/dev/shm" && mount --bind /dev/pts "$R/dev/pts" && mount -t tmpfs -o nosuid,nodev tmpfs "$R/dev/shm" || exit 1
ln -s pts/ptmx "$R/dev/ptmx"; ln -s /proc/self/fd "$R/dev/fd"
ln -s /proc/self/fd/0 "$R/dev/stdin"; ln -s /proc/self/fd/1 "$R/dev/stdout"; ln -s /proc/self/fd/2 "$R/dev/stderr"
# box: live partitions carry image UUIDs, so hooks resolve root/boot by UUID (initramfs fsck hook); same with ro base copies
mkdir -p "$R/dev/disk/by-uuid"
for n in 1 2; do
  touch "$R/dev/h96-rc-p$n" && mount --bind "$W/p$n.base" "$R/dev/h96-rc-p$n" && mount -o remount,bind,ro "$R/dev/h96-rc-p$n" || exit 1
  ln -s "../../h96-rc-p$n" "$R/dev/disk/by-uuid/$(blkid -p -s UUID -o value "$W/p$n.base")"
done
[ -c "$R/dev/null" ] && [ -d "$R/dev/pts" ] || { echo "chroot /dev not usable: abort"; exit 1; }
# libblkid takes no regular file from udev links: probe once so image blkid cache (/run/blkid, removed by image-clean.sh) lists them
chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin blkid /dev/h96-rc-p1 /dev/h96-rc-p2
chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin blkid -o value -s TYPE "$(chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin blkid -l -t "UUID=$(blkid -p -s UUID -o value "$W/p2.base")" -o device)" | grep -qx ext4 \
  && echo "root UUID resolves to ext4 in chroot" || { echo "root UUID not resolvable in chroot: abort"; exit 1; }
mkdir -p "$R/root/f5-in" "$R/root/f5-log"; mount --bind "$I" "$R/root/f5-in" && mount --bind "$LOGD" "$R/root/f5-log" || exit 1
findmnt -o TARGET,SOURCE,OPTIONS | grep -F "$W/"; findmnt -no TARGET,OPTIONS -M /; findmnt -no TARGET,OPTIONS -M /boot
rc=0
for s in $STEPS; do
  chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C HOME=/root TERM=dumb /bin/bash "/root/f5-in/$s" 2>&1 | tee "$LOGD/${s%.sh}-run.txt"
  rc=${PIPESTATUS[0]}; echo "$s rc=$rc"
  [ "$rc" = 0 ] || { echo "STOP at $s"; break; }
done
umount -R "$R/dev" || { echo "umount dev failed"; rc=1; }
for m in root/f5-log root/f5-in sys proc/sys proc boot; do umount "$R/$m" || { echo "umount $m failed"; rc=1; }; done
rmdir "$R/root/f5-in" "$R/root/f5-log" || rc=1
findmnt -rn -o TARGET | grep -F "$W/p" && { echo "mounts left on trees"; rc=1; }
echo "chroot-ns rc=$rc"; exit "$rc"
