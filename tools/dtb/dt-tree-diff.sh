#!/bin/sh
# Tree-diff gate: decompile reference and candidate DTB with dtc -s and compare.
# Usage: dt-tree-diff.sh <reference.dtb> <candidate.dtb> [outdir]
# Pass: diff empty, or only phandle renumbering (verified by node path) plus
# lines listed in gate/allowed-residual.txt. Read-only on both inputs.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ref=${1:?reference dtb}
cand=${2:?candidate dtb}
out=$(realpath -m "${3:-$(mktemp -d)}")
# refuse /boot itself and anything below it
case "$out" in /boot|/boot/*) echo "refusing to write under /boot" >&2; exit 2;; esac
mkdir -p "$out"
dtc -q -I dtb -O dts -s -o "$out/reference.sorted.dts" "$ref"
dtc -q -I dtb -O dts -s -o "$out/candidate.sorted.dts" "$cand"
sha256sum "$ref" "$cand"
if diff -u "$out/reference.sorted.dts" "$out/candidate.sorted.dts" > "$out/raw.diff"; then
	echo "raw diff: empty"
	echo "GATE: PASS (empty diff)"
	exit 0
fi
echo "raw diff: $(grep -c '^[-+][^-+]' "$out/raw.diff") changed lines, saved to $out/raw.diff"
python3 -I "$here/gate/dt-tree-diff.py" "$out/reference.sorted.dts" \
	"$out/candidate.sorted.dts" "$here/gate/allowed-residual.txt"
