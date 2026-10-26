#!/usr/bin/env bash
# Builds the four v8.0 kernel debs from kernel build outputs; builder pins (PIN=1) check every input sha256.
# Usage: debs.sh <outdir>   env K612 = build-6.12.sh outdir, K61 = build-6.1.sh outdir, DTB61 = 6.1 DTB from tools/dtb/build-dtb.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:?outdir}"
: "${K612:?K612 = build-6.12.sh outdir}" "${K61:?K61 = build-6.1.sh outdir}" "${DTB61:?DTB61 = 6.1 DTB}"
B="$REPO/build/build-kernel-debs.sh"
MAINT='Scrumpper <190908034+Scrumpper@users.noreply.github.com>'
# builder default SOURCE_DATE_EPOCH (1791244800) gives the published debs
unset SOURCE_DATE_EPOCH PKGVER DTB_PKGVER KCFLAGS MODPREFIX

# 6.12 default kernel: kernel and dtb debs 8.0.0~r23, dtb deb carries USB OTG overlay
KREL=6.12.69-h96v58-8.0 PIN=1 MAINT="$MAINT" \
	IMAGE="$K612/Image" SYSMAP="$K612/System.map-6.12.69-h96v58-8.0" CONFIG="$K612/config" \
	MODTAR="$K612/modules-6.12.69-h96v58-8.0.tar.gz" DTB="$K612/rk3588-h96-max-v58.dtb" \
	DTBO="$K612/rk3588-h96-usb-otg.dtbo" bash "$B" "$OUT"

# 6.1 fallback: kernel deb 8.0.0~r11, dtb deb 8.0.0~r12
KREL=6.1.172-h96v58-8.0 PIN=1 MAINT="$MAINT" \
	IMAGE="$K61/Image" SYSMAP="$K61/System.map-6.1.172-h96v58-8.0" CONFIG="$K61/config" \
	MODTAR="$K61/modules-6.1.172-h96v58-8.0.tar.gz" DTB="$DTB61" bash "$B" "$OUT"

# published sha256 of the four debs
(cd "$OUT" && sha256sum -c - <<'SUMS'
b1469c6501b71c1100b558bb82fdb2a7c8d7a52f6772c96390d8ef578f115894  h96-kernel-6.12.69-h96v58-8.0_8.0.0~r23_arm64.deb
b42bca1ce3b65b058172633c0cca4facc39baa0d199ceaac4376212db9965e26  h96-dtb-6.12.69-h96v58-8.0_8.0.0~r23_arm64.deb
cd620587d47a675232d260891d719e02afd5d8e7adecda1fbcf4f04e31947746  h96-kernel-6.1.172-h96v58-8.0_8.0.0~r11_arm64.deb
a62b4d0d5cd10ec2b305fbd5e167d6aa0e4dd5cd751cf5d9ff842a3a6bb6ba50  h96-dtb-6.1.172-h96v58-8.0_8.0.0~r12_arm64.deb
SUMS
)
