#!/bin/bash
# Install ddcutil from the offline repo (file:///opt/h96-pkgs, no network) so h96-brightness/PowerDevil DDC/CI brightness works; gated on a done-flag, runs off the boot path via a timer.
LOG=/var/log/h96-ddc-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== H96 ddcutil setup [OFFLINE] ==="; date
DONE=/var/lib/h96-ddc-setup-done
REPO=/opt/h96-pkgs
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
command -v ddcutil >/dev/null 2>&1 && { echo "ddcutil already present"; touch "$DONE"; exit 0; }
[ -s "$REPO/Packages" ] || { echo "offline repo missing; will retry next boot"; exit 0; }
grep -q "Package: ddcutil" "$REPO/Packages" || { echo "ddcutil not in offline repo; giving up"; touch "$DONE"; exit 0; }
h96_offline_source
apt_offline() {
  env DEBIAN_FRONTEND=noninteractive apt-get "$@" \
    -o Dir::Etc::sourcelist="$LOCAL_SRC" -o Dir::Etc::sourceparts=/dev/null \
    -o DPkg::Lock::Timeout=600 -o APT::Get::List-Cleanup=0
}
for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 5; done
apt_offline update -y >/dev/null 2>&1 || true
apt_offline install -y ddcutil 2>&1 || true
if command -v ddcutil >/dev/null 2>&1; then echo "ddcutil installed"; touch "$DONE"; else echo "install failed; will retry next boot"; fi
exit 0
