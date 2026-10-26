#!/bin/bash
# Heavy: WirePlumber 0.5.18 trixie rebuild under qemu in arm64 trixie container. Output $W/wp/out.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"
CI=${H96_DEB_CONTAINER_ARM64:-docker.io/library/debian:trixie}
P=$W/wp; rm -rf "$P"; mkdir -p "$P/src" "$P/out"; cp -p "$H/build-in-container.sh" "$P/"
for f in wireplumber_0.5.18-1.dsc wireplumber_0.5.18-1.debian.tar.xz wireplumber_0.5.18.orig.tar.gz; do
  [ "$(sha256sum < "$IN/src/$f" | cut -d' ' -f1)" = "$(pin "src/$f")" ] || { echo "FAIL $f sha vs pins"; exit 1; }; cp -p "$IN/src/$f" "$P/src/"; done
podman run --rm --arch arm64 -v "$P:/w:Z" "$CI" bash /w/build-in-container.sh
for f in wireplumber_0.5.18-1~h96.1+deb13.1_arm64.deb libwireplumber-0.5-0_0.5.18-1~h96.1+deb13.1_arm64.deb; do
  s=$(sha256sum < "$P/out/$f" | cut -d' ' -f1); [ "$s" = "$(pin "debs/$f")" ] && echo "PASS $f = pins" || echo "DIFF $f ${s:0:8} (pins $(pin "debs/$f" | cut -c1-8))"; done
