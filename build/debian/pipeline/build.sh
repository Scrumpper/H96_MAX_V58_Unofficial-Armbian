#!/bin/bash
# Stage 6 build (laptop, rootless): prepped trixie rootfs + H96 p1 tree from v7.2 rootfs tarball in /boot, fstab and
# armbianEnv rootdev for new UUIDs, six chroot steps (repo-apply, f5-chroot, stage-kernel, image-brand, final-check,
# image-clean) from stage/, built tree packed as built-rootfs.tar.zst. Heavy: systemd-run scope.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"
EV=$EVR/build; ST=$W/stage
. "$H/uuids.env"
[ "$(sha256sum < "$V72" | cut -d' ' -f1)" = "$V72SHA" ] || { echo "v7.2 tarball sha"; exit 1; }
[ "$(sha256sum < "$W/prep-rootfs.tar.zst" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$EVR/prep/prep-tarball.sha256")" ] || { echo "prep tarball sha"; exit 1; }
(cd "$ST" && sha256sum -c --quiet inputs.sha256) || { echo "stage inputs differ from pins (run dryrun)"; exit 1; }
[ -f "$ST/DRYRUN-OK" ] && sha256sum -c --status "$ST/DRYRUN-OK" || { echo "stage not from a passing dryrun"; exit 1; }
rm -rf "$EV"; mkdir -p "$EV"
R=$W/rootfs-build
[ -e "$R" ] && podman unshare rm -rf "$R"
mkdir -p "$R"
podman unshare tar --zstd --numeric-owner --xattrs --xattrs-include='*' -xpf "$W/prep-rootfs.tar.zst" -C "$R"
# /boot: H96 p1 tree of v7.2 image (boot.cmd, boot.scr, armbianEnv, dtb tree with overlays, overlay-user, v7.2 kernel
# files removed by stage-kernel.sh); prep left Armbian files there (BSP postinst), all replaced
podman unshare sh -c 'rm -rf "$1"/boot/* "$1"/boot/.[!.]* 2>/dev/null; tar --zstd -xpf "$2" -C "$1" --numeric-owner ./boot' _ "$R" "$V72"
podman unshare sh -c '
  R="$1"; P1="$2"; P2="$3"
  sed -i "s/^rootdev=UUID=.*/rootdev=UUID=$P2/" "$R/boot/armbianEnv.txt"
  printf "UUID=%s  /      ext4  defaults,noatime,nodiratime,commit=30,errors=remount-ro  0 1\nUUID=%s  /boot  ext4  defaults,noatime,errors=remount-ro  0 2\ntmpfs           /tmp     tmpfs    defaults,nosuid                                             0 0\n" "$P2" "$P1" > "$R/etc/fstab"
' _ "$R" "$P1_UUID" "$P2_UUID"
podman unshare cat "$R/etc/fstab" > "$EV/fstab"; podman unshare cat "$R/boot/armbianEnv.txt" > "$EV/armbianEnv.txt"
rc=0
for s in repo-apply.sh f5-chroot.sh stage-kernel.sh image-brand.sh final-check.sh image-clean.sh; do
  bash "$H/chroot-run.sh" "$R" "$ST" "$s" "$EV/${s%.sh}-run.txt" || rc=$?
  mkdir -p "$EV/f5-log"; podman unshare sh -c 'cp -a "$1/root/f5-log/." "$2/f5-log/"' _ "$R" "$EV" || true
  echo "$s rc=$rc ($(grep -c '^FAIL' "$EV/${s%.sh}-run.txt") FAIL lines)"
  [ "$rc" = 0 ] || break
done
podman unshare rm -rf "$R/root/f5-in" "$R/root/f5-log"
[ "$rc" = 0 ] || { echo "build rc=$rc"; exit "$rc"; }
podman unshare tar --numeric-owner --xattrs --xattrs-include='*' --sort=name -C "$R" -cpf - . | zstd -T8 -q -o "$W/built-rootfs.tar.zst" -f
sha256sum "$W/built-rootfs.tar.zst" | tee "$EV/built-tarball.sha256"
echo "build rc=0"
