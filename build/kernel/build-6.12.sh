#!/usr/bin/env bash
# Builds kernel 6.12.69-h96v58-8.0 (Image, System.map, config, modules tarball, DTB, USB OTG overlay).
# Source: armbian/linux-rockchip fa8a79f7 + patch/kernel-6.12 (see build/kernel/source.sh). Toolchain: GCC 16.1.0, binutils 2.47.
# Usage: build-6.12.sh <source> <outdir>   (env JOBS=N default 2, KCONFIG, GADGET_REF, CROSS_COMPILE)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="${1:?source}"
OUT="${2:?outdir}"
BASE="${KCONFIG:-$REPO/config/kernel-6.12.69-h96v58-8.0.config}"
GREF="${GADGET_REF:-$REPO/config/kernel-6.12-usb-gadget.ref}"
CC_PREFIX="${CROSS_COMPILE:-aarch64-linux-gnu-}"
REL_EXPECT="6.12.69-h96v58-8.0"
DTB=rockchip/rk3588-h96-max-v58.dtb
DTBO=rockchip/overlay/rk3588-h96-usb-otg.dtbo
JOBS="${JOBS:-2}"

case "$(realpath -m "$OUT")/" in /boot/*) echo "refusing outdir under /boot" >&2; exit 1;; esac
case "$SRC" in *" "*) echo "kbuild needs a source path without spaces" >&2; exit 1;; esac

# neutral, reproducible banner; SOURCE_DATE_EPOCH fixes __DATE__/__TIME__
export KBUILD_BUILD_USER=builder
export KBUILD_BUILD_HOST=h96-build
export KBUILD_BUILD_TIMESTAMP="Mon Oct 19 00:00:00 UTC 2026"
export KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1792368000
export LOCALVERSION=

MK=(make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CC_PREFIX")

"${CC_PREFIX}gcc" --version | head -1
grep -q '^CONFIG_CC_VERSION_TEXT="aarch64-linux-gnu-gcc (GCC) 16.1.0"$' "$BASE" || { echo "config pin is not GCC 16.1.0" >&2; exit 1; }
grep -q '^SUBLEVEL = 69$' "$SRC/Makefile" || { echo "source is not 6.12.69" >&2; exit 1; }

mkdir -p "$OUT"
cp "$BASE" "$SRC/.config"
"${MK[@]}" olddefconfig
cmp -s "$SRC/.config" "$BASE" || { echo "$(basename "$BASE") not stable under olddefconfig" >&2; exit 1; }
cp "$SRC/.config" "$OUT/config"

"${MK[@]}" -j"$JOBS" Image modules "$DTB" "$DTBO"

REL="$(cat "$SRC/include/config/kernel.release")"
[ "$REL" = "$REL_EXPECT" ] || { echo "release $REL != $REL_EXPECT" >&2; exit 1; }
BANNER="$(grep -a -m1 -o 'Linux version [[:print:]]*' "$SRC/arch/arm64/boot/Image")"
echo "$BANNER"
case "$BANNER" in
	*"($KBUILD_BUILD_USER@$KBUILD_BUILD_HOST)"*"$KBUILD_BUILD_TIMESTAMP"*) ;;
	*) echo "banner not neutral" >&2; exit 1 ;;
esac

# series markers in the built kernel
grep -qw dw_hdmi_qp_i2s_prepare "$SRC/System.map" || { echo "System.map lacks dw_hdmi_qp_i2s_prepare" >&2; exit 1; }
grep -qw vop2_power_domain_ensure_on "$SRC/System.map" || { echo "System.map lacks vop2_power_domain_ensure_on" >&2; exit 1; }
grep -qw dw_hdmi_qp_unmute_work "$SRC/System.map" || { echo "System.map lacks dw_hdmi_qp_unmute_work" >&2; exit 1; }
# static and inlined: checked in source
grep -q vop2_crtc_relatch_cursor "$SRC/drivers/gpu/drm/rockchip/rockchip_drm_vop2.c" || { echo "vop2 source lacks vop2_crtc_relatch_cursor" >&2; exit 1; }
grep -q dw_hdmi_qp_sink_phys_addr "$SRC/drivers/gpu/drm/bridge/synopsys/dw-hdmi-qp.c" || { echo "dw-hdmi-qp source lacks dw_hdmi_qp_sink_phys_addr" >&2; exit 1; }
grep -q eotf_auto "$SRC/drivers/gpu/drm/rockchip/rockchip_drm_vop2.c" || { echo "vop2 source lacks eotf_auto" >&2; exit 1; }
grep -q rga_init_cmd_buf_pools "$SRC/drivers/video/rockchip/rga3/rga_drv.c" || { echo "rga_drv.c lacks rga_init_cmd_buf_pools" >&2; exit 1; }
# dwcmshc skips the PD warning when no power domain is attached
grep -q 'err != -EOPNOTSUPP && err != -ENODEV' "$SRC/drivers/mmc/host/sdhci-of-dwcmshc.c" || { echo "dwcmshc lacks -ENODEV guard" >&2; exit 1; }
# source fixes
P="$SRC/drivers/pci/controller/dwc/pcie-dw-rockchip.c"
grep -q 'if (!rk_pcie->has_ptm)' "$P" || { echo "pcie lacks PTM guard" >&2; exit 1; }
grep -q 'controller off' "$P" || { echo "pcie lacks failed-resume RESET guard" >&2; exit 1; }
grep -q 'stop it before clocks go off' "$P" || { echo "pcie lacks trace stop in suspend" >&2; exit 1; }
[ "$(grep -c 'power = 1;' "$P")" = 2 ] || { echo "pcie lacks power init" >&2; exit 1; }
for f in net/rfkill/rfkill-wlan.c net/rfkill/rfkill-bt.c; do
	grep -q devm_gpiod_get_optional "$SRC/$f" || { echo "$f lacks optional gpiod" >&2; exit 1; }
done
grep -q 'realtek,ledcr' "$SRC/drivers/net/phy/realtek.c" || { echo "realtek.c lacks ledcr" >&2; exit 1; }
grep -q 'dev_info(dev, "pvtm-volt-sel=%d' "$SRC/drivers/soc/rockchip/rockchip_opp_select.c" || { echo "pvtm-volt-sel not info" >&2; exit 1; }
grep -q 'memchr_inv(block, 0, EDID_LENGTH)' "$SRC/drivers/gpu/drm/bridge/synopsys/dw-hdmi-qp.c" || { echo "dw-hdmi-qp lacks 6.1 EDID rules" >&2; exit 1; }
# mmcq: HSQ when CQE is off, mainline CQE enable/halt order
M="$SRC/drivers/mmc/host/sdhci-of-dwcmshc.c"
for p in mmc_hsq_init rk35xx_sdhci_cqe_post_disable rk35xx_sdhci_cqe_pre_enable dwcmshc_request_atomic 'priv->hsq'; do
	grep -q "$p" "$M" || { echo "dwcmshc lacks $p" >&2; exit 1; }
done
if grep -q 'cqe_ops->cqe_wait_for_idle(mmc);' "$M"; then echo "dwcmshc keeps vendor cqe_wait_for_idle in disable" >&2; exit 1; fi
awk '/^config MMC_SDHCI_OF_DWCMSHC$/{p=1;next} p&&/^config /{exit} p' "$SRC/drivers/mmc/host/Kconfig" | grep -q 'select MMC_HSQ' || { echo "Kconfig lacks select MMC_HSQ" >&2; exit 1; }
# vrr: AMD VSDB range, FreeSync SPD infoframe, low-mode guard, module parameter
grep -q parse_amd_vsdb "$SRC/drivers/gpu/drm/rockchip/rockchip_drm_drv.c" || { echo "drm_drv lacks parse_amd_vsdb" >&2; exit 1; }
grep -q dw_hdmi_qp_config_freesync_spd "$SRC/drivers/gpu/drm/bridge/synopsys/dw-hdmi-qp.c" || { echo "dw-hdmi-qp lacks FreeSync SPD" >&2; exit 1; }
for p in dw_hdmi_rockchip_vrr_usable 'module_param(hdmi_freesync'; do
	grep -q "$p" "$SRC/drivers/gpu/drm/rockchip/dw_hdmi_qp-rockchip.c" || { echo "dw_hdmi_qp-rockchip lacks $p" >&2; exit 1; }
done
# dvfs: one MCU stop attempt after a rate change timeout
grep -q 'one stop attempt' "$SRC/drivers/devfreq/rockchip_dmc.c" || { echo "rockchip_dmc lacks single stop attempt" >&2; exit 1; }
if sed -n '/waiting for wait_ctrl.complt_irq times out.\\n", __func__);/,/^\t}$/p' "$SRC/drivers/devfreq/rockchip_dmc.c" | grep -q 'goto out;'; then echo "rockchip_dmc still retries the stop" >&2; exit 1; fi
if grep -q 'rk3588-hdptx-phy-hdmi' "$SRC/drivers/phy/rockchip/phy-rockchip-samsung-hdptx.c"; then echo "hdptx rk3588-hdptx-phy-hdmi compatible still present" >&2; exit 1; fi
# vrr fixes: SPD resend on enable and hotplug, stale SPD cleared, VSDB FreeSync bit and v3 max
Q="$SRC/drivers/gpu/drm/bridge/synopsys/dw-hdmi-qp.c"
[ "$(grep -c 'if (hdmi->freesync_enable)' "$Q")" = 2 ] || { echo "dw-hdmi-qp lacks FreeSync SPD resend" >&2; exit 1; }
grep -q 'dw_hdmi_qp_set_freesync(hdmi->hdmi_qp, false, 0, 0);' "$SRC/drivers/gpu/drm/rockchip/dw_hdmi_qp-rockchip.c" || { echo "glue lacks stale SPD clear" >&2; exit 1; }
for p in '!(db\[5\] & BIT(0))' 'db\[14\] | (db\[15\] & 0x3) << 8' '(db\[21\] & 0x3) << 10'; do
	grep -q "$p" "$SRC/drivers/gpu/drm/rockchip/rockchip_drm_drv.c" || { echo "parse_amd_vsdb lacks $p" >&2; exit 1; }
done
grep -q '^	u16 fs_max;' "$SRC/drivers/gpu/drm/rockchip/rockchip_drm_drv.h" || { echo "fs_max not u16" >&2; exit 1; }
# 0022 fresh EDID per probe, ELD resend
Q="$SRC/drivers/gpu/drm/bridge/synopsys/dw-hdmi-qp.c"
grep -q 'drm_edid = drm_edid_read_ddc(connector, hdmi->ddc);' "$Q" || { echo "dw-hdmi-qp lacks 0022 EDID read" >&2; exit 1; }
grep -q 'eld_changed = memcmp(old_eld, connector->eld, MAX_ELD_BYTES);' "$Q" || { echo "dw-hdmi-qp lacks 0022 ELD resend" >&2; exit 1; }
# HPD disconnect debounce in detect, module parameter
grep -q 'result = dw_hdmi_qp_hpd_debounce(hdmi, result);' "$Q" || { echo "dw-hdmi-qp lacks HPD debounce in detect" >&2; exit 1; }
grep -q '^static uint hpd_debounce_ms = 3000;$' "$Q" || { echo "hpd_debounce_ms default not 3000" >&2; exit 1; }
grep -q '^module_param(hpd_masked_drops, uint, 0444);$' "$Q" || { echo "hpd_masked_drops not read-only parameter" >&2; exit 1; }
grep -qw __param_hpd_masked_drops "$SRC/System.map" || { echo "System.map lacks hpd_masked_drops parameter" >&2; exit 1; }
grep -qw __param_hpd_debounce_ms "$SRC/System.map" || { echo "System.map lacks hpd_debounce_ms parameter" >&2; exit 1; }
# path independence: srctree mapped in debug info
grep -q -- '-ffile-prefix-map=$(abs_srctree)=.' "$SRC/Makefile" || { echo "Makefile lacks file-prefix-map" >&2; exit 1; }

# Panthor uAPI 1.5, fdinfo, profiling knob
D="$SRC/drivers/gpu/drm/panthor/panthor_drv.c"
# patchlevel has no initialiser (0); built value checked below
for p in '^	\.major = 1,$' '^	\.minor = 5,$'; do
	grep -q "$p" "$D" || { echo "panthor_drv.c lacks $p" >&2; exit 1; }
done
for p in 'panthor_ioctl_set_user_mmio_offset' 'panthor_ioctl_bo_set_label' 'DRM_PANTHOR_DEV_QUERY_TIMESTAMP_INFO:' \
	'DRM_PANTHOR_DEV_QUERY_GROUP_PRIORITIES_INFO:' '\.show_fdinfo = panthor_show_fdinfo' 'DEVICE_ATTR_RW(profiling)' '\.dev_groups = panthor_groups'; do
	grep -q "$p" "$D" || { echo "panthor_drv.c lacks $p" >&2; exit 1; }
done
grep -q 'DRM_PANTHOR_GROUP_STATE_INNOCENT' "$SRC/drivers/gpu/drm/panthor/panthor_sched.c" || { echo "sched lacks INNOCENT" >&2; exit 1; }
grep -q 'panthor_heap_pool_size' "$SRC/drivers/gpu/drm/panthor/panthor_heap.c" || { echo "heap lacks pool size" >&2; exit 1; }

# 8.0: stmmac built in; netconsole module, zram backends; pstore uncompressed, buddy hardlockup panic
for s in CONFIG_STMMAC_ETH=y CONFIG_STMMAC_PLATFORM=y CONFIG_DWMAC_ROCKCHIP=y CONFIG_DWMAC_GENERIC=y CONFIG_MII=y \
	CONFIG_RFKILL_RK=y CONFIG_AP6XXX=m CONFIG_DRM_PANTHOR=m CONFIG_USB_UAS=m CONFIG_HID_SONY=m CONFIG_HID_PLAYSTATION=m \
	CONFIG_JOYSTICK_XPAD=m CONFIG_SND_USB_AUDIO=m CONFIG_USB_VIDEO_CLASS=m CONFIG_BINFMT_MISC=y CONFIG_COMPAT=y CONFIG_IO_URING=y \
	CONFIG_DW_WATCHDOG=y CONFIG_CEC_CORE=y CONFIG_DRM_DW_HDMI_CEC=y CONFIG_ROCKCHIP_MPP_SERVICE=y CONFIG_ROCKCHIP_MULTI_RGA=y \
	CONFIG_NETCONSOLE=m CONFIG_PSTORE_CONSOLE=y CONFIG_PSTORE_RAM=y \
	CONFIG_ZRAM=y CONFIG_ZRAM_BACKEND_ZSTD=y CONFIG_ZRAM_BACKEND_LZ4=y CONFIG_ZRAM_BACKEND_LZ4HC=y CONFIG_ZRAM_BACKEND_LZO=y \
	'CONFIG_ZRAM_DEF_COMP="lzo-rle"' CONFIG_HARDLOCKUP_DETECTOR_BUDDY=y CONFIG_BOOTPARAM_HARDLOCKUP_PANIC=y \
	CONFIG_MFD_RK808=y CONFIG_INPUT_RK805_PWRKEY=y CONFIG_PANIC_TIMEOUT=10 CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y \
	CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y CONFIG_USB_GADGET=y CONFIG_USB_CONFIGFS=y CONFIG_USB_LIBCOMPOSITE=y \
	CONFIG_USB_DWC3_DUAL_ROLE=y \
	CONFIG_SCHED_CLASS_EXT=y CONFIG_EXT_GROUP_SCHED=y CONFIG_HID_BPF=y CONFIG_ZRAM_MULTI_COMP=y CONFIG_LIST_HARDENED=y \
	CONFIG_RANDOM_KMALLOC_CACHES=y CONFIG_SLAB_BUCKETS=y CONFIG_MMC_HSQ=y CONFIG_MMC_CQHCI=y CONFIG_MMC_SDHCI_OF_DWCMSHC=y \
	CONFIG_UCLAMP_TASK=y CONFIG_UCLAMP_TASK_GROUP=y CONFIG_PM_DEVFREQ=y CONFIG_PM_DEVFREQ_EVENT=y CONFIG_ARM_ROCKCHIP_DMC_DEVFREQ=y \
	CONFIG_DEVFREQ_EVENT_ROCKCHIP_DFI=y CONFIG_ROCKCHIP_SYSTEM_MONITOR=y CONFIG_ROCKCHIP_OPP=y CONFIG_DEVFREQ_GOV_PERFORMANCE=y \
	CONFIG_DEVFREQ_GOV_USERSPACE=y CONFIG_DEVFREQ_THERMAL=y CONFIG_DRM_ROCKCHIP=y CONFIG_ROCKCHIP_DW_HDMI_QP=y CONFIG_ROCKCHIP_VOP2=y \
	CONFIG_DEBUG_FS=y CONFIG_MODVERSIONS=y CONFIG_MODULE_ALLOW_BTF_MISMATCH=y; do
	grep -qx "$s" "$SRC/.config" || { echo "config lacks $s" >&2; exit 1; }
done
# only the power key from the RK808 family; rk806 cells are pinctrl, pwrkey, regulator
for s in PSTORE_COMPRESS PSTORE_PMSG PSTORE_FTRACE PSTORE_BOOT_LOG NETCONSOLE_DYNAMIC \
	REGULATOR_RK808 COMMON_CLK_RK808 PINCTRL_RK805 RTC_DRV_RK808 SND_SOC_RK817 DRM_PANFROST DRM_LIMA \
	MALI_BIFROST MALI_VALHALL MALI_MIDGARD MALI400 RT_GROUP_SCHED MEMCG_V1 CPUSETS_V1 PSTORE_COMPRESS BUG_ON_DATA_CORRUPTION; do
	grep -qx "# CONFIG_$s is not set" "$SRC/.config" || { echo "CONFIG_$s not off" >&2; exit 1; }
done
# front power button driver built in (rk806 creates the rk805-pwrkey cell)
grep -qw rk805_pwrkey_probe "$SRC/System.map" || { echo "System.map lacks rk805_pwrkey_probe" >&2; exit 1; }
# 8.0: ethernet driver built in
for f in stmmac_dvr_probe rk_gmac_probe; do
	grep -qw "$f" "$SRC/System.map" || { echo "System.map lacks $f" >&2; exit 1; }
done
# built-in symbols of each new feature (HSQ: dwcmshc request path)
for f in dwcmshc_request_atomic dwcmshc_request_done rk35xx_sdhci_cqe_pre_enable rk35xx_sdhci_cqe_post_disable \
	mmc_hsq_init mmc_hsq_finalize_request cqhci_init dw_hdmi_qp_set_freesync rockchip_dmcfreq_wait_complete \
	ext_sched_class dispatch_hid_bpf_device_event random_kmalloc_seed kmem_buckets_create __list_add_valid_or_report; do
	grep -qw "$f" "$SRC/System.map" || { echo "System.map lacks $f" >&2; exit 1; }
done
grep -q '__param_hdmi_freesync' "$SRC/System.map" || { echo "System.map lacks hdmi_freesync parameter" >&2; exit 1; }
# 8.0: USB device mode kept: gadget, configfs and functions, dwc3 dual role
G='^CONFIG_USB_(GADGET|LIBCOMPOSITE|CONFIGFS[A-Z0-9_]*|F_[A-Z0-9_]+|DWC3_DUAL_ROLE)='
diff "$GREF" <(grep -E "$G" "$SRC/.config") || { echo "gadget set differs from reference" >&2; exit 1; }
grep -qw configfs_composite_bind "$SRC/System.map" || { echo "System.map lacks configfs_composite_bind" >&2; exit 1; }
# built panthor.ko: drm_driver version 1.5.0 (pahole offsets, bytes from the symbol's section), symbols, fdinfo strings
KO="$SRC/drivers/gpu/drm/panthor/panthor.ko"
OFFS="$(pahole -C drm_driver "$KO" | awk '$NF=="*/" && ($2=="major;"||$2=="minor;"||$2=="patchlevel;") {print $2, $(NF-2)}' | tr -d ';')"
[ "$(echo "$OFFS" | wc -l)" = 3 ] || { echo "pahole drm_driver offsets: $OFFS" >&2; exit 1; }
# shellcheck disable=SC2086
VER="$(python3 -I - "$KO" $OFFS <<'PY'
import struct, sys
ko = sys.argv[1]
off = dict(zip(sys.argv[2::2], map(int, sys.argv[3::2])))
b = open(ko, 'rb').read()
shoff, = struct.unpack_from('<Q', b, 0x28)
shentsize, shnum = struct.unpack_from('<HH', b, 0x3a)
sh = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)]
symtab = next(s for s in sh if s[1] == 2)
strtab = sh[symtab[6]]
for i in range(symtab[5] // 24):
	name, info, other, ndx, value, size = struct.unpack_from('<IBBHQQ', b, symtab[4] + i * 24)
	n = b[strtab[4] + name:b.index(b'\0', strtab[4] + name)].decode()
	if n == 'panthor_drm_driver':
		base = sh[ndx][4] + value
		print('.'.join(str(struct.unpack_from('<i', b, base + off[k])[0]) for k in ('major', 'minor', 'patchlevel')))
		break
PY
)"
[ "$VER" = 1.5.0 ] || { echo "panthor.ko drm_driver version '$VER' != 1.5.0" >&2; exit 1; }
echo "panthor.ko drm_driver version $VER"
KSYMS="$("${CC_PREFIX}nm" "$KO")"
for f in panthor_ioctl_set_user_mmio_offset panthor_ioctl_bo_set_label panthor_show_fdinfo dev_attr_profiling; do
	grep -qw "$f" <<<"$KSYMS" || { echo "panthor.ko lacks $f" >&2; exit 1; }
done
for p in 'drm-engine-panthor:' 'drm-cycles-panthor:' 'drm-maxfreq-panthor:' 'drm-curfreq-panthor:' '%s-%s-%s:'; do
	grep -a -q -F "$p" "$KO" || { echo "panthor.ko lacks fdinfo string $p" >&2; exit 1; }
done
# DTB: 6.1 ramoops layout, no eMMC CQE, no VOP DVFS
DTS="$(mktemp)"
"$SRC/scripts/dtc/dtc" -q -I dtb -O dts "$SRC/arch/arm64/boot/dts/$DTB" > "$DTS"
awk '/ramoops@110000 \{/{p=1} p{print} p&&/\};/{exit}' "$DTS" | tr -d '\t' > "$DTS.ramoops"
for l in 'reg = <0x00 0x110000 0x00 0xf0000>;' 'record-size = <0x20000>;' 'console-size = <0x80000>;' \
	'pmsg-size = <0x50000>;' 'ftrace-size = <0x00>;'; do
	grep -qxF "$l" "$DTS.ramoops" || { echo "ramoops lacks: $l" >&2; exit 1; }
done
if grep -q boot-log "$DTS.ramoops"; then echo "ramoops has boot-log" >&2; exit 1; fi
# DTB: eMMC CQE off (HSQ path), VOP DVFS absent, DDR DVFS on with 800 MB/s floor
if awk '/mmc@fe2e0000 \{/{p=1} p{print} p&&/\};/{exit}' "$DTS" | grep -q supports-cqe; then echo "eMMC CQE on" >&2; exit 1; fi
if awk '/vop@fdd90000 \{/{p=1} p{print} p&&/ports \{/{exit}' "$DTS" | grep -q 'operating-points-v2\|vop-supply\|aclk-reset-mode-rates'; then echo "VOP DVFS present" >&2; exit 1; fi
for p in vop-bw-dmc-level vop-frame-bw-dmc-level; do
	awk '/^\tdmc \{/{p=1} p{print} p&&/^\t\};/{exit}' "$DTS" | grep -qF "$p = <0x320 0xbb7 0x04 0xbb8 0x1869f 0x08>;" || { echo "dmc $p not 800/3000" >&2; exit 1; }
done
# base DTB host only on all three dwc3; overlay switches OTG0 to otg
[ "$(grep -c 'dr_mode = "host";' "$DTS")" = 3 ] || { echo "base DTB not host-only x3" >&2; exit 1; }
"$SRC/scripts/dtc/dtc" -q -I dtb -O dts "$SRC/arch/arm64/boot/dts/$DTBO" > "$DTS.o"
grep -q 'target = <0xffffffff>;' "$DTS.o" && grep -q 'dr_mode = "otg";' "$DTS.o" && grep -q 'usbdrd_dwc3_0' "$DTS.o" || { echo "overlay content" >&2; exit 1; }
rm -f "$DTS.o"
for n in 'dmc \{' 'dfi@fe060000 \{'; do
	awk "/^\t$n/{p=1} p{print} p&&/^\t\};/{exit}" "$DTS" | grep -qx '\s*status = "okay";' || { echo "node $n not okay" >&2; exit 1; }
done
awk '/^\tdmc \{/{p=1} p{print} p&&/^\t\};/{exit}' "$DTS" | grep -q 'delayed-freq-scaling' || { echo "dmc lacks delayed-freq-scaling" >&2; exit 1; }
# no absolute source path in Image or vmlinux debug strings
SRCABS="$(cd "$SRC" && pwd -P)"
if grep -a -q -F "$SRCABS" "$SRC/arch/arm64/boot/Image"; then echo "Image carries $SRCABS" >&2; exit 1; fi
n="$(grep -a -c -F "$SRCABS" "$SRC/vmlinux" || true)"
[ "$n" = 0 ] || { echo "vmlinux carries $SRCABS ($n lines)" >&2; exit 1; }
# DTB: rfkill gpiod property names, no legacy names left
for p in 'WIFI,poweren-gpios' 'WIFI,host_wake-gpios' 'BT,reset-gpios' 'BT,wake-gpios' 'BT,wake_host-gpios' 'uart_rts-gpios'; do
	grep -q "^\s*$p = " "$DTS" || { echo "DTB lacks $p" >&2; exit 1; }
done
if grep -qE '^\s*(WIFI,poweren_gpio|WIFI,host_wake_irq|BT,reset_gpio|BT,wake_gpio|BT,wake_host_irq|uart_rts_gpios) = ' "$DTS"; then echo "DTB keeps legacy rfkill names" >&2; exit 1; fi
# DTB: no wdt CRU reset; standby IRQs of remotectl kept
CRUPH="$(awk '/^\tclock-controller@fd7c0000 \{/{p=1} p&&/phandle = /{print $3; exit}' "$DTS" | tr -d '<>;')"
[ -n "$CRUPH" ] || { echo "cru phandle not found" >&2; exit 1; }
if awk '/^\twatchdog@feaf0000 \{/{p=1} p{print} p&&/^\t\};/{exit}' "$DTS" | grep -q 'resets = '; then echo "wdt has resets (watchdog must keep running at power off)" >&2; exit 1; fi
awk '/^\trockchip-suspend \{/{p=1} p{print} p&&/^\t\};/{exit}' "$DTS" | grep -qx '\s*rockchip,virtual-poweroff-irqs = <0x179 0x178>;' || { echo "virtual-poweroff-irqs not 377 376" >&2; exit 1; }
awk '/^\trockchip-suspend \{/{p=1} p{print} p&&/^\t\};/{exit}' "$DTS" | grep -qx '\s*rockchip,wakeup-config = <0x101>;' || { echo "wakeup-config not 0x101" >&2; exit 1; }
# DTB: no wl_reg_on hog
if grep -q 'wl_reg_on_hog' "$DTS"; then echo "DTB keeps wl_reg_on_hog" >&2; exit 1; fi
# DTB: jack LED pattern, no Android vendor storage, OP-TEE off
grep -qx '\s*realtek,ledcr = <0xc160>;' "$DTS" || { echo "DTB lacks realtek,ledcr" >&2; exit 1; }
grep -qx '\s*realtek,eeelcr = <0x08>;' "$DTS" || { echo "DTB lacks realtek,eeelcr" >&2; exit 1; }
if grep -q 'vendor-storage' "$DTS"; then echo "DTB keeps vendor-storage" >&2; exit 1; fi
awk '/^\t\toptee \{/{p=1} p{print} p&&/^\t\t\};/{exit}' "$DTS" | grep -qx '\s*status = "disabled";' || { echo "optee not disabled" >&2; exit 1; }
rm -f "$DTS" "$DTS.ramoops"

cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"
cp "$SRC/System.map" "$OUT/System.map-$REL"
cp "$SRC/arch/arm64/boot/dts/$DTB" "$OUT/rk3588-h96-max-v58.dtb"
cp "$SRC/arch/arm64/boot/dts/$DTBO" "$OUT/rk3588-h96-usb-otg.dtbo"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
"${MK[@]}" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install
rm -f "$STAGE/lib/modules/$REL/build" "$STAGE/lib/modules/$REL/source"
# modules expected from config (=m): Wi-Fi, netconsole, GPU, USB classes, pads
for m in bcmdhd netconsole panthor uas hid-sony hid-playstation xpad snd-usb-audio uvcvideo; do
	find "$STAGE/lib/modules/$REL" -name "$m.ko*" | grep -q . || { echo "missing $m.ko" >&2; exit 1; }
done
# trim: PCI cards, SDIO Wi-Fi, IIO chips, camera sensors gone; 8.0: no Panfrost/Lima, stmmac built in
for m in r8169 iwlwifi aic8800_fdrv r8723bs bmp280 ov5640 panfrost lima stmmac stmmac-platform dwmac-rockchip dwmac-generic mii; do
	if find "$STAGE/lib/modules/$REL" -name "$m.ko*" | grep -q .; then echo "trimmed module $m.ko present" >&2; exit 1; fi
done
if find "$STAGE/lib/modules/$REL" -name 'mali_kbase*.ko*' | grep -q .; then echo "kbase module present" >&2; exit 1; fi
PKO="$(find "$STAGE/lib/modules/$REL" -name 'panthor.ko*')"
grep -q "vermagic=$REL SMP" <<<"$("${CC_PREFIX}readelf" -p .modinfo "$PKO")" || { echo "panthor.ko vermagic not $REL" >&2; exit 1; }
echo "modules: $(find "$STAGE/lib/modules/$REL" -name '*.ko' | wc -l)"
tar -C "$STAGE/lib/modules" --owner=0 --group=0 --numeric-owner --sort=name \
	--mtime="@$SOURCE_DATE_EPOCH" -czf "$OUT/modules-$REL.tar.gz" "$REL"
(cd "$OUT" && sha256sum Image "modules-$REL.tar.gz" config "System.map-$REL" rk3588-h96-max-v58.dtb rk3588-h96-usb-otg.dtbo > SHA256SUMS)
cat "$OUT/SHA256SUMS"
