#!/bin/bash
# shellcheck disable=SC2034  # SHA_* pins read through ${!want}
# Builds h96-kernel-<krel> and h96-dtb-<krel> debs from pinned kernel build outputs.
# Payload stages into /usr/lib/h96-kernel/<krel>/ and /usr/lib/modules/<krel>/; nothing under /boot.
# Usage: MAINT='Name <email>' IMAGE=.. SYSMAP=.. CONFIG=.. MODTAR=.. DTB=.. build-kernel-debs.sh [OUTDIR]
# KCFLAGS: flags the kernel was compiled with; recorded in kernel package changelog only. Value other than
# KCFLAGS_PIN needs PIN=0 and PKGVER above default, so no earlier version gets second content.
# Re-runnable; output depends only on inputs and SOURCE_DATE_EPOCH.
set -euo pipefail

KREL=${KREL:-6.1.172-h96v58-8.0}
# default versions belong to pinned inputs and maintainer scripts below; new content needs a new version
# kernel and DTB debs carry own versions (DTB content changes less often). Explicit PKGVER sets both.
[ -z "${PKGVER:-}" ] || DTB_PKGVER=${DTB_PKGVER:-$PKGVER}
PKGVER_DEF=8.0.0~r11
PKGVER_GIVEN=${PKGVER:-}
PKGVER=${PKGVER:-$PKGVER_DEF}
DTB_PKGVER=${DTB_PKGVER:-8.0.0~r10}
MODPREFIX=${MODPREFIX:-/usr/lib/modules}
STAGEPREFIX=/usr/lib/h96-kernel
FDTFILE=${FDTFILE:-rockchip/rk3588-h96-max-v58-panthor.dtb}
# Maintainer field; required, no default
MAINT=${MAINT:-}
# KCFLAGS of pinned Image build; other KCFLAGS mean new content (PIN=0, own PKGVER)
KCFLAGS_PIN=""
KCFLAGS=${KCFLAGS:-$KCFLAGS_PIN}
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1791244800}

# inputs: kernel Image, System.map, .config, modules tarball (<krel>/kernel/...), board DTB
IMAGE=${IMAGE:-}
SYSMAP=${SYSMAP:-}
CONFIG=${CONFIG:-}
MODTAR=${MODTAR:-}
DTB=${DTB:-}

# pins: 8.0 kernel build outputs and overlay DTB; PIN=0 skips pins for other inputs
PIN=${PIN:-1}
SHA_IMAGE=6fbe2fee96d1dbc920d7957877ccb2b140c32a927d647615d877a840af64e8bc
SHA_SYSMAP=6d8e615f4e8376088bd9145a59c9ae3f48f3715a287826ae8ff19c7ce430f976
SHA_CONFIG=b94f0167acfc532645470821d7acf56360aaf8a93c6fd513406328083f633e19
SHA_MODTAR=a9c2f2c972697937d23a160daff70b021cc7e22c154ddd1a407d351babce3e49
SHA_DTB=4891450dbe1ffee7257e268ecca06c91857623a6025ff6a79ba02e31d2363253

OUT=${1:-out}
if [ -z "${WORK:-}" ]; then WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; fi
# HEAVY=1 runs dpkg-deb under flock HEAVY_LOCK and systemd-run MemoryMax=HEAVY_MEM
HEAVY=${HEAVY:-0}
HEAVY_LOCK=${HEAVY_LOCK:-}
HEAVY_MEM=${HEAVY_MEM:-}

die() { echo "ERROR: $*" >&2; exit 1; }
heavy() {
    if [ "$HEAVY" = 1 ]; then
        flock "$HEAVY_LOCK" systemd-run --user --scope --quiet -p "MemoryMax=$HEAVY_MEM" nice -n 10 "$@"
    else
        "$@"
    fi
}

[ "$(id -u)" != 0 ] || die "run as normal user; dpkg-deb --root-owner-group sets root ownership"
for p in "$OUT" "$WORK"; do
    case "$(realpath -m "$p")/" in /boot/*) die "refusing path under /boot: $p";; esac
done
command -v dpkg-deb >/dev/null || die "dpkg-deb missing"
# names joined into payload paths: no traversal, MODPREFIX absolute
case "$KREL" in ''|*/*|*..*) die "bad KREL: $KREL";; esac
case "$FDTFILE" in ''|/*|*..*) die "bad FDTFILE: $FDTFILE";; esac
case "$MODPREFIX" in ''|[!/]*|*..*) die "bad MODPREFIX: $MODPREFIX";; esac
case "$KCFLAGS" in *[!-A-Za-z0-9=.,+_\ ]*) die "KCFLAGS has characters outside [-A-Za-z0-9=.,+_ ]: $KCFLAGS";; esac
if [ "$KCFLAGS" != "$KCFLAGS_PIN" ]; then
    [ "$PIN" = 0 ] || die "KCFLAGS '$KCFLAGS' differs from pinned build '$KCFLAGS_PIN': set PIN=0 and new PKGVER"
    if [ -z "$PKGVER_GIVEN" ] || ! dpkg --validate-version "$PKGVER" 2>/dev/null ||
        ! dpkg --compare-versions "$PKGVER" gt "$PKGVER_DEF"; then
        die "KCFLAGS '$KCFLAGS' needs explicit PKGVER above $PKGVER_DEF"
    fi
fi
case "$MAINT" in
    '') die "set MAINT='Name <email>'";;
    *' <'*@*'>') ;;
    *) die "MAINT not in 'Name <email>' form: $MAINT";;
esac
if [ "$HEAVY" = 1 ]; then
    [ -n "$HEAVY_LOCK" ] && [ -n "$HEAVY_MEM" ] || die "HEAVY=1 needs HEAVY_LOCK and HEAVY_MEM"
fi

for v in IMAGE SYSMAP CONFIG MODTAR DTB; do [ -n "${!v}" ] && [ -f "${!v}" ] || die "$v not set or not found: ${!v}"; done
if [ "$PIN" = 1 ]; then
    for v in IMAGE SYSMAP CONFIG MODTAR DTB; do
        want=SHA_$v; got=$(sha256sum "${!v}" | cut -d' ' -f1)
        [ "$got" = "${!want}" ] || die "$v sha $got, pinned ${!want}"
        echo "pin ok  $v $got"
    done
fi
grep -q "^CONFIG_LOCALVERSION=\"-${KREL#*-}\"" "$CONFIG" || die "config LOCALVERSION does not match $KREL"

KPKG=h96-kernel-$KREL
DPKG=h96-dtb-$KREL
# clear only this script's trees; caller WORK may hold other files
rm -rf "${WORK:?}/$KPKG" "${WORK:?}/$DPKG"; mkdir -p "$WORK" "$OUT"

doc_files() { # pkg root version
    local d="$2/usr/share/doc/$1"
    mkdir -p "$d"
    cat > "$d/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: linux (Rockchip BSP rk-6.1 with H96 MAX V58 patches)
Source: https://github.com/armbian/linux-rockchip

Files: *
Copyright: 1991-2026 Linus Torvalds and Linux kernel contributors
License: GPL-2
 On Debian systems, full text of GNU General Public License version 2
 is in /usr/share/common-licenses/GPL-2.
EOF
    # native version (no Debian revision) takes changelog.gz
    local cl=changelog.gz
    case "$3" in *-*) cl=changelog.Debian.gz;; esac
    # KCFLAGS line in kernel package only; DTB package stays byte-equal
    local kc=""
    [ -z "$KCFLAGS" ] || [ "$1" != "$KPKG" ] || kc="  * Kernel compiled with KCFLAGS: $KCFLAGS\n"
    printf '%s (%s) unstable; urgency=medium\n\n  * Kernel %s, staged files only.\n%b\n -- %s  %s\n' \
        "$1" "$3" "$KREL" "$kc" "$MAINT" "$(date -u -R -d "@$SOURCE_DATE_EPOCH")" \
        | gzip -9n > "$d/$cl"
}

inst_size() { # root; KiB per file rounded up, 1 per other entry, as dpkg-gencontrol
    find "$1" -mindepth 1 -path "$1/DEBIAN" -prune -o \( -type f -printf 'f %s\n' -o -printf 'o 0\n' \) \
        | awk '{ n += ($1 == "f") ? int(($2 + 1023) / 1024) : 1 } END { print n + 0 }'
}

finish_pkg() { # root
    local r=$1
    find "$r" -path "$r/DEBIAN" -prune -o -type d -exec chmod 0755 {} +
    find "$r" -path "$r/DEBIAN" -prune -o -type f -exec chmod 0644 {} +
    (cd "$r" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 md5sum) > "$r/DEBIAN/md5sums"
    chmod 0644 "$r/DEBIAN/md5sums"
    if find "$r" -path "$r/DEBIAN" -prune -o -print | sed "s|^$r||" | grep -qE '^/boot(/|$)'; then die "payload contains /boot"; fi
    find "$r" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
}

# kernel package
KR=$WORK/$KPKG
KS=$KR$STAGEPREFIX/$KREL
mkdir -p "$KS" "$KR$MODPREFIX" "$KR/DEBIAN"
cp "$IMAGE" "$KS/Image"
cp "$SYSMAP" "$KS/System.map"
cp "$CONFIG" "$KS/config"
tar -xzf "$MODTAR" -C "$KR$MODPREFIX" --no-same-owner --no-same-permissions
[ -d "$KR$MODPREFIX/$KREL/kernel" ] || die "modules tarball has no $KREL/kernel"
# depmod outputs: generated by postinst, removed by postrm
for g in alias alias.bin builtin.alias.bin builtin.bin dep dep.bin devname softdep symbols symbols.bin weakdep; do
    rm -f "$KR$MODPREFIX/$KREL/modules.$g"
done
find "$KR$MODPREFIX/$KREL" -maxdepth 1 \( -name build -o -name source \) -exec rm -f {} +
(cd "$KS" && sha256sum Image System.map config > SHA256SUMS.kernel)
doc_files "$KPKG" "$KR" "$PKGVER"

cat > "$KR/DEBIAN/postinst" <<EOF
#!/bin/sh
# runs depmod for $KREL only; no /boot access, no /etc/kernel hooks, no initramfs
set -e
if [ "\$1" = configure ]; then
    depmod -a -b "\${DPKG_ROOT:-/}" -F "\${DPKG_ROOT:-}$STAGEPREFIX/$KREL/System.map" $KREL
    # hint only, skipped when $KREL already boots by default or is on trial; switching is a separate admin step
    if [ -z "\${DPKG_ROOT:-}" ]; then
        roles=""
        if command -v h96-kernel-switch >/dev/null 2>&1; then
            roles=\$(h96-kernel-switch in-use $KREL 2>/dev/null || true)
        elif [ "\$(uname -r)" = $KREL ]; then
            roles=default
        fi
        case " \$roles " in
        *" default "*|*" trial "*) ;;
        *)
            echo "$KPKG: staged in $STAGEPREFIX/$KREL; boot files unchanged"
            echo "$KPKG: to boot it once with fallback: h96-kernel-switch try $KREL (package h96-kernel-switch)"
            ;;
        esac
    fi
fi
exit 0
EOF
cat > "$KR/DEBIAN/prerm" <<EOF
#!/bin/sh
# refuses removal of modules of running, default, trial or rollback kernel unless H96_KERNEL_FORCE_REMOVE=1
set -e
if [ "\$1" = remove ] && [ -z "\${DPKG_ROOT:-}" ] && [ "\${H96_KERNEL_FORCE_REMOVE:-0}" != 1 ]; then
    if [ "\$(uname -r)" = $KREL ]; then
        echo "$KPKG: $KREL is running kernel; removal refused (H96_KERNEL_FORCE_REMOVE=1 overrides)" >&2
        exit 1
    fi
    if command -v h96-kernel-switch >/dev/null 2>&1 && roles=\$(h96-kernel-switch in-use $KREL 2>/dev/null); then
        echo "$KPKG: $KREL is \$roles kernel in boot files; removal refused (H96_KERNEL_FORCE_REMOVE=1 overrides)" >&2
        exit 1
    fi
fi
exit 0
EOF
cat > "$KR/DEBIAN/postrm" <<EOF
#!/bin/sh
# removes depmod outputs for $KREL; no /boot access
set -e
case "\$1" in
remove|purge)
    d="\${DPKG_ROOT:-}$MODPREFIX/$KREL"
    for g in alias alias.bin builtin.alias.bin builtin.bin dep dep.bin devname softdep symbols symbols.bin weakdep; do
        rm -f "\$d/modules.\$g"
    done
    rmdir --ignore-fail-on-non-empty "\$d" 2>/dev/null || true
    ;;
esac
exit 0
EOF
finish_pkg "$KR"
chmod 0755 "$KR/DEBIAN/postinst" "$KR/DEBIAN/prerm" "$KR/DEBIAN/postrm"
KSIZE=$(inst_size "$KR")
cat > "$KR/DEBIAN/control" <<EOF
Package: $KPKG
Version: $PKGVER
Section: kernel
Priority: optional
Architecture: arm64
Depends: kmod
Recommends: $DPKG
Installed-Size: $KSIZE
Maintainer: $MAINT
Description: H96 MAX V58 Linux kernel $KREL (staged)
 Linux kernel $KREL for H96 MAX V58 (RK3588),
 Rockchip BSP rk-6.1 tree with H96 patch series.
 .
 Stages Image, System.map and config under
 $STAGEPREFIX/$KREL/
 and installs modules under
 $MODPREFIX/$KREL/.
 Maintainer scripts run depmod for this release only.
 Package never writes /boot and runs no /etc/kernel hooks
 or initramfs tools; h96-kernel-switch copies files into
 /boot as guarded trial.
EOF
touch -d "@$SOURCE_DATE_EPOCH" "$KR/DEBIAN/control" "$KR/DEBIAN"

# dtb package
DR=$WORK/$DPKG
DS=$DR$STAGEPREFIX/$KREL/dtb
mkdir -p "$DS/$(dirname "$FDTFILE")" "$DR/DEBIAN"
cp "$DTB" "$DS/$FDTFILE"
(cd "$DS" && sha256sum "$FDTFILE" > SHA256SUMS.dtb)
doc_files "$DPKG" "$DR" "$DTB_PKGVER"
finish_pkg "$DR"
DSIZE=$(inst_size "$DR")
cat > "$DR/DEBIAN/control" <<EOF
Package: $DPKG
Version: $DTB_PKGVER
Section: kernel
Priority: optional
Architecture: arm64
Installed-Size: $DSIZE
Maintainer: $MAINT
Description: H96 MAX V58 device tree for kernel $KREL (staged)
 Device tree blob for H96 MAX V58 (RK3588):
 $FDTFILE
 staged under $STAGEPREFIX/$KREL/dtb/.
 Package has no maintainer scripts and never writes /boot;
 h96-kernel-switch copies file into /boot.
EOF
touch -d "@$SOURCE_DATE_EPOCH" "$DR/DEBIAN/control" "$DR/DEBIAN"

ARCH=arm64
KDEB=$OUT/${KPKG}_${PKGVER}_$ARCH.deb
DDEB=$OUT/${DPKG}_${DTB_PKGVER}_$ARCH.deb
heavy dpkg-deb --root-owner-group -Zxz --build "$KR" "$KDEB"
heavy dpkg-deb --root-owner-group -Zxz --build "$DR" "$DDEB"
(cd "$OUT" && sha256sum "$(basename "$KDEB")" "$(basename "$DDEB")" > SHA256SUMS)
sync
cat "$OUT/SHA256SUMS"
