#!/bin/bash
# Packaging smoke test: runs build/build-kernel-debs.sh on placeholder inputs.
# Usage: kernel-debs-smoke.sh OUTDIR  (non-root; resulting debs are for lintian only, not installable)
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "${1:?outdir}")
case "$out/" in /boot/*) echo "refusing path under /boot: $out" >&2; exit 2;; esac
krel=${KREL:-6.1.172-h96v58-8.0}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
in=$work/in
mkdir -p "$in/mods/$krel/kernel"
printf 'placeholder kernel image\n' > "$in/Image"
printf '0000000000000000 T _text\n' > "$in/System.map"
printf 'CONFIG_LOCALVERSION="-%s"\n' "${krel#*-}" > "$in/config"
printf 'kernel/placeholder.ko\n' > "$in/mods/$krel/modules.order"
printf 'placeholder module\n' > "$in/mods/$krel/kernel/placeholder.ko"
tar -czf "$in/modules.tar.gz" -C "$in/mods" "$krel"
# board overlay stands in for full DTB; vendor base DTB is not in repo
dtc -@ -q -I dts -O dtb -o "$in/board.dtb" "$repo/patch/dt/h96-max-v58.dtso"
IMAGE=$in/Image SYSMAP=$in/System.map CONFIG=$in/config MODTAR=$in/modules.tar.gz DTB=$in/board.dtb \
  MAINT=${MAINT:-"Scrumpper <190908034+Scrumpper@users.noreply.github.com>"} KREL=$krel PIN=0 HEAVY=0 WORK=$work/build bash "$repo/build/build-kernel-debs.sh" "$out"
