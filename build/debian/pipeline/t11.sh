#!/bin/bash
# T11 driver: throwaway copy of built rootfs, t11-in/t11-firstlogin.sh, no network. Heavy: systemd-run scope.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR/t11
rm -rf "$EV"; mkdir -p "$EV"
R=$W/rootfs-t11; [ -e "$R" ] && podman unshare rm -rf "$R"; mkdir -p "$R"
podman unshare tar --zstd --numeric-owner --xattrs --xattrs-include='*' -xpf "$W/built-rootfs.tar.zst" -C "$R"
rc=0; bash "$H/chroot-run.sh" "$R" "$H/t11-in" t11-firstlogin.sh "$EV/t11-run.txt" || rc=$?
podman unshare sh -c 'cp -a "$1/root/f5-log/t11/." "$2/"' _ "$R" "$EV" || true
podman unshare rm -rf "$R"
grep -v 'T11-.*-pass' "$EV/t11-run.txt"; exit "$rc"
