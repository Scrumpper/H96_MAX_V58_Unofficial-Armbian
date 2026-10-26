#!/usr/bin/env bash
# Builds kernel 6.1.172-h96v58-8.0 (Image, System.map, config, modules tarball); DTB comes from tools/dtb/build-dtb.sh.
# Source: armbian/linux-rockchip 44bbd021 + patch/kernel-6.1 (see build/kernel/source.sh). Toolchain: GCC 16.1.0, binutils 2.47.
# Usage: build-6.1.sh <source> <outdir>   (env JOBS=N default 2, KCONFIG, CROSS_COMPILE)
# Optional env: KCFLAGS (passed to make, compiler probe first; unset = published build), BUILD_NUM (banner #N, default 1).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="${1:?source}"
OUT="${2:?outdir}"
BASE="${KCONFIG:-$REPO/config/kernel-6.1.172-h96v58-8.0.config}"
PATCHES="$REPO/patch/kernel-6.1"
CC_PREFIX="${CROSS_COMPILE:-aarch64-linux-gnu-}"
REL_EXPECT="6.1.172-h96v58-8.0"
JOBS="${JOBS:-2}"
KCF="${KCFLAGS:-}"
unset KCFLAGS

case "$(realpath -m "$OUT")/" in /boot/*) echo "refusing outdir under /boot" >&2; exit 1;; esac
case "$SRC" in *" "*) echo "kbuild needs a source path without spaces" >&2; exit 1;; esac

# neutral, reproducible banner; SOURCE_DATE_EPOCH fixes __DATE__/__TIME__
export KBUILD_BUILD_USER=builder
export KBUILD_BUILD_HOST=h96-build
export KBUILD_BUILD_TIMESTAMP="Sat Oct 17 00:00:00 UTC 2026"
export KBUILD_BUILD_VERSION="${BUILD_NUM:-1}"
export SOURCE_DATE_EPOCH=1792195200
export LOCALVERSION=

case "$KBUILD_BUILD_VERSION" in ''|*[!0-9]*) echo "BUILD_NUM not a number" >&2; exit 1;; esac
MK=(make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CC_PREFIX")
[ -z "$KCF" ] || MK+=(KCFLAGS="$KCF")

"${CC_PREFIX}gcc" --version | head -1
if [ -n "$KCF" ]; then
	echo "KCFLAGS=$KCF"
	# shellcheck disable=SC2086 # KCF may hold several flags
	"${CC_PREFIX}gcc" $KCF -mgeneral-regs-only -x c -c -o /dev/null /dev/null || { echo "compiler rejects $KCF" >&2; exit 1; }
fi
grep -q '^CONFIG_CC_VERSION_TEXT="aarch64-linux-gnu-gcc (GCC) 16.1.0"$' "$BASE" || { echo "config pin is not GCC 16.1.0" >&2; exit 1; }

# last three series patches must already be in the tree
shopt -s nullglob
for p in "$PATCHES"/00{18,19,20}-*.patch; do
	patch -d "$SRC" -p1 -R --dry-run -s -f < "$p" >/dev/null || { echo "patch not in $SRC: $(basename "$p")" >&2; exit 1; }
	echo "applied: $(basename "$p")"
done

# release string comes from config LOCALVERSION
grep -qx 'CONFIG_LOCALVERSION="-h96v58-8.0"' "$BASE" || { echo "config LOCALVERSION not -h96v58-8.0" >&2; exit 1; }

mkdir -p "$OUT"
cp "$BASE" "$SRC/.config"
"${MK[@]}" olddefconfig
cmp -s "$SRC/.config" "$BASE" || { echo "$(basename "$BASE") not stable under olddefconfig" >&2; exit 1; }
cp "$SRC/.config" "$OUT/config"

"${MK[@]}" -j"$JOBS" Image modules

REL="$(cat "$SRC/include/config/kernel.release")"
[ "$REL" = "$REL_EXPECT" ] || { echo "release $REL != $REL_EXPECT" >&2; exit 1; }
BANNER="$(grep -a -m1 -o 'Linux version [[:print:]]*' "$SRC/arch/arm64/boot/Image")"
echo "$BANNER"
case "$BANNER" in
	*"($KBUILD_BUILD_USER@$KBUILD_BUILD_HOST)"*"$KBUILD_BUILD_TIMESTAMP"*) ;;
	*) echo "banner not neutral" >&2; exit 1 ;;
esac
case "$BANNER" in *t4*|*h96v58v*|*-r[0-9]*) echo "banner carries an internal label" >&2; exit 1 ;; esac

# series markers in the built kernel
grep -qw dw_hdmi_qp_i2s_prepare "$SRC/System.map" || { echo "System.map lacks dw_hdmi_qp_i2s_prepare" >&2; exit 1; }
grep -q eotf_auto "$SRC/drivers/gpu/drm/rockchip/rockchip_drm_vop2.c" || { echo "vop2 source lacks eotf_auto" >&2; exit 1; }
grep -q rga_init_cmd_buf_pools "$SRC/drivers/video/rockchip/rga3/rga_drv.c" || { echo "rga_drv.c lacks rga_init_cmd_buf_pools" >&2; exit 1; }

cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"
cp "$SRC/System.map" "$OUT/System.map-$REL"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
"${MK[@]}" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install
rm -f "$STAGE/lib/modules/$REL/build" "$STAGE/lib/modules/$REL/source"
for m in panfrost lima panthor uas hid-sony; do
	find "$STAGE/lib/modules/$REL" -name "$m.ko" | grep -q . || { echo "missing $m.ko" >&2; exit 1; }
done
if find "$STAGE/lib/modules/$REL" -name 'mali_kbase*.ko' | grep -q .; then echo "kbase module present" >&2; exit 1; fi
echo "modules: $(find "$STAGE/lib/modules/$REL" -name '*.ko' | wc -l)"
tar -C "$STAGE/lib/modules" --owner=0 --group=0 --numeric-owner --sort=name \
	--mtime="@$SOURCE_DATE_EPOCH" -czf "$OUT/modules-$REL.tar.gz" "$REL"
(cd "$OUT" && sha256sum Image "modules-$REL.tar.gz" config "System.map-$REL" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
