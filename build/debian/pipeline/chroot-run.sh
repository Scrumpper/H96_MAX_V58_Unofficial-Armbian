#!/bin/bash
# Run one script inside an arm64 rootfs tree: podman unshare (full subuid map), private mount+pid namespace,
# proc and host /dev bound, qemu binfmt. Host / and /boot never written (chroot target only).
# Usage: chroot-run.sh ROOTFS IN_DIR SCRIPT LOGFILE [--net]
#   IN_DIR is copied to ROOTFS/root/f5-in (scripts and inputs), logs land in ROOTFS/root/f5-log.
#   --net: host resolver config in place of ROOTFS/etc/resolv.conf for the run (prep, repo download), restored after.
set -euo pipefail
R="$1"; IN="$2"; S="$3"; LOG="$4"; NET="${5:-}"
case "$(realpath -m "$R")" in /|/boot|/boot/*) echo "refuse $R" >&2; exit 2 ;; esac
[ -x "$R/bin/bash" ] || [ -L "$R/bin" ] || { echo "no rootfs at $R" >&2; exit 2; }
podman unshare sh -c 'rm -rf "$1/root/f5-in" && mkdir -p "$1/root/f5-in" "$1/root/f5-log" && cp -a "$2"/. "$1/root/f5-in/"' _ "$R" "$IN"
# shellcheck disable=SC2016
podman unshare unshare -m -p -f --propagation private sh -c '
  R="$1"; S="$2"; NET="$3"
  mount -t proc proc "$R/proc"
  mount --rbind /dev "$R/dev"
  if [ "$NET" = --net ]; then
    [ -e "$R/etc/resolv.conf.h96-run" ] || [ -L "$R/etc/resolv.conf.h96-run" ] || mv "$R/etc/resolv.conf" "$R/etc/resolv.conf.h96-run" 2>/dev/null || true
    grep -v "^#" /etc/resolv.conf > "$R/etc/resolv.conf"; [ -s "$R/etc/resolv.conf" ] || echo "nameserver 1.1.1.1" > "$R/etc/resolv.conf"
  fi
  rc=0
  chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C HOME=/root TERM=dumb /bin/bash "/root/f5-in/$S" || rc=$?
  if [ "$NET" = --net ]; then rm -f "$R/etc/resolv.conf"; mv "$R/etc/resolv.conf.h96-run" "$R/etc/resolv.conf" 2>/dev/null || true; fi
  exit $rc
' _ "$R" "$S" "$NET" > "$LOG" 2>&1 && rc=0 || rc=$?
echo "$S rc=$rc" >> "$LOG"
exit "$rc"
