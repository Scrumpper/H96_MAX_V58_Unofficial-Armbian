#!/bin/bash
# Install the offline-repo WirePlumber (0.5.18, upstream fix #1004) over the distro 0.5.13 once a desktop pulled it in.
# Idempotent; no-op without wireplumber installed or when the installed version is already >= the offline one.
# Called from h96-pkgs-setup.sh (every boot until done) and from desktop-fixup after the desktop install.
set -u
REPO=/opt/h96-pkgs
WANT=0.5.18-1~h96.1
PKGS="wireplumber libwireplumber-0.5-0"
have=$(dpkg-query -W -f='${Status} ${Version}' wireplumber 2>/dev/null | awk '/install ok installed/{print $4}')
[ -n "$have" ] || { echo "wireplumber not installed; nothing to do"; exit 0; }
dpkg --compare-versions "$have" ge "$WANT" && { echo "wireplumber $have already >= $WANT"; exit 0; }
grep -qx "Version: $WANT" "$REPO/Packages" 2>/dev/null || { echo "offline repo has no wireplumber $WANT"; exit 0; }
d=/etc/apt/sources.list.d
if [ -f "$d/h96-local.sources" ]; then SRC="$d/h96-local.sources"; else SRC="$d/h96-local.list"; fi
[ -f "$SRC" ] || { echo "no offline repo source file"; exit 0; }
apt_offline() {
  env DEBIAN_FRONTEND=noninteractive apt-get "$@" \
    -o Dir::Etc::sourcelist="$SRC" -o Dir::Etc::sourceparts=/dev/null -o DPkg::Lock::Timeout=600 -o APT::Get::List-Cleanup=0
}
apt_offline update >/dev/null 2>&1 || true
# explicit version: the offline repo is pinned to 1, so the plain candidate stays the distro build
apt_offline install -y --no-install-recommends $(for p in $PKGS; do printf '%s=%s ' "$p" "$WANT"; done) 2>&1 | tail -n 2
now=$(dpkg-query -W -f='${Version}' wireplumber 2>/dev/null)
[ "$now" = "$WANT" ] && echo "wireplumber $now installed (takes effect at next login)" || { echo "wireplumber still $now"; exit 1; }
