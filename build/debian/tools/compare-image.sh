#!/bin/bash
# Compare two Debian Edition images: raw areas, partition inventories (path, type, mode, owner, link, xattrs, file sha256).
# Usage: compare-image.sh PUBLISHED.img REBUILT.img OUTDIR   (read only, debugfs; reports differing paths)
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); A=$1; B=$2; O=$3; mkdir -p "$O"
cmp -n 16777216 "$A" "$B" && echo "PASS sectors 0..32767 equal (GPT, loader)" || echo "DIFF sectors 0..32767"
cmp <(tail -c 1048576 "$A") <(tail -c 1048576 "$B") && echo "PASS last 1 MiB equal (backup GPT)" || echo "DIFF last 1 MiB"
for p in p1:16777216 p2:553648128; do n=${p%%:*}; off=${p#*:}
  for s in A B; do i=$A; [ "$s" = B ] && i=$B
    python3 -I "$H/../pipeline/e2inv.py" "$i?offset=$off" "$O/inv-$n-$s.tsv" "$O/xattr-$n-$s.tsv"
    python3 -I "$H/e2sums.py" "$i?offset=$off" "$O/inv-$n-$s.tsv" > "$O/sums-$n-$s.txt"; done
  for k in inv xattr sums; do f=$O/$k-$n; [ "$k" = sums ] && e=txt || e=tsv
    diff "$f-A.$e" "$f-B.$e" > "$f.diff" && echo "PASS $n $k equal" || echo "DIFF $n $k: $(grep -c '^[<>]' "$f.diff") lines ($f.diff)"; done
done
