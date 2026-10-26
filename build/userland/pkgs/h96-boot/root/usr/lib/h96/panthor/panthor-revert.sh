#!/bin/bash
# panthor-revert.sh: GPU driver off. Panthor DTB and kernel stay; the Panthor module is blocked, so the desktop
# runs on software GL (llvmpipe). Waydroid "gpu" profile and Steam ARM GPU routes need Panthor.
# Usage: panthor-revert.sh [--undo]; run as root, then reboot.
set -u
B=/boot
ENV=$B/armbianEnv.txt
OFF=/etc/modprobe.d/h96-gpu-off.conf
LOAD=/etc/modules-load.d/panthor.conf
TOKEN=modprobe.blacklist=panthor
KMARK=/var/lib/h96/gpu-off-kwin-compose
log(){ printf '[panthor-revert] %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
case "${1:-}" in
  "") undo=0;;
  --undo) undo=1;;
  -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "usage: panthor-revert.sh [--undo]" >&2; exit 2;;
esac

# extraargs token, armbianEnv lock + tmp + fsync + rename + fsync of /boot
env_edit(){ # add|del
  (
    flock 9
    tmp=$(mktemp "$B/.armbianEnv.XXXXXX") || exit 1
    if [ "$1" = add ]; then
      awk -v t="$TOKEN" '/^extraargs=/ && index(" " substr($0, 11) " ", " " t " ") == 0 { $0 = $0 " " t } { print }' "$ENV" > "$tmp"
    else
      awk -v t="$TOKEN" '/^extraargs=/ { n = split(substr($0, 11), a, " "); s = ""
           for (i = 1; i <= n; i++) if (a[i] != t) s = s (s == "" ? "" : " ") a[i]; $0 = "extraargs=" s } { print }' "$ENV" > "$tmp"
    fi
    grep -q '^extraargs=' "$tmp" || { rm -f "$tmp"; exit 1; }
    chmod 0644 "$tmp"; sync "$tmp"; mv -f "$tmp" "$ENV"; sync "$B"
  ) 9>/run/lock/h96-armbianenv.lock
}

if [ "$undo" = 0 ]; then
  env_edit add || { echo "armbianEnv.txt not changed" >&2; exit 1; }
  printf '# panthor-revert.sh: GPU driver off (undo: panthor-revert.sh --undo)\ninstall panthor /bin/false\nblacklist panthor\n' > "$OFF"
  rm -f "$LOAD"
  # forced GLES compositing makes KWin exit on llvmpipe (no window manager); KWin runs uncomposited without it
  if [ -e /etc/environment ] && grep -q '^KWIN_COMPOSE=O2ES$' /etc/environment; then
    sed -i '/^KWIN_COMPOSE=O2ES$/d' /etc/environment; mkdir -p "${KMARK%/*}"; touch "$KMARK"
  fi
  log "Panthor blocked ($OFF, $TOKEN in extraargs); reboot for software GL"
else
  env_edit del || { echo "armbianEnv.txt not changed" >&2; exit 1; }
  rm -f "$OFF"
  echo panthor > "$LOAD"
  if [ -e "$KMARK" ]; then
    grep -q '^KWIN_COMPOSE=' /etc/environment 2>/dev/null || echo KWIN_COMPOSE=O2ES >> /etc/environment
    rm -f "$KMARK"
  fi
  log "Panthor allowed again; reboot for the GPU driver"
fi
