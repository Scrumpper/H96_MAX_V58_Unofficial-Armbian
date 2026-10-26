#!/bin/bash
# On box as root, from /root/rc-scratch/in: drives image steps in private mount namespace holder unit.
# Usage: box-run.sh check | up | steps | step SCRIPT | down | status
set -uo pipefail
B=/root/rc-scratch; M=$B/mnt; I=$B/in; U=h96-rc-ns
LOGD=$B/log
# transient rule: image partitions share UUIDs with host, keep loops out of by-uuid links and udisks
UR=/run/udev/rules.d/59-h96-rc-loop.rules
pid() { systemctl show -p MainPID --value "$U" 2>/dev/null; }
inns() { local p; p=$(pid); [ -n "$p" ] && [ "$p" != 0 ] || { echo "holder $U not running" >&2; return 1; }; nsenter -t "$p" -m -- "$@"; }
inchroot() {
  inns chroot "$M" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C HOME=/root TERM=dumb /bin/bash "/root/f5-in/$1"
}
STEPS="repo-apply.sh f5-chroot.sh stage-kernel.sh image-brand.sh final-check.sh image-clean.sh"
case "${1:-}" in
  check)
    # inputs and image on box equal laptop pins
    cd "$I" || exit 1
    sha256sum -c --quiet inputs.sha256 && echo "PASS inputs" || { echo "FAIL inputs"; exit 1; }
    sha256sum -c --quiet scripts.sha256 && echo "PASS scripts" || { echo "FAIL scripts"; exit 1; }
    (cd repo && sha256sum -c --quiet index.sha256 && sha256sum -c --quiet add.sha256) && echo "PASS repo stage" || { echo "FAIL repo stage"; exit 1; }
    [ "$(sha256sum < "$B/work.img" | cut -d' ' -f1)" = "$(cut -d' ' -f1 base-img.sha256)" ] && echo "PASS work.img = v7.2 base" || { echo "FAIL work.img"; exit 1; }
    [ -z "$(losetup -a | grep rc-scratch)" ] && echo "PASS no rc loops" || { echo "FAIL loops in use"; exit 1; }
    ;;
  up)
    systemctl is-active -q "$U" && { echo "holder $U already running"; exit 1; }
    mkdir -p "$LOGD" /run/udev/rules.d
    echo 'KERNEL=="loop*", ENV{UDEV_DISABLE_PERSISTENT_STORAGE_RULES_FLAG}="1", ENV{UDISKS_IGNORE}="1"' > "$UR"
    udevadm control --reload || exit 1
    systemd-run --unit="$U" --collect -p Type=exec unshare -m --propagation private sleep infinity || exit 1
    for _ in 1 2 3 4 5; do [ "$(pid)" -gt 0 ] 2>/dev/null && break; sleep 1; done
    inns bash "$I/ns-up.sh" 2>&1 | tee "$LOGD/ns-up.txt"; rc=${PIPESTATUS[0]}
    udevadm settle; ls -l /dev/disk/by-uuid | tee "$LOGD/by-uuid-up.txt"
    grep -q 'loop' "$LOGD/by-uuid-up.txt" && echo "WARN by-uuid link on loop"
    exit "$rc"
    ;;
  step)
    s=${2:?script}; case " $STEPS " in *" $s "*) ;; *) echo "unknown step $s"; exit 2 ;; esac
    inchroot "$s" 2>&1 | tee "$LOGD/${s%.sh}-run.txt"; rc=${PIPESTATUS[0]}; echo "$s rc=$rc"; exit "$rc"
    ;;
  steps)
    # stops at first failure; holder stays up for inspection, then 'down'
    for s in $STEPS; do
      inchroot "$s" 2>&1 | tee "$LOGD/${s%.sh}-run.txt"; rc=${PIPESTATUS[0]}; echo "$s rc=$rc"
      [ "$rc" = 0 ] || { echo "STOP at $s"; exit 1; }
    done
    ;;
  down)
    inns bash "$I/ns-down.sh" 2>&1 | tee "$LOGD/ns-down.txt"; rc=${PIPESTATUS[0]}
    systemctl stop "$U"; rm -f "$UR"; udevadm control --reload; udevadm settle
    ls -l /dev/disk/by-uuid | tee "$LOGD/by-uuid-down.txt"; echo "ns-down rc=$rc"; exit "$rc"
    ;;
  status)
    systemctl status --no-pager "$U" 2>&1 | head -5; losetup -a | grep rc-scratch; inns findmnt -R "$M" 2>/dev/null | head -20
    ;;
  *) sed -n '2,3p' "$0"; exit 2 ;;
esac
