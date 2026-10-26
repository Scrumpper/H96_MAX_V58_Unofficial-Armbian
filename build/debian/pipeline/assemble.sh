#!/bin/bash
# Stage 7 assemble (laptop, rootless): built rootfs tarball split into p1 tree (/boot) and p2 tree; ext4 images with
# mke2fs -d inside podman unshare (owners kept), feature set of Ubuntu 8.0 image (no metadata_csum_seed, no orphan_file:
# vendor U-Boot 2017.09 reads p1); sectors 0..32767 (primary GPT, old loader set) and last 1 MiB (backup GPT) from v7.2
# image, so geometry and GPT bytes equal Ubuntu 8.0; e2fsck -fn both; caps and owners checked with debugfs.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR/assemble
V72XZ="$IN/H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz"; V72IMG=$(pin H96-MAX-V58_Unofficial-Armbian_v7.2.img)
IMG=$W/$NAME.img
SIZE=3699376128; P1_OFF=16777216; P1_BLK=130816; P2_OFF=553648128; P2_BLK=767744; P2_INODES=192000
FEAT=none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,64bit,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize,metadata_csum
. "$H/uuids.env"
export E2FSPROGS_FAKE_TIME=1792540800   # 2026-10-21 00:00 UTC: fixed superblock and lost+found times
rm -rf "$EV"; mkdir -p "$EV"
[ "$(sha256sum < "$W/built-rootfs.tar.zst" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$EVR/build/built-tarball.sha256")" ] || { echo "built tarball sha"; exit 1; }
[ "$(sha256sum < "$V72XZ" | cut -d' ' -f1)" = "$(pin H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz)" ] || { echo "v7.2 xz sha"; exit 1; }
# raw areas from v7.2 image (one stream: whole-image sha checked at the same time)
xz -dc "$V72XZ" | tee -p >(head -c 16777216 > "$W/v72-head.bin") >(tail -c 1048576 > "$W/v72-tail.bin") | sha256sum | cut -d' ' -f1 > "$W/v72.sha"
sleep 2; [ "$(cat "$W/v72.sha")" = "$V72IMG" ] && echo "PASS v7.2 img sha (9f366f09)" || { echo "v7.2 img sha"; exit 1; }
[ "$(stat -c %s "$W/v72-head.bin")" = 16777216 ] && [ "$(stat -c %s "$W/v72-tail.bin")" = 1048576 ] || { echo "raw area sizes"; exit 1; }
T=$W/assemble; [ -e "$T" ] && podman unshare rm -rf "$T"; mkdir -p "$T/p2"
podman unshare tar --zstd --numeric-owner --xattrs --xattrs-include='*' -xpf "$W/built-rootfs.tar.zst" -C "$T/p2"
podman unshare sh -c 'mv "$1/p2/boot" "$1/p1" && mkdir "$1/p2/boot" && chmod 755 "$1/p2/boot"' _ "$T"
rm -f "$T/p1.img" "$T/p2.img"
podman unshare mke2fs -q -F -t ext4 -O "$FEAT" -b 4096 -I 256 -G 16 -m 0 -L BOOT -U "$P1_UUID" -E hash_seed=$P1_UUID -d "$T/p1" "$T/p1.img" "$P1_BLK"
podman unshare mke2fs -q -F -t ext4 -O "$FEAT" -b 4096 -I 256 -G 16 -m 0 -N "$P2_INODES" -L ROOTFS -U "$P2_UUID" -E hash_seed=$P2_UUID -d "$T/p2" "$T/p2.img" "$P2_BLK"
for p in p1 p2; do e2fsck -fn "$T/$p.img" > "$EV/e2fsck-$p.txt" 2>&1 && echo "PASS e2fsck -fn $p" || { cat "$EV/e2fsck-$p.txt"; echo "FAIL e2fsck $p"; exit 1; }
  dumpe2fs -h "$T/$p.img" > "$EV/sb-$p.txt" 2>/dev/null; done
grep -h 'Filesystem features' "$EV"/sb-p*.txt
# image: v7.2 head, p1, p2, v7.2 tail
rm -f "$IMG"; truncate -s "$SIZE" "$IMG"
dd if="$W/v72-head.bin" of="$IMG" conv=notrunc status=none
dd if="$T/p1.img" of="$IMG" bs=1M seek=$((P1_OFF / 1048576)) conv=notrunc,sparse status=none
dd if="$T/p2.img" of="$IMG" bs=1M seek=$((P2_OFF / 1048576)) conv=notrunc,sparse status=none
dd if="$W/v72-tail.bin" of="$IMG" bs=1M seek=$(( (SIZE - 1048576) / 1048576 )) conv=notrunc status=none
[ "$(stat -c %s "$IMG")" = "$SIZE" ] && echo "PASS image size $SIZE"
cmp -n 16777216 "$IMG" "$W/v72-head.bin" && echo "PASS sectors 0..32767 = v7.2 (GPT, old loader set)"
cmp <(tail -c 1048576 "$IMG") "$W/v72-tail.bin" && echo "PASS last 1 MiB = v7.2 (backup GPT)"
sfdisk -d "$IMG" | sed 1,3d > "$EV/sfdisk.txt"; cat "$EV/sfdisk.txt"
# T13 checks on the image partitions (debugfs, read only)
D1="$IMG?offset=$P1_OFF"; D2="$IMG?offset=$P2_OFF"
dbg() { debugfs -R "$1" "$2" 2>/dev/null; }
[ "$(dbg 'stat /Image' "$D1" | sed -n 's/^Fast link dest: "\(.*\)"/\1/p')" = Image-6.12.69-h96v58-8.0 ] && echo "PASS p1 Image link on 6.12 final" || echo "FAIL p1 Image link"
[ "$(dbg 'stat /uInitrd' "$D1" | sed -n 's/^Fast link dest: "\(.*\)"/\1/p')" = uInitrd-6.12.69-h96v58-8.0 ] && echo "PASS p1 uInitrd link" || echo "FAIL p1 uInitrd link"
dbg 'cat /boot.scr' "$D1" | sha256sum | cut -c1-16 > "$EV/bootscr.sha"; tar --zstd -xOf "$V72" ./boot/boot.scr | sha256sum | cut -c1-16 > "$EV/bootscr-v72.sha"
cmp -s "$EV/bootscr.sha" "$EV/bootscr-v72.sha" && echo "PASS boot.scr = v7.2 ($(cat "$EV/bootscr.sha"))" || echo "FAIL boot.scr"
dbg 'cat /armbianEnv.txt' "$D1" | grep -qx "rootdev=UUID=$P2_UUID" && echo "PASS armbianEnv rootdev = p2 UUID" || echo "FAIL rootdev"
dbg 'cat /etc/fstab' "$D2" > "$EV/fstab"; grep -q "^UUID=$P2_UUID  / " "$EV/fstab" && grep -q "^UUID=$P1_UUID  /boot " "$EV/fstab" && echo "PASS fstab UUIDs" || echo "FAIL fstab"
[ "$(blkid -o value -s UUID "$T/p1.img")" = "$P1_UUID" ] && [ "$(blkid -o value -s UUID "$T/p2.img")" = "$P2_UUID" ] && echo "PASS filesystem UUIDs" || echo "FAIL fs UUIDs"
dbg 'ea_list /usr/bin/fping' "$D2" | tee "$EV/fping-ea.txt" | grep -q 'security.capability' && echo "PASS fping caps in p2: $(grep capability "$EV/fping-ea.txt" | tr -s ' ')" || echo "FAIL fping caps"
for f in /usr/bin/sudo /usr/bin/passwd /usr/lib/dbus-1.0/dbus-daemon-launch-helper /root /tmp /etc/shadow; do dbg "stat $f" "$D2" | awk -v f="$f" '/Mode:/{for(i=1;i<NF;i++) if($i=="Mode:") m=$(i+1)} /User:/{u=$2; g=$4} END{print f, "mode", m, "uid", u, "gid", g}'; done | tee "$EV/owners.txt"
grep -q '^/usr/bin/sudo mode 04755 uid 0 gid 0' "$EV/owners.txt" && grep -q '^/tmp mode 01777' "$EV/owners.txt" && echo "PASS setuid and sticky modes, root owners" || echo "FAIL modes/owners"
dbg 'stat /usr/lib/dbus-1.0/dbus-daemon-launch-helper' "$D2" | grep -q 'Group:  *0' && echo "WARN dbus helper gid 0" || echo "PASS dbus helper group messagebus (not 0)"
free=$(dumpe2fs -h "$T/p2.img" 2>/dev/null | awk -F: '/^Free blocks/{gsub(/ /,"",$2); print $2*4096}')
echo "p2 free $free B ($((free / 1048576)) MiB)"; [ "$free" -gt 67108864 ] && echo "PASS p2 free > 64 MiB" || echo "FAIL p2 free"
p1free=$(dumpe2fs -h "$T/p1.img" 2>/dev/null | awk -F: '/^Free blocks/{gsub(/ /,"",$2); print $2*4096}'); echo "p1 free $p1free B ($((p1free / 1048576)) MiB)"
sha256sum "$IMG" | tee "$EV/img.sha256"
mkdir -p "$OUT"; echo "$(cut -d' ' -f1 "$EV/img.sha256")  $NAME.img" > "$OUT/$NAME.img.sha256"
podman unshare rm -rf "$T"
