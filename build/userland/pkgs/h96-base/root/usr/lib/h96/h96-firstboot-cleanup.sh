#!/bin/bash
# first boot only (run by h96-firstboot-cleanup.service); takes no options
case "${1:-}" in
  -h|--help) echo "h96-firstboot-cleanup.sh: one-time first-boot package cleanup, run by its service; takes no options"; exit 0 ;;
esac
[ -e /var/lib/h96-firstboot-cleanup-done ] && { echo "h96-firstboot-cleanup: already done, not running again"; exit 0; }
[ "$(id -u)" = 0 ] || { echo "h96-firstboot-cleanup: must run as root" >&2; exit 1; }
LOG=/var/log/h96-firstboot-cleanup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== H96 firstboot-cleanup $(sed -n 's/^H96_RELEASE=//p' /etc/h96-release 2>/dev/null) ==="
date

export DEBIAN_FRONTEND=noninteractive

echo "[1/3] Installing missing runtime deps (offline)..."
dpkg -i /opt/h96-pkgs/libwayland-server0*.deb 2>/dev/null || \
    apt-get install -y --no-install-recommends libwayland-server0 2>/dev/null || true
ldconfig 2>/dev/null || true

echo "[2/3] Removing unneeded packages..."
# purge cascades into desktop packages, so only on a console-only system; no autoremove: it purged
# runtime libs that h96-video-setup and h96-gaming-setup install against (no ordering between units)
if [ -x /usr/bin/plasmashell ] || [ -x /usr/bin/gnome-shell ] || [ -x /usr/bin/startxfce4 ]; then
  echo "  desktop installed: package removal skipped"
else
  # purge a package only when nothing else goes with it (libasan8 took gcc, build-essential, dkms)
  for p in plymouth unicode-data iso-codes libasan8; do
    dpkg -s "$p" >/dev/null 2>&1 || continue
    extra=$(apt-get -s remove --purge "$p" 2>/dev/null | awk '/^Purg /{print $2}' \
      | grep -v -x -e "$p" -e 'plymouth-.*' -e 'armbian-plymouth-theme')
    if [ -n "$extra" ]; then
      echo "  $p kept, needed by: $(echo $extra)"
    else
      apt-get remove --purge -y --no-auto-remove -o DPkg::Lock::Timeout=600 "$p" 2>/dev/null || true
    fi
  done
fi

echo "[3/3] Done."
date
touch /var/lib/h96-firstboot-cleanup-done
systemctl disable h96-firstboot-cleanup.service 2>/dev/null || true
# disable above is a no-op; unit is pulled by a multi-user.target drop-in that resolves
# network-online.target before the done-flag condition, remove it here to drop NM-wait-online
rm -f /etc/systemd/system/multi-user.target.d/10-h96-firstboot.conf
