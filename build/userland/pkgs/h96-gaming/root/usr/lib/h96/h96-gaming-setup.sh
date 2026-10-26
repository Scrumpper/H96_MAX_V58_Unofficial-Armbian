#!/bin/bash
# h96-gaming-setup.sh: online first-boot setup for box64/wine/DXVK/PanVK gaming stack; sets done-flag only after validation, else retries next boot.
set -o pipefail
LOG=/var/log/h96-gaming-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== H96 gaming stack (PanVK/box64/wine/DXVK) setup [ONLINE] ==="; date

PAYLOAD=/usr/lib/h96/gaming
TAR=/opt/h96-gaming/h96-gaming-stack.tar.gz
BOX64_DEB="$PAYLOAD/box64-rk3588-fallback.deb"   # offline fallback for apt pkg
DONE=/var/lib/h96-gaming-setup-done
REPO=/opt/h96-pkgs                                # offline apt repo (mesa 26.1.4 debs)
MESA_VER="26.1.4~kisak1~r"                        # kisak GL+Vulkan lockstep target

# --- Panthor guard: PanVK/panfrost need the panthor kernel driver ---
PANTHOR_DONE=/var/lib/h96-panthor-setup-done
if [ ! -e "$PANTHOR_DONE" ] && [ ! -d /sys/bus/platform/drivers/panthor ]; then
  echo "  panthor driver not registered; deferring gaming setup to a later boot"
  date
  exit 0
fi

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

# Installed in two passes: apt is atomic, so an unreachable online package must not abort offline installs.
# OFFLINE: required for the step-8 validation gate; all present in /opt/h96-pkgs.
APT_PKGS_OFFLINE="vulkan-tools cage mesa-utils"
# ONLINE: best-effort; box64-rk3588 has a bundled fallback (step 3b), never gates.
APT_PKGS_ONLINE="box64-rk3588 gamescope"

# Scope apt to the offline repo only: sourceparts=/dev/null keeps online sources unread.
apt_offline() {
  env DEBIAN_FRONTEND=noninteractive apt-get "$@" \
    -o Dir::Etc::sourcelist="$LOCAL_SRC" \
    -o Dir::Etc::sourceparts=/dev/null \
    -o DPkg::Lock::Timeout=600
}

# Resolve the PanVK ICD path; filename varies across Mesa builds.
find_panvk_icd() {
  local f
  for f in /usr/share/vulkan/icd.d/panfrost_icd.aarch64.json \
           /usr/share/vulkan/icd.d/panfrost_icd.json; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  f=$(ls /usr/share/vulkan/icd.d/*panfrost*_icd*.json 2>/dev/null | head -1)
  [ -n "$f" ] && { echo "$f"; return 0; }
  return 1
}

# --- 1) wait for dpkg lock ---
echo "  waiting for dpkg lock..."
for i in $(seq 1 180); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  sleep 5
done

# --- 2) refresh apt lists (best-effort, offline tolerated) ---
echo "  apt-get update..."
env DEBIAN_FRONTEND=noninteractive apt-get update -y \
  -o Acquire::Retries=3 >/dev/null 2>&1
APT_UPDATE_RC=$?
[ $APT_UPDATE_RC -ne 0 ] && echo "  (apt-get update rc=$APT_UPDATE_RC; likely offline; continuing with fallbacks)"

# --- 3) install apt packages; rc is logged, not masked, step 8 gates the done-flag ---
# 3a) offline-required packages, installed one at a time so one failure does not abort the rest.
echo "  installing offline-repo packages (network-independent): $APT_PKGS_OFFLINE"
APT_INSTALL_RC=0
for p in $APT_PKGS_OFFLINE; do
  if apt_offline install -y "$p" >/dev/null 2>&1; then
    echo "    [ ok ] $p"
  else
    echo "    [FAIL] $p (offline repo)"
    APT_INSTALL_RC=1
  fi
done
echo "  offline apt install rc=$APT_INSTALL_RC"

# 3b) online extras, best-effort; never gates the done-flag.
echo "  installing online-only extras (best-effort): $APT_PKGS_ONLINE"
for p in $APT_PKGS_ONLINE; do
  if env DEBIAN_FRONTEND=noninteractive apt-get install -y \
       -o DPkg::Lock::Timeout=600 -o Acquire::Retries=1 "$p" >/dev/null 2>&1; then
    echo "    [ ok ] $p"
  else
    echo "    [skip] $p (offline or unreachable; non-fatal)"
  fi
done

# box64 offline fallback: install the bundled deb via dpkg if apt could not provide it.
if ! command -v box64 >/dev/null 2>&1; then
  if [ -f "$BOX64_DEB" ]; then
    echo "  box64 missing after apt; installing bundled fallback .deb"
    env DEBIAN_FRONTEND=noninteractive dpkg -i "$BOX64_DEB"
    echo "  dpkg -i box64 fallback rc=$?"
  else
    echo "  !! box64 still missing and no bundled fallback present"
  fi
fi

# --- 4) extract wine/DXVK bundle; verify wine binary non-empty, retry up to 3x ---
if [ -f "$TAR" ]; then
  WINE_BIN=/opt/h96-gaming/wine/bin/wine
  for attempt in 1 2 3; do
    echo "  extracting gaming stack into / (attempt $attempt)..."
    tar xzmf "$TAR" -C / --overwrite 2>&1
    if [ -s "$WINE_BIN" ]; then
      echo "  extraction ok: wine=$(stat -c%s "$WINE_BIN" 2>/dev/null)B"
      break
    fi
    echo "  !! extraction left wine empty/absent; retrying"; sleep 2
  done
else
  echo "  wine downloads on first h96-game-mode run; DXVK is in /usr/lib/h96/gaming"
fi

# --- 5) install global box64rc (h96-game-mode and h96-dxvk-install are packaged in /usr/bin) ---
if [ -f /usr/lib/h96/gaming/box64.box64rc ]; then
  # Append h96 per-title stanzas after the stock box64rc rather than replacing it (marker-guarded, idempotent).
  H96_RC_MARK="# >>> h96 per-title tuning (v2.9) >>>"
  if [ -f /etc/box64.box64rc ]; then
    [ -f /etc/box64.box64rc.dist ] || cp /etc/box64.box64rc /etc/box64.box64rc.dist
    if ! grep -qF "$H96_RC_MARK" /etc/box64.box64rc; then
      { echo ""; echo "$H96_RC_MARK";
        cat /usr/lib/h96/gaming/box64.box64rc;
        echo "# <<< h96 per-title tuning <<<"; } >> /etc/box64.box64rc
      echo "  appended h96 per-title stanzas to stock /etc/box64.box64rc (stock [steam*] profiles kept)"
    else
      echo "  /etc/box64.box64rc already carries the h96 stanzas; leaving as-is"
    fi
  else
    cp /usr/lib/h96/gaming/box64.box64rc /etc/box64.box64rc
    echo "  installed /etc/box64.box64rc (no stock rc was present)"
  fi
fi

# --- 6) refresh desktop database for the Game-Mode .desktop entry ---
update-desktop-database /usr/share/applications 2>/dev/null || true

# --- 6.5) base-wide Mesa upgrade to MESA_VER, offline; must precede ICD resolution in step 7 ---
echo "  upgrading Mesa GL+Vulkan stack to $MESA_VER (offline, base-wide)..."
apt-get update -y >/dev/null 2>&1 || true
env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
  -o DPkg::Lock::Timeout=600 \
  mesa-vulkan-drivers=$MESA_VER libgl1-mesa-dri=$MESA_VER libglx-mesa0=$MESA_VER \
  libegl-mesa0=$MESA_VER libgbm1=$MESA_VER mesa-libgallium=$MESA_VER
MESA_RC=$?
echo "  mesa upgrade apt (pinned-by-name) rc=$MESA_RC"
# Fallback: install the staged debs by absolute path if the pinned-by-name install failed.
if [ "$MESA_RC" -ne 0 ] && [ -f "$REPO/mesa-vulkan-drivers_${MESA_VER}_arm64.deb" ]; then
  echo "  pinned-by-name install failed; falling back to install-by-path from $REPO"
  env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    -o DPkg::Lock::Timeout=600 \
    "$REPO/mesa-libgallium_${MESA_VER}_arm64.deb" \
    "$REPO/libgbm1_${MESA_VER}_arm64.deb" \
    "$REPO/libgl1-mesa-dri_${MESA_VER}_arm64.deb" \
    "$REPO/libglx-mesa0_${MESA_VER}_arm64.deb" \
    "$REPO/libegl-mesa0_${MESA_VER}_arm64.deb" \
    "$REPO/mesa-vulkan-drivers_${MESA_VER}_arm64.deb"
  MESA_RC=$?
  echo "  mesa install-by-path apt rc=$MESA_RC"
fi
ldconfig
echo "  mesa-vulkan-drivers now: $(dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null || echo '?')"
# Mesa userspace in place: mark panthor setup done (8.0 has no h96-panthor-setup run)
if [ "$MESA_RC" -eq 0 ] && [ ! -e "$PANTHOR_DONE" ]; then
  touch "$PANTHOR_DONE"
  echo "  set $PANTHOR_DONE"
fi

# --- 7) validation gate: hard = box64/Dynarec, PanVK ICD, wine under box64; soft = BOX32, vkcube ---
PASS=1

# 7a) box64 + Dynarec (hard) / BOX32 (soft)
BANNER=$(box64 --version 2>&1; box64 /bin/true 2>&1)
if command -v box64 >/dev/null 2>&1 && echo "$BANNER" | grep -qi 'dynarec'; then
  echo "  [OK ] box64 present with Dynarec: $(box64 --version 2>&1 | head -1)"
else
  echo "  [FAIL] box64 missing or Dynarec not reported"; PASS=0
fi
# banner of box64 0.4.x does not name Box32; binary carries its log string
if grep -qaF 'Using Box32' "$(command -v box64 2>/dev/null || echo /nonexistent)" 2>/dev/null; then
  echo "  [OK ] box64 BOX32 (32-bit x86) support present"
else
  echo "  [WARN] BOX32 not found in box64 binary: 32-bit x86 programs under box64 may not run"
  echo "         (wow64 wine and Steam under FEX do not need BOX32; not gating on this)"
fi

# 7b) PanVK via the Mesa panfrost Vulkan ICD (hard)
ICD=$(find_panvk_icd)
if [ -n "$ICD" ]; then
  echo "  using PanVK ICD: $ICD"
  VKINFO=$(VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" vulkaninfo 2>/dev/null)
  # Here-string, not a pipe: grep -q would SIGPIPE echo under pipefail and false-fail.
  if grep -qiE 'panvk|panfrost|mali' <<<"$VKINFO"; then
    echo "  [OK ] vulkaninfo reports PanVK device:"
    grep -iE 'driverName|deviceName|apiVersion' <<<"$VKINFO" | head -4 | sed 's/^/         /' || true
  else
    echo "  [FAIL] vulkaninfo did not report a PanVK/Mali device via $ICD"; PASS=0
  fi
else
  echo "  [FAIL] no panfrost Vulkan ICD found in /usr/share/vulkan/icd.d/ (Mesa/PanVK not installed?)"; PASS=0
fi

# 7c) wine (wow64) under box64 (hard)
if [ -x /opt/h96-gaming/wine/bin/wine ]; then
  WV=$(box64 /opt/h96-gaming/wine/bin/wine --version 2>&1 | head -1)
  if grep -qi 'wine' <<<"$WV"; then
    echo "  [OK ] wine runs under box64: $WV"
  else
    echo "  [FAIL] box64 wine --version did not report a version: $WV"; PASS=0
  fi
else
  echo "  [INFO] wine fetched on demand by h96-game-mode - not gating done flag"
fi

# 7d) vkcube smoke test (soft, needs a KMS surface)
if [ -n "$ICD" ] && command -v vkcube >/dev/null 2>&1; then
  echo "  vkcube smoke (best-effort, 60-frame headless-timeout)..."
  if command -v cage >/dev/null 2>&1; then
    timeout 40 env VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD" \
      cage -- vkcube --c 60 >/dev/null 2>&1 \
      && echo "  [OK ] vkcube rendered 60 frames under cage" \
      || echo "  [INFO] vkcube frame test skipped/failed (no free KMS surface at first boot; not gating)"
  fi
fi

command -v cage >/dev/null 2>&1 || { echo "  [FAIL] cage not installed (h96-game-mode default, h96-mpv-kiosk)"; PASS=0; }
# --- 8) set done-flag only if hard gates passed ---
if [ "$PASS" -eq 1 ]; then
  touch "$DONE"
  # Self-retire: disable and drop both wants symlinks so a done unit stops pulling network-online.target on every boot.
  systemctl disable h96-gaming-setup.service 2>/dev/null || true
  rm -f /usr/lib/systemd/system/multi-user.target.wants/h96-gaming-setup.service
  rm -f /etc/systemd/system/multi-user.target.wants/h96-gaming-setup.service
  echo "=== gaming stack setup DONE (validated) ==="; date
else
  echo "!!! gaming stack incomplete; NOT setting done flag; will retry next boot"; date
fi
