#!/bin/bash
# Runs inside h96-trixie-arm64 container (qemu): WirePlumber Debian 0.5.18-1 rebuilt for trixie against backports
# PipeWire; version 0.5.18-1~h96.1+deb13.1. /w/src = dsc set (sha checked against .dsc), /w/out = debs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
V=0.5.18-1~h96.1+deb13.1
cat > /etc/apt/sources.list.d/debian.sources <<'S'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
S
apt-get update -q
apt-get install -y -q --no-install-recommends build-essential fakeroot dpkg-dev debhelper dh-exec gnome-pkg-tools \
  gobject-introspection libglib2.0-dev liblua5.4-dev libsystemd-dev meson ninja-build pkgconf systemd-dev ca-certificates
apt-get install -y -q --no-install-recommends -t trixie-backports libpipewire-0.3-dev libspa-0.2-dev
dpkg-query -W libpipewire-0.3-dev libspa-0.2-dev
cd /w/src
awk '/^Checksums-Sha256:/{f=1;next} /^[^ ]/{f=0} f{print $1"  "$3}' wireplumber_0.5.18-1.dsc | sha256sum -c
rm -rf /b && mkdir /b && cd /b
tar xzf /w/src/wireplumber_0.5.18.orig.tar.gz; mv wireplumber-0.5.18* wireplumber-0.5.18; cd wireplumber-0.5.18
tar xJf /w/src/wireplumber_0.5.18-1.debian.tar.xz
for p in $(cat debian/patches/series); do patch -p1 -s < "debian/patches/$p"; done
{ printf 'wireplumber (%s) trixie; urgency=medium\n\n' "$V"
  printf '  * Debian 0.5.18-1 rebuilt for trixie against trixie-backports PipeWire (H96 offline repo).\n'
  printf '  * Fixes event dispatcher freeze on failed node creation (upstream #1004).\n\n'
  printf ' -- Scrumpper <190908034+Scrumpper@users.noreply.github.com>  %s\n\n' "Wed, 21 Oct 2026 22:00:00 +0000"
  cat debian/changelog; } > debian/changelog.new; mv debian/changelog.new debian/changelog
export SOURCE_DATE_EPOCH=1792620000 DEB_BUILD_PROFILES="nodoc nogir nocheck" DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)"
dpkg-buildpackage -b -nc -us -uc -Pnodoc,nogir,nocheck > /w/out/build.log 2>&1 || { tail -40 /w/out/build.log; exit 1; }
cd /b; cp -p ./*.deb ./*.buildinfo /w/out/; cd /w/out; sha256sum ./*.deb > SHA256SUMS; cat SHA256SUMS
for d in *.deb; do dpkg-deb -f "$d" Package Version Depends; done
echo WP_OK
