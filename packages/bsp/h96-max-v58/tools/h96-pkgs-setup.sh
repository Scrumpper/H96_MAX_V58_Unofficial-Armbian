#!/bin/bash
# Install v6.2 base packages from the offline repo: v4l-utils (cec-ctl, h96-cec), dnsmasq-base (h96-hotspot).
LOG=/var/log/h96-pkgs-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "=== H96 offline package setup ==="; date
DONE=/var/lib/h96-pkgs-setup-done
REPO=/opt/h96-pkgs
PKGS="v4l-utils dnsmasq-base"
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
missing() { local p m=""; for p in $PKGS; do installed "$p" || m="$m $p"; done; echo "$m"; }
MISS=$(missing)
[ -z "$MISS" ] && { echo "all present"; touch "$DONE"; exit 0; }
[ -s "$REPO/Packages" ] || { echo "offline repo missing; retry next boot"; exit 0; }
# offline repo source: v6.1+ deb822 file, older one-line file, else write deb822
d=/etc/apt/sources.list.d
if [ -f "$d/h96-local.sources" ]; then LOCAL_SRC="$d/h96-local.sources"
elif [ -f "$d/h96-local.list" ]; then LOCAL_SRC="$d/h96-local.list"
else
  LOCAL_SRC="$d/h96-local.sources"
  printf 'Types: deb\nURIs: file:/opt/h96-pkgs/\nSuites: ./\nSigned-By: /usr/share/keyrings/h96-local-archive-keyring.gpg\n' > "$LOCAL_SRC"
fi
apt_offline() {
  env DEBIAN_FRONTEND=noninteractive apt-get "$@" \
    -o Dir::Etc::sourcelist="$LOCAL_SRC" -o Dir::Etc::sourceparts=/dev/null \
    -o DPkg::Lock::Timeout=600
}
for i in $(seq 1 100); do
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 || break
  sleep 5
done
apt_offline update >/dev/null 2>&1 || true
# one package per transaction: one failure never blocks the other
for p in $MISS; do
  grep -qx "Package: $p" "$REPO/Packages" || { echo "$p not in offline repo; skipped"; continue; }
  apt_offline install -y --no-install-recommends "$p" 2>&1 | tail -n 2
done
MISS=$(missing)
if [ -z "$MISS" ]; then echo "installed: $PKGS"; touch "$DONE"; else echo "still missing:$MISS; retry next boot"; fi
exit 0
