#!/bin/bash
# Laptop tests T5 to T9 inside throwaway copy of built rootfs (network): KDE closure, Mesa pin, video stack run under
# qemu, Python 3.13 compile, systemd unit verify, Recommends-on install simulation. Copy is discarded afterwards.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
L=/root/f5-log/tests; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
apt-get -o Acquire::PDiffs=false update > "$L/update.txt" 2>&1 && ok "apt-get update (online + offline sources, box64 keyrings from h96-gaming)" || bad "update: $(grep -m3 '^[EW]:' "$L/update.txt" | tr '\n' ' ')"
echo "== T7 Mesa pin"
apt-cache policy mesa-vulkan-drivers libgbm1 libgl1-mesa-dri > "$L/t7-policy.txt" 2>&1
for p in mesa-vulkan-drivers libgbm1 libgl1-mesa-dri; do
  c=$(apt-cache policy "$p" | sed -n 's/^  Candidate: //p'); echo "  $p candidate $c"
  [ "$c" = 26.1.6-1~bpo13+1 ] && ok "T7 $p candidate 26.1.6-1~bpo13+1 (25.0.7 not chosen)" || bad "T7 $p candidate $c"
done
SRC=/etc/apt/sources.list.d/h96-local.sources
apt-get -s -o Dir::Etc::sourcelist=$SRC -o Dir::Etc::sourceparts=/dev/null install mesa-vulkan-drivers=26.1.6-1~bpo13+1 libgl1-mesa-dri=26.1.6-1~bpo13+1 \
  libglx-mesa0=26.1.6-1~bpo13+1 libegl-mesa0=26.1.6-1~bpo13+1 libgbm1=26.1.6-1~bpo13+1 mesa-libgallium=26.1.6-1~bpo13+1 vulkan-tools cage mesa-utils > "$L/t7-offline-sim.txt" 2>&1 \
  && ok "T7 gaming setup offline Mesa install resolves from offline repo alone ($(grep -c '^Inst' "$L/t7-offline-sim.txt") packages)" || bad "T7 offline Mesa: $(grep -m2 'E:\|unmet' "$L/t7-offline-sim.txt")"
L5=/usr/lib/aarch64-linux-gnu/libGLX_mesa.so.0
echo "== T6 KDE closure"
KDE="kde-plasma-desktop sddm sddm-theme-breeze konsole dolphin ark bluedevil gwenview kscreen network-manager-gnome okular plasma-nm plasma-pa xserver-xorg dbus-x11 dmz-cursor-theme fonts-ubuntu gtk2-engines gtk2-engines-murrine gtk2-engines-pixbuf gvfs-backends lm-sensors spice-vdagent xdg-user-dirs accountsservice libu2f-udev pipewire-audio pipewire-pulse wireplumber"
# shellcheck disable=SC2086
apt-get -s install $KDE > "$L/t6-armbian-tier.txt" 2>&1 && ok "T6 armbian-config KDE minimal tier (trixie) resolves: $(grep -c '^Inst' "$L/t6-armbian-tier.txt") packages" || bad "T6 KDE tier: $(grep -m3 'E:\|unmet\|but' "$L/t6-armbian-tier.txt" | tr '\n' ' ')"
grep -E '^Inst (plasma-workspace|pipewire|libpipewire-0.3-0t64|wireplumber|kwin-wayland|sddm) ' "$L/t6-armbian-tier.txt" | sed 's/^/  /'
for p in kwin-x11 lightdm lightdm-gtk-greeter xinit x11-xserver-utils plasma-session-x11; do
  c=$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^  Candidate: //p'); echo "  h96-kde-configure X11 set: $p candidate ${c:-none}"
done
# shellcheck disable=SC2086
apt-get -s install $KDE kwin-x11 lightdm lightdm-gtk-greeter xinit x11-xserver-utils > "$L/t6-x11.txt" 2>&1 && ok "T6 KDE tier + X11 set (kwin-x11, lightdm) resolves" || bad "T6 X11 set: $(grep -m3 'E:\|unmet' "$L/t6-x11.txt" | tr '\n' ' ')"
grep -q '^Inst kwin-x11 ' "$L/t6-x11.txt" && grep -q '^Inst lightdm ' "$L/t6-x11.txt" && ok "T6 kwin-x11 and lightdm in transaction" || bad "T6 kwin-x11/lightdm missing"
apt-cache policy plasma-session-x11 2>/dev/null | grep -q 'Candidate: [0-9]' && echo "INFO plasma-session-x11 has candidate" || ok "T6 plasma-session-x11 absent (X11 session in plasma-workspace 6.3), skipped by h96-kde-configure"
grep -o '^Inst plasma-workspace [^ ]* ([^ ]*' "$L/t6-x11.txt" | sed 's/^/  /'
grep -o '^Inst pipewire [^ ]* ([^ ]*' "$L/t6-x11.txt" | sed 's/^/  PipeWire with backports pin: /'
grep -q '^Inst pipewire (1\.6\.9\|^Inst pipewire \[.*\] (1\.6\.9' "$L/t6-x11.txt" && ok "T6 PipeWire 1.6.9 from backports by pin" || echo "INFO PipeWire version: $(grep '^Inst pipewire ' "$L/t6-x11.txt")"
echo "== T5 Recommends on (simulation over installed h96 set)"
REC=$(dpkg-query -W -f '${Recommends}, ' h96-base h96-boot h96-net h96-audio h96-desktop h96-media h96-tools h96-gaming steam-arm-setup h96-kernel-switch | tr ',' '\n' | sed 's/(.*//; s/|.*//; s/ //g' | grep -v '^steam-arm-setup$' | sort -u | xargs)
echo "  Recommends of installed set: $REC"
# shellcheck disable=SC2086
apt-get -s install $REC > "$L/t5-recommends.txt" 2>&1 && ok "T5 Recommends of h96 set resolve on trixie ($(grep -c '^Inst' "$L/t5-recommends.txt") packages)" || bad "T5 recommends: $(grep -m3 'E:\|unmet' "$L/t5-recommends.txt")"
echo "== T8 video stack under qemu"
PKGS=$(sed -n 's/^\[ .* = debian \] && PKGS="\(.*\)"$/\1/p' /usr/lib/h96/h96-video-setup.sh)
echo "  video PKGS (Debian): $PKGS"
# shellcheck disable=SC2086
apt-get -y -o Dir::Etc::sourcelist=$SRC -o Dir::Etc::sourceparts=/dev/null install $PKGS > "$L/t8-install.txt" 2>&1 && ok "T8 video runtime set installs from offline repo alone" || bad "T8 install: $(grep -m3 'E:' "$L/t8-install.txt")"
tar xzmf /usr/lib/h96/video/h96-video-stack.tar.gz -C / --overwrite --no-same-owner && ldconfig
for b in /usr/bin/mpv /usr/bin/ffmpeg /usr/bin/ffprobe /usr/lib/aarch64-linux-gnu/libmpv.so.2.5.0; do
  m=$(ldd "$b" 2>&1 | grep 'not found'); [ -z "$m" ] && ok "T8 ldd $b resolves" || bad "T8 $b missing: $m"
done
mpv --version > "$L/t8-mpv.txt" 2>&1 && head -1 "$L/t8-mpv.txt" | grep -q '^mpv v0.41.0' && ok "T8 mpv --version under qemu: $(head -1 "$L/t8-mpv.txt")" || bad "T8 mpv run"
ffmpeg -hide_banner -hwaccels > "$L/t8-hwaccels.txt" 2>&1; grep -qx rkmpp "$L/t8-hwaccels.txt" && grep -qx drm "$L/t8-hwaccels.txt" && ok "T8 ffmpeg hwaccels drm rkmpp" || bad "T8 hwaccels"
mpv --gpu-context=help 2>&1 | grep -q 'drm *DRM/EGL' && ok "T8 mpv GPU context drm" || bad "T8 drm context"
ffmpeg -hide_banner -decoders 2>/dev/null | grep -E 'rkmpp' | head -3 | sed 's/^/  /'
# glibc symbol versions of every ELF: checked on laptop with host objdump (pipeline/elf-glibc.sh; no binutils in image)
echo "== T9 Python 3.13 and systemd 257"
n=0; e=0; for f in $(dpkg -L h96-audio h96-base h96-boot h96-desktop h96-gaming h96-media h96-net h96-tools | sort -u); do
  [ -f "$f" ] || continue; head -c 100 "$f" | head -1 | grep -q '^#!.*python3' || case "$f" in *.py) ;; *) continue ;; esac
  grep -q $'PK\x03\x04' "$f" 2>/dev/null && { echo "  zipapp skipped: $f"; continue; }
  n=$((n+1)); python3 -c 'import sys,ast; ast.parse(open(sys.argv[1],"rb").read(), sys.argv[1])' "$f" 2> "$L/py-err.txt" || { e=$((e+1)); echo "  py error $f: $(tail -1 "$L/py-err.txt")"; }
done
[ "$e" = 0 ] && ok "T9 Python $(python3 -V | cut -d' ' -f2) parses $n h96 Python files" || bad "T9 $e Python files fail"
U=$(dpkg -L h96-audio h96-base h96-boot h96-desktop h96-gaming h96-media h96-net h96-tools h96-kernel-switch | grep -E '/systemd/(system|user)/[^/]+\.(service|timer|path|socket)$' | sort -u)
SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no $U > "$L/t9-verify.txt" 2>&1
grep -iE 'unknown (key|lvalue|section)' "$L/t9-verify.txt" > "$L/t9-unknown.txt"; echo "  units: $(echo "$U" | wc -l), verify lines: $(wc -l < "$L/t9-verify.txt")"
[ ! -s "$L/t9-unknown.txt" ] && ok "T9 systemd $(systemctl --version | head -1 | cut -d' ' -f2) verify: 0 unknown keys" || bad "T9 unknown keys: $(head -3 "$L/t9-unknown.txt")"
rm -f /usr/sbin/policy-rc.d
echo "fail=$fail"; exit $fail
