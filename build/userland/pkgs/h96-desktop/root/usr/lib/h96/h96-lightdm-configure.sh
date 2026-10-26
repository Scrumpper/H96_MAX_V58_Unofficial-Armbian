#!/bin/bash
LOG=/var/log/h96-lightdm-configure.log
exec > >(tee -a "$LOG") 2>&1
[ -e /var/lib/h96-lightdm-configure-done ] && { echo "h96-lightdm-configure: already done"; exit 0; }
echo "=== H96 LightDM configure $(sed -n 's/^H96_RELEASE=//p' /etc/h96-release 2>/dev/null) ==="
date

# Xorg display config: modesetting + glamor defaults, screen blanking off
mkdir -p /etc/X11/xorg.conf.d/
cat > /etc/X11/xorg.conf.d/20-h96-display.conf << 'XORGEOF'
# modesetting driver on the Panthor/Panfrost GPU, hardware defaults; ShadowFB/PageFlip=false were llvmpipe-only workarounds that force CPU copies and ban vsynced flips on GPU, so dropped.
Section "Device"
    Identifier  "H96-GPU"
    Driver      "modesetting"
EndSection

Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
XORGEOF
echo "  Xorg display config written"

# seat keys in a drop-in: package conffile lightdm.conf stays untouched
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-h96-seat.conf << 'LDMEOF'
[Seat:*]
minimum-vt=1
xserver-command=X -nolisten tcp
LDMEOF
echo "  lightdm.conf.d/50-h96-seat.conf written"
# earlier H96 releases replaced lightdm.conf with these three lines: put package file back
if [ -f /etc/lightdm/lightdm.conf.dpkg-dist ] && [ "$(cat /etc/lightdm/lightdm.conf 2>/dev/null)" = "$(printf '[Seat:*]\nminimum-vt=1\nxserver-command=X -nolisten tcp')" ]; then
  mv -f /etc/lightdm/lightdm.conf.dpkg-dist /etc/lightdm/lightdm.conf && echo "  package lightdm.conf restored"
fi

# Add lightdm to video + render groups
usermod -aG video,render lightdm 2>/dev/null || true

# Enable and start lightdm
# h96: wait for installer (skipped when called in-line by h96-kde-configure)
if [ -z "${H96_NO_WAIT:-}" ]; then
echo "  waiting for dpkg lock + armbian-config to finish..."
h96_wait_ok=0
for i in $(seq 1 1440); do
  locked=0
  # lock check: fuser, else lsof, else pgrep apt/dpkg
  if command -v fuser >/dev/null 2>&1; then
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 && locked=1
  elif command -v lsof >/dev/null 2>&1; then
    lsof /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 && locked=1
  else
    pgrep -x 'apt-get|apt|dpkg' >/dev/null 2>&1 && locked=1
  fi
  # armbian-config check: comm name, or full cmdline (it is a bash script)
  running=0
  pgrep -x armbian-config >/dev/null 2>&1 && running=1
  pgrep -f '/armbian-config( |$)' >/dev/null 2>&1 && running=1
  [ -e /run/h96-desktop-handoff ] && running=0
  [ "$locked" = 0 ] && [ "$running" = 0 ] && { h96_wait_ok=1; break; }
  sleep 5
done
[ "$h96_wait_ok" = 1 ] || echo "  WARNING: dpkg/armbian-config wait hit 7200s cap, continuing" >&2
# h96: wait for desktop hooks
for i in $(seq 1 1440); do
  pgrep -f 'h96-kde-configure\.sh|h96-desktop-fixup\.sh' >/dev/null 2>&1 || break
  sleep 5
done
fi
[ -e /var/lib/h96-lightdm-configure-done ] && { echo "h96-lightdm-configure: done meanwhile"; exit 0; }
systemctl enable lightdm.service 2>/dev/null || true
[ -n "${H96_NO_START:-}" ] || systemctl start lightdm.service 2>/dev/null || true

echo "=== H96 LightDM configure done ==="
date
touch /var/lib/h96-lightdm-configure-done
systemctl disable h96-lightdm-configure.service 2>/dev/null || true
