#!/bin/bash
# h96-desktop-fixup.sh: H96 Max V58 desktop completeness fixup
#
# Armbian ships APT::Install-Recommends "0" in 71-armbian-no-recommends; desktop
# metapackages (kde-full, GNOME set, pipewire) put most functionality in Recommends,
# not Depends, so installing a desktop here produces a skeleton: no network applet,
# printer module, Bluetooth module, polkit agent, or PipeWire session manager
#
# installs the pieces Recommends would have pulled, explicitly and by name, and
# reports each failure instead of hiding it behind || true
#
# safe to run by hand: sudo h96-desktop-fixup.sh. idempotent, called automatically
# by h96-kde-configure / h96-gnome-configure
set -u
LOG=/var/log/h96-desktop-fixup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== h96-desktop-fixup $(date -Is) (arg: ${1:-auto}) ==="

[ "$(id -u)" = 0 ] || { echo "!!! must run as root"; exit 1; }

MODE="${1:-auto}"
if [ "$MODE" = "auto" ]; then
  if   [ -x /usr/bin/plasmashell ]; then MODE=--kde
  elif [ -x /usr/bin/gnome-shell ]; then MODE=--gnome
  else MODE=--none; fi
  echo "  auto-detected desktop: $MODE"
fi

# write stdin to $1 only when content differs (no mtime churn); rc 0 = written
put_if_changed() {
  local t="$1.h96new"
  cat > "$t" || { rm -f "$t"; return 1; }
  if cmp -s "$t" "$1"; then rm -f "$t"; return 1; fi
  mv -f "$t" "$1"
}

# --- apt helpers ---
# caller may be a .path unit that fires mid-install while armbian-config holds
# the dpkg lock; wait for it to free rather than failing
wait_dpkg() {
  echo "  waiting for dpkg lock..."
  for _ in $(seq 1 180); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || return 0
    sleep 5
  done
  echo "  !!! dpkg lock still held after 15 min — continuing anyway"
}

# install with Recommends forced on for this call only, system-wide policy untouched
apt_install() {
  # triggered by a .path unit that fires while armbian-config is still installing,
  # so apt calls collide with its dpkg lock. wait_dpkg() above only checks the lock
  # is free and then races for it; DPkg::Lock::Timeout makes apt itself wait, which
  # is the actual fix
  env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o DPkg::Lock::Timeout=600 \
      -o APT::Install-Recommends=1 -o APT::Install-Suggests=0 "$@"
}

MISSING=""
# install each package on its own so one unavailable name cannot abort the rest
# (names drift between Ubuntu releases); record failures and keep apt's explanation
# so they stay visible, not swallowed
install_each() {
  local p out
  for p in "$@"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed$"; then
      echo "  [have] $p"; continue
    fi
    if out="$(apt_install "$p" 2>&1)"; then
      echo "  [ ok ] $p"
    else
      echo "  [FAIL] $p"
      printf '%s\n' "$out" | grep -iE "^E:|Unable to locate|has no installation candidate|broken|held" | sed 's/^/         /'
      MISSING="$MISSING $p"
    fi
  done
}

wait_dpkg
apt-get update >/dev/null 2>&1 || echo "  (apt-get update failed — using cached lists)"

# --- 1. audio ---
# pipewire Recommends pipewire-pulse, wireplumber, libspa-0.2-bluetooth. without
# wireplumber there is no session manager, so HDMI stays silent even though
# aplay -l shows the card; without libspa-0.2-bluetooth pairing succeeds but
# connecting fails (br-connection-unknown)
echo "[1] audio stack (PipeWire + WirePlumber + Bluetooth codecs)"
# Hand-installed PulseAudio takes the audio session over from PipeWire and makes
# packaged HDMI rule a no-op, say so rather than silently fighting it
if dpkg-query -W -f='${Status}' pulseaudio 2>/dev/null | grep -q "^install ok installed$"; then
  echo "  NOTE: pulseaudio is installed. It conflicts with pipewire-pulse, and while it"
  echo "        is present packaged HDMI rule (h96-audio) does nothing. Installing"
  echo "        pipewire-pulse below will replace it. To keep PulseAudio instead, stop"
  echo "        here and configure HDMI with pavucontrol."
fi
install_each pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth
# libspa-0.2-bluetooth alone does not pull codecs on every release
  install_each libldacbt-abr2 libldacbt-enc2 libfdk-aac2 libfreeaptx0

  # WiFi tray icon: wlan0 is not NetworkManager-managed (see
  # /etc/NetworkManager/conf.d/99-h96-wlan0-unmanaged.conf). wpagui talks straight
  # to h96-wpa-supplicant-wlan0.service's control socket, autostarted as a tray icon
  install_each wpagui
  if command -v wpa_gui >/dev/null 2>&1; then
    mkdir -p /etc/xdg/autostart
    put_if_changed /etc/xdg/autostart/h96-wpa-gui.desktop <<'DESK'
[Desktop Entry]
Type=Application
Version=1.0
Name=WiFi (H96)
GenericName=WiFi connection manager
Comment=Scan and connect to WiFi networks on this box
Exec=env -u SESSION_MANAGER wpa_gui -t
Icon=network-wireless
Terminal=false
Categories=Qt;Network;
X-KDE-autostart-phase=2
DESK
    put_if_changed /usr/share/applications/wpa_gui.desktop <<'DESK'
[Desktop Entry]
Version=1.0
Name=WiFi (H96)
GenericName=WiFi connection manager
Comment=Scan and connect to WiFi networks on this box
Exec=wpa_gui
Icon=network-wireless
Terminal=false
Type=Application
Categories=Qt;Network;
Keywords=wifi;wireless;network;wpa;
DESK
    for u in /home/*; do
      [ -d "$u" ] || continue
      un=$(basename "$u")
      id "$un" >/dev/null 2>&1 || continue
      usermod -aG netdev "$un" 2>/dev/null || true
    done
    echo "  wpagui installed + autostarted as a tray icon"
  fi

# --- 2. bluetooth ---
echo "[2] bluetooth"
install_each bluez bluez-tools

echo "[2b] GPU monitor (Panthor-aware)"
install_each nvtop
systemctl unmask bluetooth.service 2>/dev/null || true
systemctl enable --now bluetooth.service 2>/dev/null || true

# --- 3. desktop bits ---
case "$MODE" in
  --kde)
    echo "[3] KDE modules that Recommends would have pulled"
    # plasma-nm       network applet + network module
    # print-manager   printer module
    # bluedevil       bluetooth module + applet
    # plasma-pa       audio applet / volume OSD
    # polkit-kde-agent-1  authentication dialog; without it every polkit prompt fails
    # kio-extras      filenamesearch KIO worker for Dolphin search
    install_each plasma-nm print-manager bluedevil plasma-pa \
                 polkit-kde-agent-1 powerdevil plasma-discover \
                 kde-config-gtk-style kinfocenter kio-extras
    ;;
  --gnome)
    echo "[3] GNOME modules that Recommends would have pulled"
    # GNOME polkit agent is built into gnome-shell, no agent package needed
    install_each gnome-control-center gnome-bluetooth-sendto \
                 cups-pk-helper system-config-printer gnome-software \
                 gnome-software-plugin-deb network-manager-gnome
    ;;
  *)
    echo "[3] no desktop detected — skipping desktop-specific packages"
    ;;
esac

# --- 4. polkit ---
# Ubuntu's 49-ubuntu-admin.rules returns unix-group:sudo and unix-group:admin, but
# Armbian has no admin group, so polkitd logs an invalid-identity warning on every
# admin check (harmless, polkitd keeps unix-group:sudo); declare the admin identity
# explicitly so behavior is unambiguous and the log is clean
echo "[4] polkit admin identity"
install -d -m 0750 -o root -g polkitd /etc/polkit-1/rules.d 2>/dev/null || mkdir -p /etc/polkit-1/rules.d
put_if_changed /etc/polkit-1/rules.d/10-h96-admin.rules <<'POLKIT'
/* H96 Max V58: Armbian has no `admin` group, but Ubuntu's
   /usr/share/polkit-1/rules.d/49-ubuntu-admin.rules returns one, leaving
   polkitd to log "Identity `unix-group:admin' is not valid, ignoring" on every
   administrative check. Declare the sudo group as the sole administrator
   identity. Members of `sudo` authenticate with their own password, exactly as
   they do for sudo itself. */
polkit.addAdminRule(function(action, subject) {
    return ["unix-group:sudo"];
});
POLKIT
pk=$?
[ "$(stat -c %a /etc/polkit-1/rules.d/10-h96-admin.rules 2>/dev/null)" = 644 ] || chmod 0644 /etc/polkit-1/rules.d/10-h96-admin.rules
if [ "$pk" = 0 ]; then systemctl restart polkit.service 2>/dev/null || true; else echo "  polkit rule unchanged"; fi

# --- 5. HDMI audio ---
# Forced EDID (drm.edid_firmware h96-1080p-audio.bin, or h96-sink-audio.bin loaded by
# h96-audio-passthrough detect) gives HDMI card an ELD, so card profile layer (ACP)
# stays on with h96 profile set: layouts TV / AV receiver reports appear as card
# profiles in KDE. Profile set + codec rule generated by h96-hdmi-audio-detect.service.
# h96: 8ch hdmi audio
echo "[5] HDMI audio (WirePlumber, ACP with h96 profile set)"
# rule file is h96-audio conffile, not written here

echo "[5b] seeding the correct HDMI default-sink state (v3.2.1)"
# priority rule alone is not enough: WirePlumber's first-ever default-sink choice
# can land on S/PDIF (kept enabled as a fallback some boxes use) before the priority
# rule is read, and that choice sticks via the per-user state file below; write the
# correct choice directly for every existing user and pre-seed /etc/skel for new ones
OLD_HDMI_NODE='alsa_output.platform-hdmi0-sound.playback.0.0'
HDMI_DEFAULT_NODES='[default-nodes]\ndefault.configured.audio.sink=alsa_output.platform-hdmi0-sound.hdmi-stereo\ndefault.configured.audio.sink.0=alsa_output.platform-spdif-tx0-sound.stereo-fallback\n'
install -d -m 0700 /etc/skel/.local/state/wireplumber
printf '%b' "$HDMI_DEFAULT_NODES" > /etc/skel/.local/state/wireplumber/default-nodes.h96new \
  && if cmp -s /etc/skel/.local/state/wireplumber/default-nodes.h96new /etc/skel/.local/state/wireplumber/default-nodes; then rm -f /etc/skel/.local/state/wireplumber/default-nodes.h96new; else mv -f /etc/skel/.local/state/wireplumber/default-nodes.h96new /etc/skel/.local/state/wireplumber/default-nodes; fi
for home in /home/*; do
  [ -d "$home" ] || continue
  install -d -m 0700 "$home/.local/state/wireplumber" 2>/dev/null || continue
  dn="$home/.local/state/wireplumber/default-nodes"
  if [ -s "$dn" ] && ! grep -qF "$OLD_HDMI_NODE" "$dn"; then
    echo "  left alone: $home already has a configured default sink"
    continue
  fi
  printf '%b' "$HDMI_DEFAULT_NODES" | put_if_changed "$dn" || { echo "  HDMI default already set: $home"; continue; }
  owner=$(stat -c '%U:%G' "$home" 2>/dev/null)
  [ -n "$owner" ] && chown -R "$owner" "$home/.local/state/wireplumber" 2>/dev/null
  echo "  seeded HDMI default for: $home"
done
echo "[5c] disabling the DiscoverNotifier autostart (~128MB resident)"
# trade-off: loses the GUI update balloon; Discover still works when launched,
# apt untouched. undo per user by deleting the override below
DN=org.kde.discover.notifier.desktop
if [ -f "/etc/xdg/autostart/$DN" ]; then
  install -d -m 0755 /etc/skel/.config/autostart
  { cat "/etc/xdg/autostart/$DN"; echo "Hidden=true"; } | put_if_changed "/etc/skel/.config/autostart/$DN"
  for home in /home/*; do
    [ -d "$home" ] || continue
    install -d -m 0755 "$home/.config/autostart" 2>/dev/null || continue
    { cat "/etc/xdg/autostart/$DN"; echo "Hidden=true"; } | put_if_changed "$home/.config/autostart/$DN" \
      || { echo "  DiscoverNotifier autostart already disabled for: $home"; continue; }
    owner=$(stat -c '%U:%G' "$home" 2>/dev/null)
    [ -n "$owner" ] && chown -R "$owner" "$home/.config/autostart" 2>/dev/null
    echo "  DiscoverNotifier autostart disabled for: $home"
  done
else
  echo "  DiscoverNotifier autostart not present, nothing to disable"
fi

# --- 6. cups ---
# printing stays socket-activated: cupsd is out of RAM at boot, spawns on demand
echo "[6] cups (socket-activated)"
systemctl disable cups.service 2>/dev/null || true
systemctl enable cups.socket 2>/dev/null || true

# h96: wireplumber 0.5.18 from the offline repo (distro build is older)
echo "[6b] WirePlumber (offline repo)"
/usr/lib/h96/h96-wireplumber-offline.sh || echo "  !!! WirePlumber offline install failed"

# --- 6c. leftovers ---
echo "[6c] PulseAudio, XFCE and LXQt leftovers"
# pipewire-pulse replaced pulseaudio: purge conffiles (autostart entry, global user-unit links)
if dpkg-query -W -f='${db:Status-Abbrev}' pulseaudio 2>/dev/null | grep -q '^rc'; then
  env DEBIAN_FRONTEND=noninteractive apt-get purge -y -o DPkg::Lock::Timeout=600 pulseaudio >/dev/null 2>&1 \
    && echo "  pulseaudio conffiles purged" || echo "  !!! pulseaudio purge failed"
fi
for l in /etc/systemd/user/*.wants/pulseaudio.service /etc/systemd/user/*.wants/pulseaudio.socket; do
  [ -L "$l" ] && [ ! -e "$l" ] && rm -f "$l" && echo "  removed dangling $l"
done
if [ -e /etc/xdg/autostart/pulseaudio.desktop ] && ! command -v start-pulseaudio-x11 >/dev/null 2>&1; then
  rm -f /etc/xdg/autostart/pulseaudio.desktop && echo "  removed /etc/xdg/autostart/pulseaudio.desktop"
fi
# armbian-config XFCE skel autostarts pasystray, which is not installed
if ! command -v pasystray >/dev/null 2>&1; then
  for f in /etc/skel/.config/autostart/pasystray.desktop /home/*/.config/autostart/pasystray.desktop; do
    [ -f "$f" ] && rm -f "$f" && echo "  removed $f"
  done
fi
# software-properties-qt LXQt entries run lxqt-sudo: listed only once it is installed
for n in software-properties-lxqt software-properties-drivers-lxqt; do
  f="/usr/share/applications/$n.desktop"
  [ -f "$f" ] && ! grep -q '^TryExec=' "$f" || continue
  s='0,/^\[Desktop Entry\]$/s//[Desktop Entry]\nTryExec=lxqt-sudo/'
  for h in /etc/skel /home/*; do
    [ -d "$h" ] || continue
    if [ "$h" = /etc/skel ]; then u=root; else u=$(stat -c %U "$h"); fi
    # shellcheck disable=SC2016
    runuser -u "$u" -- sh -c 'mkdir -p "$1" && sed "$4" "$2" > "$1/$3.desktop.h96new" && if cmp -s "$1/$3.desktop.h96new" "$1/$3.desktop"; then rm -f "$1/$3.desktop.h96new"; else mv -f "$1/$3.desktop.h96new" "$1/$3.desktop"; fi' \
      _ "$h/.local/share/applications" "$f" "$n" "$s" && echo "  $n menu entry needs lxqt-sudo (TryExec, $h)"
  done
done

# --- 7. summary ---
# WirePlumber is per-user, a root-run script cannot restart it for the logged-in
# session; say what to do instead of leaving it looking broken
echo
echo "  the HDMI audio rule takes effect after wireplumber re-reads its config:"
echo "    log out and back in, or run as your desktop user:"
echo "      systemctl --user restart wireplumber pipewire pipewire-pulse"
echo
if [ -n "$MISSING" ]; then
  echo "!!! not installed:$MISSING"
  echo "    (re-run this script once the machine has network, or install by hand)"
else
  echo "  all requested packages present"
fi
echo "=== h96-desktop-fixup done $(date -Is) ==="
[ -z "$MISSING" ]
