#!/bin/bash
LOG=/var/log/h96-video-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== H96 hardware-video (rkmpp) setup [OFFLINE] ==="; date
PAYLOAD=/usr/lib/h96/video
TAR="$PAYLOAD/h96-video-stack.tar.gz"
REPO=/opt/h96-pkgs
# The offline repo's apt source: the deb822 file shipped since v6.1, or the one-line file
# an older image or a manual edit left behind. Writes the deb822 form when neither exists.
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

# runtime deps for bundled mpv/ffmpeg + cage GPU kiosk: full ldd closure of the bundled binaries, not already in the base rootfs, plus nodejs/yt-dlp/cage and the V4L rkmpp plugin.
# librga is the only bundled lib not owned by any deb (ships in the tarball); libluajit-5.1-2 + libxpresent1 are required (Lua scripting + XPresent) or mpv fails with a missing-.so error; libdav1d7 = AV1 software decoder linked into mpv/ffmpeg (v7.1); libgbm1 = mpv/libmpv DRM context (v7.1); libpipewire-0.3-0t64 + libpulse0 = mpv pipewire and pulse audio outputs (8.0).
PKGS="nodejs yt-dlp cage libplacebo360 libass9 liblcms2-2 libxcb-dri2-0 \
libv4l-rkmpp libluajit-5.1-2 libvulkan1 libegl1 libgles2 libglvnd0 libgbm1 \
libwayland-client0 libwayland-cursor0 libwayland-egl1 libdrm2 \
libfreetype6 libfontconfig1 libharfbuzz0b libfribidi0 libunibreak6 \
libgnutls30t64 libxv1 libxss1 libxpresent1 libxrandr2 \
librockchip-mpp1 libxfixes3 libdisplay-info3 libdav1d7 \
libpipewire-0.3-0t64 libpulse0 \
irqbalance"
# ^ irqbalance: standard Armbian base daemon the lean/no-recommends base skipped; bundled here, auto-enables via its postinst

# 0) gate on the offline repo, not the network
if [ ! -s "$REPO/Packages" ]; then
  echo "!!! offline repo $REPO/Packages missing — cannot proceed; will retry next boot"; date
  exit 0
fi
# re-assert the canonical local apt source (defensive)
h96_offline_source

# v3.2.8: EVERY apt call in this unit is now scoped to ONLY the offline repo
# above (Dir::Etc::sourcelist points at just the offline source file, sourceparts is
# /dev/null so ubuntu.sources/armbian.sources are never even read). Before
# this fix, on real hardware, the SAME first-boot dependency install failed
# two different ways on two different boots, both silently swallowed by
# `|| true`.
apt_offline() {
  env DEBIAN_FRONTEND=noninteractive apt-get "$@" \
    -o Dir::Etc::sourcelist="$LOCAL_SRC" -o Dir::Etc::sourceparts=/dev/null \
    -o DPkg::Lock::Timeout=600 -o APT::Get::List-Cleanup=0
}

# batch first; on failure one package at a time, then online sources for whatever offline repo cannot resolve
install_deps() {
  apt_offline install -y $PKGS 2>&1 && return 0
  local p miss=""
  for p in $PKGS; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' && continue
    apt_offline install -y "$p" >/dev/null 2>&1 || miss="$miss $p"
  done
  [ -z "$miss" ] && return 0
  echo "  offline repo could not install:$miss; trying online sources"
  env DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=2 >/dev/null 2>&1
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 $miss 2>&1 | tail -n 3
}

# 1) wait for the dpkg lock to be free (armbian-config / unattended-upgrades)
echo "  waiting for dpkg lock..."
for i in $(seq 1 180); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  sleep 5
done

# 2) refresh apt lists (offline-only, instant, no DNS/network timeout)
apt_offline update -y >/dev/null 2>&1 || true

# 3) install runtime deps offline from /opt/h96-pkgs (apt_offline cannot reach the network)
echo "  installing runtime deps from offline repo: $PKGS"
install_deps || true

# 5) extract the bundled binary/lib stack into /usr (overlays stock librga/librockchip_mpp with rkmpp-enabled builds; installs mpv/ffmpeg/libmpv).
#    extraction is made deterministic (--overwrite, verify non-empty, retry up to 3x) since a first-boot race could otherwise leave mpv/libmpv at 0 bytes.
if [ -f "$TAR" ]; then
  MPV=/usr/bin/mpv
  LIBMPV=$(tar tzf "$TAR" 2>/dev/null | grep -E 'libmpv\.so\.[0-9.]+$' | head -1)
  LIBMPV="/${LIBMPV#./}"
  for attempt in 1 2 3; do
    echo "  extracting video stack into / (attempt $attempt)..."
    # --no-same-owner: archive entries must not hand system directories to the account that built the archive
    tar xzmf "$TAR" -C / --overwrite --no-same-owner 2>&1
    ldconfig
    # also require mpv to genuinely execute: a non-empty file can still be a truncated/corrupt binary that the shell's ENOEXEC fallback hides
    if [ -s "$MPV" ] && "$MPV" --version 2>/dev/null | grep -q '^mpv ' && { [ -z "$LIBMPV" ] || [ -s "$LIBMPV" ]; }; then
      echo "  extraction ok: mpv=$(stat -c%s "$MPV" 2>/dev/null)B libmpv=$(stat -c%s "$LIBMPV" 2>/dev/null)B"
      break
    fi
    # diagnose the real cause: a non-empty, correctly-sized mpv that won't run is missing a shared library, not a bad extraction, so re-extracting the tarball can never fix it (its deps come from step 3)
    if [ ! -s "$MPV" ]; then
      echo "  !! extraction left an empty/missing mpv (attempt $attempt) — retrying"
    else
      MISSING=$(ldd "$MPV" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')
      if [ -n "$MISSING" ]; then
        echo "  !! mpv extracted fine (mpv=$(stat -c%s "$MPV" 2>/dev/null)B) but is missing: $MISSING"
        echo "     re-running the offline dep install (not re-extracting the tarball)..."
        install_deps || true
        ldconfig
      else
        echo "  !! mpv=$(stat -c%s "$MPV" 2>/dev/null)B, all libs resolve, but still won't execute — retrying"
      fi
    fi
    sleep 2
  done
fi

# 6) refresh desktop/mime DBs so .desktop launchers register (best-effort)
update-desktop-database /usr/share/applications 2>/dev/null || true

# 7) mark done only if mpv actually runs and prints its version banner (else retry next boot); `mpv --version >/dev/null` alone is not sufficient since a 0-byte file EXITS 0 via the shell's ENOEXEC fallback.
if [ -s /usr/bin/mpv ] && /usr/bin/mpv --version 2>/dev/null | grep -q '^mpv '; then
  touch /var/lib/h96-video-setup-done
  # archive sha of extracted stack; h96-media postinst re-runs setup when it changes
  mkdir -p /var/lib/h96 && sha256sum < "$TAR" | cut -d' ' -f1 > /var/lib/h96/video-stack.sha256
  echo "  mpv: $(/usr/bin/mpv --version 2>/dev/null | head -1)"
  echo "=== hardware-video setup done (offline) ==="; date
else
  M=$(ldd /usr/bin/mpv 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')
  echo "!!! mpv not runnable after setup${M:+ (still missing: $M)} — NOT setting done flag; will retry next boot"; date
fi
