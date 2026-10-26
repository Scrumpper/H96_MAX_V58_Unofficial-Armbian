#!/bin/bash
LOG=/var/log/h96-gnome-configure.log
exec > >(tee -a "$LOG") 2>&1
echo "=== H96 GNOME auto-configure $(sed -n 's/^H96_RELEASE=//p' /etc/h96-release 2>/dev/null) ==="
date

# Add gdm user to video/render so Mali kernel module is accessible
usermod -aG video,render gdm 2>/dev/null && echo "  gdm -> video,render" || true

# GDM: Wayland enabled, no auto-login; login/logout works because the GPU setup
# script unsets LD_LIBRARY_PATH in the gnome-shell user service, keeping Mali's
# broken libgbm out of the compositor.
cat > /etc/gdm3/custom.conf << 'GDMCONF'
[daemon]
WaylandEnable=true
AutomaticLoginEnable=false

[security]

[xdmcp]

[chooser]

[debug]
GDMCONF
echo "  GDM: Wayland=true, no auto-login"

# Set graphical boot target
systemctl set-default graphical.target

# Finish GDM setup: postinst is sometimes incomplete after a bulk armbian-config install; dpkg-reconfigure re-runs generate-config.
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure gdm3 2>/dev/null || true

# Reload and restart GDM so it picks up new group membership
systemctl daemon-reload
systemctl enable gdm.service 2>/dev/null || true
systemctl reset-failed gdm.service 2>/dev/null || true
# GDM unit copy without getty@tty1 conflict, so armbian-config on local console survives the hand-off
[ -e /var/lib/h96-gnome-configure-done ] || /usr/sbin/h96-dm-handoff --prepare gnome
# h96: wait for installer
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
if [ -e /run/h96-desktop-handoff ]; then
  echo "  hand-off: GDM starts when this setup returns"
elif loginctl list-sessions --no-legend 2>/dev/null | awk '$2 >= 1000 {f=1} END {exit !f}'; then
  systemctl start gdm.service 2>/dev/null || true
else
  systemctl restart gdm.service 2>/dev/null || systemctl start gdm.service 2>/dev/null || true
fi

# Parity with the KDE hook, which the GNOME path missed.
# (a) Unmask/enable bluetooth.service (base ships it masked); GNOME never did, leaving its Bluetooth toggle dead.
systemctl unmask bluetooth.service 2>/dev/null || true
systemctl enable --now bluetooth.service 2>/dev/null || true
# (b) Keep printing socket-activated only, so cupsd is not resident at boot.
systemctl disable cups.service 2>/dev/null || true
systemctl enable cups.socket 2>/dev/null || true
# GPU GUI monitor, best-effort: mission-center is not in the Ubuntu archive; fall back silently to terminal nvtop.
if env DEBIAN_FRONTEND=noninteractive apt-get install -y mission-center 2>/dev/null; then
  echo "  mission-center installed (GUI GPU monitor)"
else
  echo "  mission-center not in apt — GPU GUI monitor available via flathub; nvtop installed for terminal GPU monitoring"
fi

# Install the remaining no-recommends casualties: GNOME control-center modules, PipeWire session manager, Bluetooth codec plugin (GNOME's polkit agent ships inside gnome-shell).
/usr/lib/h96/h96-desktop-fixup.sh --gnome || true

# GNOME removed while this waited: nothing to mark
[ -x /usr/bin/gnome-shell ] || { echo "  gnome-shell gone (GNOME removed)"; exit 0; }
touch /var/lib/h96-gnome-configure-done
echo "=== GNOME configure complete ==="
date
