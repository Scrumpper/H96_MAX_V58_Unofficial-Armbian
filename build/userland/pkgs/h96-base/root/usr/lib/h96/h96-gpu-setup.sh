#!/bin/bash
LOG=/var/log/h96-gpu-setup.log
exec > >(tee -a "$LOG") 2>&1
REL="$(sed -n 's/^H96_RELEASE=//p' /etc/h96-release 2>/dev/null)"
echo "=== H96 Max V58 GPU Setup ${REL:-} ==="
date

step_ok()   { echo "  [OK]   $1"; }
step_fail() { echo "  [WARN] $1 failed -- continuing"; }

# Mesa panthor (GL) and panvk (Vulkan) own the GPU; no vendor blob
echo "[1/4] Checking panthor GPU driver..."
[ -d /sys/bus/platform/drivers/panthor ] && step_ok "panthor driver" || step_fail "panthor driver"

echo "[2/4] Installing Rockchip MPP..."
for deb in /opt/h96-pkgs/librockchip-mpp1_*.deb \
           /opt/h96-pkgs/librockchip-vpu0_*.deb \
           /opt/h96-pkgs/librga2_*.deb \
           /opt/h96-pkgs/libv4l-rkmpp_*.deb; do
    [ -f "$deb" ] && dpkg -i --force-all "$deb" 2>/dev/null || true
done
dpkg-query -W -f='${Status}' librockchip-mpp1 2>/dev/null | grep -q 'ok installed' && \
    step_ok "MPP + libv4l-rkmpp" || step_fail "MPP debs"

echo "[3/4] Offline package source..."
# Ensure the offline apt source file exists (deb822 or legacy one-line form); write deb822 if missing.
h96_offline_source() {
  local d=/etc/apt/sources.list.d
  if [ -f "$d/h96-local.sources" ]; then LOCAL_SRC="$d/h96-local.sources"
  elif [ -f "$d/h96-local.list" ]; then LOCAL_SRC="$d/h96-local.list"
  else
    LOCAL_SRC="$d/h96-local.sources"
    printf 'Types: deb\nURIs: file:/opt/h96-pkgs/\nSuites: ./\nSigned-By: /usr/share/keyrings/h96-local-archive-keyring.gpg\n' > "$LOCAL_SRC"
  fi
}
h96_offline_source
apt-get update -q 2>/dev/null
echo "  [INFO] DXVK for h96-game-mode is in /usr/lib/h96/gaming (no package)"

echo "[4/4] Session environment..."
# base image may carry vendor-blob Vulkan and GTK lines; drop them
if [ -e /etc/environment ]; then
  sed -i -e '/VK_ICD_FILENAMES=.*mali/d' -e '/^GSK_RENDERER=cairo/d' /etc/environment
fi
step_ok "/etc/environment"

echo "=== GPU setup ${REL:-} complete ==="
date
touch /var/lib/h96-gpu-setup-done
