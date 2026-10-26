#!/bin/bash
LOG=/var/log/h96-kde-configure.log
exec > >(tee -a "$LOG") 2>&1
echo "=== H96 KDE -> LightDM/X11 auto-configure ==="; date
# Install LightDM/Xorg/X11 session: KDE's Wayland-first install pulls neither, so LightDM would fail without them.
# Wait for the dpkg lock to free (armbian-config may still be installing) before touching apt; capped at ~15 min.
echo "  waiting for dpkg lock to be released..."
  # apt-get also takes /var/lib/apt/lists/lock, not covered by DPkg::Lock::Timeout; wait on all three.
# h96: wait for installer
echo "  waiting for dpkg lock + armbian-config to finish..."
# desktop notification for logged-in graphical sessions
h96_notify() {
  loginctl list-sessions --no-legend 2>/dev/null | while read -r sid uid user _; do
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    [ -S "/run/user/$uid/bus" ] || continue
    runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.Notify "H96 desktop setup" 0 dialog-information "H96 desktop setup" "$1" "[]" "{}" 0 >/dev/null 2>&1 || true
  done
}
# set by h96-dm-handoff: armbian-config is parked in its display-manager start, waiting for this script
handoff() { [ -e /run/h96-desktop-handoff ]; }
# SDDM unit copy without getty@tty1 conflict, so armbian-config on local console survives the hand-off
[ -e /var/lib/h96-kde-configure-done ] || /usr/sbin/h96-dm-handoff --prepare kde
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
  handoff && running=0
  # SDDM may install after Plasma: keep preparing the hand-off copy while waiting
  [ "$running" = 1 ] && /usr/sbin/h96-dm-handoff --prepare kde
  [ "$locked" = 0 ] && [ "$running" = 0 ] && { h96_wait_ok=1; break; }
  sleep 5
done
[ "$h96_wait_ok" = 1 ] || echo "  WARNING: dpkg/armbian-config wait hit 7200s cap, continuing" >&2
# Respect the KDE tier armbian-config already installed (tier marker below); only fall back to a baseline package set if no marker exists.
# KDE removed while this waited: nothing to configure
[ -x /usr/bin/plasmashell ] || { echo "  plasmashell gone (KDE removed); nothing to do"; exit 0; }
# power-profiles-daemon is masked for h96-power-profiles; its first install would run systemctl preset on the
# masked unit and fail. Empty deb-systemd-helper state: no preset, unit stays disabled.
PPD_DSH=/var/lib/systemd/deb-systemd-helper-enabled/power-profiles-daemon.service.dsh-also
if [ "$(readlink /etc/systemd/system/power-profiles-daemon.service 2>/dev/null)" = /dev/null ] && [ ! -e "$PPD_DSH" ] \
  && ! dpkg-query -W -f='${db:Status-Abbrev}' power-profiles-daemon 2>/dev/null | grep -q '^ii'; then
  mkdir -p "${PPD_DSH%/*}" && : > "$PPD_DSH"
fi
KDE_TIER_MARKER=/etc/armbian/desktop/kde-plasma.tier
if [ -f "$KDE_TIER_MARKER" ]; then
  echo "  armbian-config installed KDE at tier '$(cat "$KDE_TIER_MARKER")' — leaving its packages as chosen, not upgrading to kde-full"
else
  echo "  no armbian-config tier marker found (KDE landed some other way) — installing a known-good baseline package set"
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 -o APT::Install-Recommends=1 \
    kde-plasma-desktop sddm sddm-theme-breeze konsole dolphin ark bluedevil \
    gwenview kscreen network-manager-gnome okular plasma-nm plasma-pa \
    xserver-xorg dbus-x11 dmz-cursor-theme fonts-ubuntu gtk2-engines \
    gtk2-engines-murrine gtk2-engines-pixbuf gvfs-backends lm-sensors pulseaudio \
    pulseaudio-module-bluetooth spice-vdagent xdg-user-dirs kate polkitd pkexec \
    libfido2-1 2>&1 || true
fi
# Install LightDM/Xorg/X11 session and kwin-x11 regardless of tier: the Wayland-first KDE install pulls only kwin-wayland, and X11 needs kwin-x11 for a window manager.
env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 -o APT::Install-Recommends=1 \
  kwin-x11 lightdm lightdm-gtk-greeter \
  xinit x11-xserver-utils plasma-session-x11 2>&1 || true
# Armbian's no-recommends policy skips kde-full's Bluetooth/power-management deps; install bluez/bluedevil/powerdevil explicitly.
env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 --install-recommends \
  bluez bluedevil powerdevil libmtp-runtime 2>&1 || true
# KDE install pulls plymouth back after first-boot cleanup removed it: purge again when nothing else goes with it
if dpkg -l plymouth 2>/dev/null | grep -q '^ii'; then
  extra=$(apt-get -s purge plymouth armbian-plymouth-theme 2>/dev/null | awk '/^Purg /{print $2}' \
          | grep -v -x -e plymouth -e 'plymouth-.*' -e armbian-plymouth-theme)
  if [ -z "$extra" ]; then
    env DEBIAN_FRONTEND=noninteractive apt-get purge -y --no-auto-remove -o DPkg::Lock::Timeout=600 \
      plymouth armbian-plymouth-theme 2>&1 | tail -1 || true
  else
    echo "  plymouth kept: purge would also remove $(echo $extra)"
  fi
fi
# GPU GUI monitor, best-effort: mission-center is not in the Ubuntu archive; fall back silently to terminal nvtop.
if env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 mission-center 2>/dev/null; then
  echo "  mission-center installed (GUI GPU monitor)"
else
  echo "  mission-center not in apt — GPU GUI monitor available via flathub; nvtop installed for terminal GPU monitoring"
fi
# Keep printing socket-activated only, so cupsd is not resident at boot.
systemctl disable cups.service 2>/dev/null || true
systemctl enable cups.socket 2>/dev/null || true
# Keep SDDM (pulled in by KDE Recommends) from grabbing the seat
if handoff; then
  # SDDM start job is running h96-dm-handoff: stop would cancel it, mask would drop its drop-in (h96-dm-handoff masks later)
  systemctl disable sddm.service 2>/dev/null || true
else
  systemctl disable --now sddm.service 2>/dev/null || true
  /usr/sbin/h96-dm-handoff --restore kde
  systemctl mask sddm.service 2>/dev/null || true
fi
# Re-assert display-manager as LightDM: masking sddm leaves the symlink dangling at a masked unit, so remove it and let enabling lightdm recreate it.
rm -f /etc/systemd/system/display-manager.service
systemctl enable lightdm.service 2>/dev/null || true
# LightDM is the display manager; override anything KDE/SDDM set.
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
echo "set shared/default-x-display-manager lightdm" | debconf-communicate 2>/dev/null || true
# Steer to the Plasma X11 session and the installed greeter; 99- prefix must sort after armbian-config's own 10-/11- lightdm configs to win.
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/99-h96-kde.conf <<'CONF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=plasmax11
CONF
# armbian-config names xfce in 11-armbian.conf; point it at Plasma X11 unless Xfce is installed
[ -e /usr/share/xsessions/xfce.desktop ] || \
  sed -i 's/^user-session=xfce$/user-session=plasmax11/' /etc/lightdm/lightdm.conf.d/*.conf 2>/dev/null || true
# Enable KWin GLES compositing on Panthor/Panfrost; QT_XCB_GL_INTEGRATION=xcb_egl and KWIN_COMPOSE=O2ES are required for it to initialise.
mkdir -p /etc/xdg
cat > /etc/xdg/kwinrc <<'CONF'
[Compositing]
Enabled=true
Backend=OpenGL
GLCore=false
OpenGLIsUnsafe=false
CONF
for kv in QT_XCB_GL_INTEGRATION=xcb_egl KWIN_COMPOSE=O2ES; do
  k=${kv%%=*}
  # GPU driver off (panthor-revert.sh): forced GLES makes KWin exit on llvmpipe; marker lets --undo add it back
  if [ "$k" = KWIN_COMPOSE ] && [ -e /etc/modprobe.d/h96-gpu-off.conf ]; then
    grep -q "^$k=" /etc/environment 2>/dev/null || { mkdir -p /var/lib/h96; touch /var/lib/h96/gpu-off-kwin-compose; }
    continue
  fi
  grep -q "^$k=" /etc/environment 2>/dev/null || echo "$kv" >> /etc/environment
done
# Plasma X11 launches kwin_x11 itself; remove the stale kwin-x11-wm.desktop autostart hack.
rm -f /etc/xdg/autostart/kwin-x11-wm.desktop
# Unmask and enable the bluetooth.service (base ships a stub) so bluedevil pairing works.
systemctl unmask bluetooth.service 2>/dev/null || true
systemctl enable --now bluetooth.service 2>/dev/null || true
# Mask the stock power-profiles-daemon so the h96-power-profiles shim owns the D-Bus name (stock ppd can't enumerate profiles on RK3588).
systemctl mask power-profiles-daemon.service 2>/dev/null || true
# Force the installed GTK greeter; the desktop install sets slick-greeter, which is not installed and fails LightDM.
mkdir -p /etc/lightdm/lightdm.conf.d
# 60- prefix (not 05-): lightdm.conf.d sorts lexically and must outrank the desktop install's 10-slick-greeter.conf.
cat > /etc/lightdm/lightdm.conf.d/60-h96-greeter.conf <<'CONF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
CONF
rm -f /etc/lightdm/lightdm.conf.d/05-h96-greeter.conf
# Install the remaining no-recommends casualties: polkit agent, plasma-nm, print-manager, bluedevil, plasma-pa, PipeWire session manager and Bluetooth codec plugin.
/usr/lib/h96/h96-desktop-fixup.sh --kde || true
# LightDM base config now, not after armbian-config exits; autologin for the desktop user
[ -e /var/lib/h96-lightdm-configure-done ] || H96_NO_WAIT=1 H96_NO_START=1 /usr/lib/h96/h96-lightdm-configure.sh || true
[ -x /usr/sbin/h96-autologin-setup ] && /usr/sbin/h96-autologin-setup || true
# Enable LightDM and go graphical
systemctl set-default graphical.target
systemctl daemon-reload
systemctl reset-failed lightdm.service 2>/dev/null || true
# Never restart the display manager under a live session: the triggering .path unit re-fires during install and could kill an active desktop.
if handoff; then
  # armbian-config restarts display-manager (now LightDM) next; fallback start if it does not
  echo "  hand-off: armbian-config starts LightDM"
  systemd-run --quiet --on-active=180 --unit=h96-lightdm-ensure /bin/sh -c 'systemctl is-active -q lightdm || systemctl start lightdm' 2>/dev/null || true
elif loginctl list-sessions --no-legend 2>/dev/null | awk '$2 >= 1000 {f=1} END {exit !f}'; then
  echo "  a user session is active — starting (not restarting) lightdm so the session survives"
  systemctl start lightdm.service 2>/dev/null || true
else
  systemctl restart lightdm.service 2>/dev/null || true
fi
if handoff; then
  echo "  lightdm enabled: $(systemctl is-enabled lightdm 2>/dev/null) (armbian-config starts it next); sddm: $(systemctl is-enabled sddm 2>/dev/null)"
else
  echo "  display-manager active: $(systemctl is-active lightdm) (lightdm); sddm: $(systemctl is-enabled sddm 2>/dev/null)"
fi
# Mark done only if LightDM installed and is active; otherwise retry next boot.
if dpkg -l lightdm 2>/dev/null | grep -q '^ii' && { systemctl is-active --quiet lightdm.service || { handoff && systemctl is-enabled --quiet lightdm.service; }; }; then
  touch /var/lib/h96-kde-configure-done
  h96_notify "H96 desktop setup finished."
  # Clear the .path unit's failed state: repeated triggers during install can hit systemd's rate limit even though the service succeeded.
  systemctl reset-failed h96-kde-configure.path h96-kde-configure.service 2>/dev/null || true
  echo "=== KDE -> LightDM configure done (lightdm installed + active) ==="; date
else
  echo "!!! LightDM not installed/active (dpkg lock held or apt failed?) — NOT setting done flag; will retry on next boot"; date
fi
