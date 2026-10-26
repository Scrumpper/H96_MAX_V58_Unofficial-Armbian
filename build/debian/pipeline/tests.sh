#!/bin/bash
# Laptop tests T5 to T9 on throwaway copy of built rootfs (tests-in/laptop-tests.sh, network). Heavy: systemd-run scope.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR/tests
rm -rf "$EV"; mkdir -p "$EV"
[ "$(sha256sum < "$W/built-rootfs.tar.zst" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$EVR/build/built-tarball.sha256")" ] || { echo "built tarball sha"; exit 1; }
R=$W/rootfs-test; [ -e "$R" ] && podman unshare rm -rf "$R"; mkdir -p "$R"
podman unshare tar --zstd --numeric-owner --xattrs --xattrs-include='*' -xpf "$W/built-rootfs.tar.zst" -C "$R"
rc=0; bash "$H/chroot-run.sh" "$R" "$H/tests-in" laptop-tests.sh "$EV/tests-run.txt" --net || rc=$?
podman unshare sh -c 'cp -a "$1/root/f5-log/tests/." "$2/"' _ "$R" "$EV" || true
podman unshare rm -rf "$R"
cat "$EV/tests-run.txt"; exit "$rc"
