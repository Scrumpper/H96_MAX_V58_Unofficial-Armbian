#!/bin/bash
# Stage 1 base: verify Armbian trixie download again, inventory p1 with debugfs (read only), rdump inside podman
# unshare, owners/modes/xattrs from inventory, tarball trixie-rootfs.tar.zst (sha in inputs.sha256 of this folder).
# Usage: base.sh   (heavy: run under systemd-run scope)
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"
D=$IN; N=Armbian_26.8.3_Rock-5b_trixie_vendor_6.1.115_minimal
XZSHA=$(pin "$N.img.xz")
IMGSHA=bec671427fe710f4acbddb73c6137b8d3cf5d801dcc9fd574c1b5fe29dd3b5f0
EV=$EVR/base; mkdir -p "$W" "$EV"
[ "$(sha256sum < "$D/$N.img.xz" | cut -d' ' -f1)" = "$XZSHA" ] && [ "$(cut -c1-64 "$D/$N.img.xz.sha")" = "$XZSHA" ] || { echo "xz sha"; exit 1; }
gpgv --keyring "$IN/keys/armbian-img.gpg" "$D/$N.img.xz.asc" "$D/$N.img.xz" 2>&1 | grep -q 'Good signature' || { echo "gpg"; exit 1; }
[ "$(sha256sum < "$W/$N.img" 2>/dev/null | cut -d' ' -f1)" = "$IMGSHA" ] || { xz -dc "$D/$N.img.xz" > "$W/$N.img"; [ "$(sha256sum < "$W/$N.img" | cut -d' ' -f1)" = "$IMGSHA" ] || exit 1; }
echo "PASS download xz sha, gpg, img sha"
P="$W/$N.img?offset=16777216"
python3 -I "$H/e2inv.py" "$P" "$EV/inv.tsv" "$EV/xattr.tsv"
T=$W/base-tree
[ -e "$T" ] && podman unshare rm -rf "$T"
mkdir -p "$T"
debugfs -R 'ls -p /' "$P" 2>/dev/null | awk -F/ 'NF>=6 && $6!="." && $6!=".." {print $6}' | while read -r n; do echo "rdump \"/$n\" \"$T\""; done > "$W/rdump.cmds"
podman unshare debugfs -f "$W/rdump.cmds" "$P" > "$EV/rdump.log" 2>&1
{ grep -v "^debugfs" "$EV/rdump.log" || true; } | head -5
podman unshare python3 -I "$H/base-fix.py" "$T" "$EV/inv.tsv" "$EV/xattr.tsv" > "$EV/fix.txt"; tail -3 "$EV/fix.txt"
podman unshare tar --numeric-owner --xattrs --xattrs-include='*' --sort=name --mtime=@1792281600 -C "$T" -cpf - . | zstd -T8 -q -o "$W/trixie-rootfs.tar.zst" -f
sha256sum "$W/trixie-rootfs.tar.zst" | tee "$EV/tarball.sha256"
