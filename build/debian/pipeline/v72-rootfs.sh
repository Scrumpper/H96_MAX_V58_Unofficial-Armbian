#!/bin/bash
# Stage 0: v7.2 rootfs tarball (p2 tree with p1 as /boot) from v7.2 image via debugfs rdump inside podman unshare,
# owners/modes/xattrs from read-only inventory (e2inv.py, base-fix.py). Output $IN/v72-rootfs.tar.zst.
# Released build made this tarball by rdump under fakeroot; its sha (pins file) is not expected from this script.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR/v72; mkdir -p "$W" "$EV"
XZ=$IN/H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz; IMG=$W/v72.img
[ "$(sha256sum < "$XZ" | cut -d' ' -f1)" = "$(pin H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz)" ] || { echo "v7.2 xz sha"; exit 1; }
[ "$(sha256sum < "$IMG" 2>/dev/null | cut -d' ' -f1)" = "$(pin H96-MAX-V58_Unofficial-Armbian_v7.2.img)" ] || xz -dc "$XZ" > "$IMG"
T=$W/v72-tree; [ -e "$T" ] && podman unshare rm -rf "$T"; mkdir -p "$T/boot"
for part in p2:553648128:/ p1:16777216:/boot; do
  IFS=: read -r n off dst <<< "$part"; P="$IMG?offset=$off"
  python3 -I "$H/e2inv.py" "$P" "$EV/inv-$n.tsv" "$EV/xattr-$n.tsv"
  debugfs -R 'ls -p /' "$P" 2>/dev/null | awk -F/ 'NF>=6 && $6!="." && $6!=".." {print $6}' | while read -r e; do echo "rdump \"/$e\" \"$T$dst\""; done > "$W/rdump-$n.cmds"
  podman unshare debugfs -f "$W/rdump-$n.cmds" "$P" > "$EV/rdump-$n.log" 2>&1
  [ "$n" = p1 ] && sed -i 's#^/#/boot/#; s#^/boot/\t#/boot\t#' "$EV/inv-$n.tsv" "$EV/xattr-$n.tsv"
done
cat "$EV/inv-p2.tsv" "$EV/inv-p1.tsv" > "$EV/inv.tsv"; cat "$EV/xattr-p2.tsv" "$EV/xattr-p1.tsv" > "$EV/xattr.tsv"
podman unshare python3 -I "$H/base-fix.py" "$T" "$EV/inv.tsv" "$EV/xattr.tsv" > "$EV/fix.txt"; tail -3 "$EV/fix.txt"
podman unshare tar --numeric-owner --xattrs --xattrs-include='*' --sort=name -C "$T" -cpf - . | zstd -T8 -q -o "$V72" -f
sha256sum "$V72" | tee "$EV/v72-tarball.sha256"
echo "pins file sha (released build): $(pin v72-rootfs.tar.zst)"
