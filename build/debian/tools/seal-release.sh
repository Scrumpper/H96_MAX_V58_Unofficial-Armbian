#!/bin/bash
# Seal pipeline output into release folder with public names; build/ubuntu/stage-and-zip.py --edition=debian reads it.
# Usage: seal-release.sh RELEASE_DIR FLASHER_DIR [VER]   (FLASHER_DIR: flash.py, MiniLoaderAll.bin, FLASHER-SHA256SUMS.txt)
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"
REL=${1:?release dir}; FL=${2:?flasher dir}; VER=${3:-8.0}; PUB="H96-MAX-V58_Unofficial-Armbian_v$VER-debian"
xz_rec=$(cut -d' ' -f1 "$OUT/$NAME.img.xz.sha256"); img_rec=$(cut -d' ' -f1 "$OUT/$NAME.img.sha256")
[ "$(sha256sum < "$OUT/$NAME.img.xz" | cut -d' ' -f1)" = "$xz_rec" ] || { echo "FAIL $NAME.img.xz != its sidecar"; exit 1; }
[ "$(xz -dc "$OUT/$NAME.img.xz" | sha256sum | cut -d' ' -f1)" = "$img_rec" ] || { echo "FAIL xz -dc sha != $NAME.img.sha256"; exit 1; }
mkdir -p "$REL"
[ "$NAME" = "$PUB" ] && [ "$(realpath "$OUT")" = "$(realpath "$REL")" ] || cp "$OUT/$NAME.img.xz" "$REL/$PUB.img.xz"
echo "$xz_rec  $PUB.img.xz" > "$REL/$PUB.img.xz.sha256"; echo "$img_rec  $PUB.img" > "$REL/$PUB.img.sha256"
cp "$REL/$PUB.img.xz.sha256" "$REL/SHA256SUMS"
for f in flash.py MiniLoaderAll.bin FLASHER-SHA256SUMS.txt; do cp "$FL/$f" "$REL/$f"; done
(cd "$REL" && sha256sum -c FLASHER-SHA256SUMS.txt >/dev/null) || { echo "FAIL flasher files"; exit 1; }
echo "sealed $NAME -> $REL/$PUB.img.xz ($xz_rec)"; cat "$REL/SHA256SUMS"
