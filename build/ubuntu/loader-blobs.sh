#!/bin/bash
# Extract loader blobs for set A1 from published v8.0 image into DIR/runbook-files (loader-pin.py checks length + sha).
# Usage: loader-blobs.sh V8_IMG DIR
set -euo pipefail
[ $# = 2 ] || { sed -n 2,3p "$0"; exit 2; }
I=$1; D=$2/runbook-files; mkdir -p "$D"
x() { dd if="$I" of="$D/$1" bs=512 skip="$2" count="$3" status=none; }
x old-idbloader.img 64 556
x A1-u-boot.itb 16384 2638
x old-u-boot.itb 20480 2638
cat > "$D/SHA256SUMS" <<'S'
05dca3609fb4698afc67ee9ffe2ca8d1919cd4c4a5b7772f61bd566227e0686d  A1-u-boot.itb
5b26987186343051b3a2a3f12f6710e4f12e5d8629eba534e642b90b5816e8d4  old-idbloader.img
5cd0e166332355fcf4c540b3e16a4655452b2ab3803499f99c0f7fbde4d0ef0d  old-u-boot.itb
S
(cd "$D" && sha256sum -c SHA256SUMS)
