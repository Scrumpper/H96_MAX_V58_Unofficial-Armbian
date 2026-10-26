#!/bin/bash
# Heavy: Debian video stack (ffmpeg-rockchip, mpv) or MPRIS plugin, cross build in amd64 trixie container.
# Usage: run.sh stack|mpris   Output $W/video/out (h96-video-stack.tar.gz) or $W/video/out-mpris (mpris.so).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; WHAT=${1:?stack or mpris}
CI=${H96_DEB_CONTAINER_AMD64:-docker.io/library/debian:trixie}
V=$W/video; rm -rf "$V"; mkdir -p "$V/src/video-src" "$V/src/mpris-src"; cp -p "$H"/*.sh "$H"/*.patch "$H"/pack-stack.py "$V/"
cp1() { [ "$(sha256sum < "$IN/$1" | cut -d' ' -f1)" = "$(pin "$1")" ] || { echo "FAIL $1 sha vs pins"; exit 1; }; cp -p "$IN/$1" "$2"; }
for f in ffmpeg-40c412d.tar.gz librga-75af4dd.tar.gz mpp-48962a10.tar.gz mpv-0.41.0.tar.gz; do cp1 "src/$f" "$V/src/video-src/"; done
cp1 src/mpv-mpris-1.2.tar.gz "$V/src/mpris-src/"; cp1 video/ubuntu-stack.tar.gz "$V/"
case "$WHAT" in
  stack) podman run --rm --arch amd64 -e JOBS="${JOBS:-6}" -v "$V/src/video-src:/src:ro,Z" -v "$V:/w:Z" "$CI" bash /w/build-in-container.sh
    python3 -I "$V/pack-stack.py" "$V/ubuntu-stack.tar.gz" "$V/out/stage" "$V/out/h96-video-stack.tar.gz"
    s=$(sha256sum < "$V/out/h96-video-stack.tar.gz" | cut -d' ' -f1); echo "stack $s (pins $(pin video/h96-video-stack.tar.gz))" ;;
  mpris) podman run --rm --arch amd64 -v "$V/src:/src:ro,Z" -v "$V:/w:Z" "$CI" bash /w/build-mpris-in-container.sh
    s=$(sha256sum < "$V/out-mpris/mpris.so" | cut -d' ' -f1); echo "mpris.so $s (pins $(pin video/mpris.so))" ;;
  *) echo "usage: run.sh stack|mpris"; exit 2 ;;
esac
