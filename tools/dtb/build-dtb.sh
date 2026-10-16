#!/bin/sh
# Build rk3588-h96-max-v58-panthor.dtb from vendor base DTB plus H96 overlay.
# Usage: build-dtb.sh <base.dtb> <out.dtb>
# Reads h96-max-v58.dtso and h96-max-v58.delete from patch/dt (H96_DT_SRC overrides).
# Writes only <out.dtb> and h96-max-v58.dtbo beside it. Never touches /boot.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src=${H96_DT_SRC:-$here/../../patch/dt}
base=${1:?base dtb}
out=${2:?output dtb}
outdir=$(realpath -m "$(dirname "$out")")
case "$outdir/" in /boot/*) echo "refusing to write under /boot" >&2; exit 2;; esac
mkdir -p "$outdir"
out=$outdir/$(basename "$out")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

dtc -@ -q -I dts -O dtb -o "$work/h96-max-v58.dtbo" "$src/h96-max-v58.dtso"
cp "$base" "$work/base-pruned.dtb"
grep -v '^[[:space:]]*\(#\|$\)' "$src/h96-max-v58.delete" | while read -r node prop; do
	fdtput -d "$work/base-pruned.dtb" "$node" "$prop"
done
fdtoverlay -i "$work/base-pruned.dtb" -o "$work/out.dtb" "$work/h96-max-v58.dtbo"
# Round trip through dtc: packs blob (drops overlay slack), fails on malformed tree.
dtc -q -I dtb -O dtb -o "$out" "$work/out.dtb"
cp "$work/h96-max-v58.dtbo" "$outdir/h96-max-v58.dtbo"
sha256sum "$out"
