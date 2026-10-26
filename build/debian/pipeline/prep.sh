#!/bin/bash
# Stage 3 prep (laptop): payload from v7.2 rootfs tarball (sha pinned), base tarball into work tree, prep-chroot.sh with
# network, prepped tree packed as prep-rootfs.tar.zst. Heavy: run under systemd-run scope.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR/prep; mkdir -p "$EV"
BSP=debs/armbian-bsp-cli-odroidn2-current_26.8.3_arm64.deb; BSPSHA=$(pin "$BSP")
[ "$(sha256sum < "$V72" | cut -d' ' -f1)" = "$V72SHA" ] || { echo "v7.2 tarball sha"; exit 1; }
[ "$(sha256sum < "$W/trixie-rootfs.tar.zst" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$EVR/base/tarball.sha256")" ] || { echo "base tarball sha"; exit 1; }
PI=$W/prep-in; rm -rf "$PI"; cp -a "$H/prep-in" "$PI"
cp -p "$IN/$BSP" "$PI/bsp.deb"
[ "$(sha256sum < "$PI/bsp.deb" | cut -d' ' -f1)" = "$BSPSHA" ] || { echo "bsp sha"; exit 1; }
rm -rf "$PI/payload"; mkdir -p "$PI/payload"
grep -v '^#' "$H/prep-payload.tsv" | cut -f1 | sed 's#^#.#' > "$W/payload.lst"
tar --zstd -xpf "$V72" -C "$PI/payload" --no-same-owner -T "$W/payload.lst"
(cd "$PI/payload" && find . ! -type d -printf '%y %m %p -> %l\n' | sort) > "$EV/payload-files.txt"
[ "$(wc -l < "$EV/payload-files.txt")" = "$(wc -l < "$W/payload.lst")" ] || { echo "payload count"; exit 1; }
R=$W/rootfs
[ -e "$R" ] && podman unshare rm -rf "$R"
mkdir -p "$R"
podman unshare tar --zstd --numeric-owner --xattrs --xattrs-include='*' -xpf "$W/trixie-rootfs.tar.zst" -C "$R"
rc=0; bash "$H/chroot-run.sh" "$R" "$PI" prep-chroot.sh "$EV/prep-run.txt" --net || rc=$?
podman unshare sh -c 'cp -a "$1/root/f5-log/prep/." "$2/" 2>/dev/null; chown -R 0:0 "$2"' _ "$R" "$EV" || true
podman unshare rm -rf "$R/root/f5-in" "$R/root/f5-log"
tail -30 "$EV/prep-run.txt"
[ "$rc" = 0 ] || exit "$rc"
podman unshare tar --numeric-owner --xattrs --xattrs-include='*' --sort=name -C "$R" -cpf - . | zstd -T8 -q -o "$W/prep-rootfs.tar.zst" -f
sha256sum "$W/prep-rootfs.tar.zst" | tee "$EV/prep-tarball.sha256"
