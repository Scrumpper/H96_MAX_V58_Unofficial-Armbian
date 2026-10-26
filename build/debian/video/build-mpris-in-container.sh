#!/bin/bash
# Inside amd64 trixie container: mpv-mpris 1.2 (MIT) cross-built for arm64 against trixie glib, no libavformat
# (same patch as Ubuntu r28); mpv client headers from mpv 0.41.0 source. Two builds byte-equal. Mounts /src, /w.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
cat > /etc/apt/sources.list.d/debian.sources <<'S'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
S
dpkg --add-architecture arm64
apt-get update -q
apt-get upgrade -y -q > /dev/null
apt-get install -y -q --no-install-recommends crossbuild-essential-arm64 pkgconf patch libglib2.0-dev:arm64 > /dev/null
dpkg-query -W -f '${Package}:${Architecture} ${Version}\n' libglib2.0-dev gcc-aarch64-linux-gnu libc6-dev:arm64 | tee /w/out-mpris/toolchain.txt
mkdir -p /b/mpvsrc && tar xzf /src/video-src/mpv-0.41.0.tar.gz -C /b/mpvsrc --strip-components=1 --wildcards '*/include/mpv/*'
export PKG_CONFIG=aarch64-linux-gnu-pkg-config
build() {
  local w=/b/mpris; rm -rf "$w"; mkdir -p "$w" "$1"
  tar xzf /src/mpris-src/mpv-mpris-1.2.tar.gz -C "$w" --strip-components=1
  patch -d "$w" -p1 < /w/mpv-mpris-no-avformat.patch
  # shellcheck disable=SC2046
  (cd "$w" && aarch64-linux-gnu-gcc mpris.c -o mpris.so -std=c99 -Wall -Wextra -Werror -pedantic -O2 \
      -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIC -shared -ffile-prefix-map=/b=/build -I/b/mpvsrc/include \
      $($PKG_CONFIG --cflags gio-2.0 gio-unix-2.0 glib-2.0) $($PKG_CONFIG --libs gio-2.0 glib-2.0) \
      -Wl,-z,relro,-z,now -Wl,--build-id=sha1 -Wl,--as-needed)
  aarch64-linux-gnu-strip --strip-unneeded --remove-section=.comment -o "$1/mpris.so" "$w/mpris.so"
  cp "$w/LICENSE" "$1/LICENSE"
}
build /w/out-mpris; build /b/second
cmp /w/out-mpris/mpris.so /b/second/mpris.so && echo "two builds byte-equal"
cd /w/out-mpris
aarch64-linux-gnu-objdump -p mpris.so | awk '/NEEDED/{print "NEEDED", $2}'
echo "GLIBC max $(aarch64-linux-gnu-objdump -T mpris.so | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
echo "undefined mpv_ symbols: $(aarch64-linux-gnu-nm -D --undefined-only mpris.so | grep -c ' mpv_')"
! aarch64-linux-gnu-nm -D --undefined-only mpris.so | grep -E ' av' || { echo "avformat symbol left"; exit 1; }
sha256sum mpris.so LICENSE | tee SHA256SUMS
echo MPRIS_OK
