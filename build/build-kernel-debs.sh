#!/bin/bash
# shellcheck disable=SC2034  # SHA_* pins read through ${!want}
# Builds h96-kernel-<krel> and h96-dtb-<krel> debs from pinned kernel build outputs.
# Payload stages into /usr/lib/h96-kernel/<krel>/ and /lib/modules/<krel>/; nothing under /boot.
# Usage: MAINT='Name <email>' IMAGE=.. SYSMAP=.. CONFIG=.. MODTAR=.. DTB=.. build-kernel-debs.sh [OUTDIR]
# Re-runnable; output depends only on inputs and SOURCE_DATE_EPOCH.
set -euo pipefail

KREL=${KREL:-6.1.172-h96v58-7.1}
PKGVER=${PKGVER:-7.1.0-1}
MODPREFIX=${MODPREFIX:-/lib/modules}
STAGEPREFIX=/usr/lib/h96-kernel
FDTFILE=${FDTFILE:-rockchip/rk3588-h96-max-v58-panthor.dtb}
# Maintainer field; required, no default
MAINT=${MAINT:-}
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1791244800}

# inputs: kernel Image, System.map, .config, modules tarball (<krel>/kernel/...), board DTB
IMAGE=${IMAGE:-}
SYSMAP=${SYSMAP:-}
CONFIG=${CONFIG:-}
MODTAR=${MODTAR:-}
DTB=${DTB:-}

# default KREL repacks published v7.1 payload (test only); PIN=0 skips pins for other inputs
PIN=${PIN:-1}
SHA_IMAGE=1ac355a2c289f5fe419c0bccdf6fc8df759782fda2888fdd1e180744a3a4678e
SHA_SYSMAP=196975ae6999198a065e4259aa266e922b3bd756b89ea17987aec4dfbe6de1d0
SHA_CONFIG=d475b71460e0946b9e4a615a32cf89b173e487a483747198406f0cd0a4f29ea9
SHA_MODTAR=befb804af7ed78ac339b2659f5354fcd36ef3231cc18fbd4a28569fa7b8e2016
SHA_DTB=f3ca55ce08fae47f351558964b4b040c9229852ba74241b01de2bb47ce2da6ea

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

doc_files() { # pkg root
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
    printf '%s (%s) unstable; urgency=medium\n\n  * Kernel %s, staged files only.\n\n -- %s  %s\n' \
        "$1" "$PKGVER" "$KREL" "$MAINT" "$(date -u -R -d "@$SOURCE_DATE_EPOCH")" \
        | gzip -9n > "$d/changelog.Debian.gz"
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
doc_files "$KPKG" "$KR"

cat > "$KR/DEBIAN/postinst" <<EOF
#!/bin/sh
# runs depmod for $KREL only; no /boot access, no /etc/kernel hooks, no initramfs
set -e
if [ "\$1" = configure ]; then
    depmod -a -b "\${DPKG_ROOT:-/}" -F "\${DPKG_ROOT:-}$STAGEPREFIX/$KREL/System.map" $KREL
fi
exit 0
EOF
cat > "$KR/DEBIAN/prerm" <<EOF
#!/bin/sh
# refuses removal of running kernel's modules unless H96_KERNEL_FORCE_REMOVE=1
set -e
if [ "\$1" = remove ] && [ -z "\${DPKG_ROOT:-}" ] && [ "\$(uname -r)" = $KREL ] && [ "\${H96_KERNEL_FORCE_REMOVE:-0}" != 1 ]; then
    echo "$KPKG: $KREL is running kernel; removal refused (H96_KERNEL_FORCE_REMOVE=1 overrides)" >&2
    exit 1
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
 or initramfs tools; separate boot staging tool copies
 files into /boot.
EOF
touch -d "@$SOURCE_DATE_EPOCH" "$KR/DEBIAN/control" "$KR/DEBIAN"

# dtb package
DR=$WORK/$DPKG
DS=$DR$STAGEPREFIX/$KREL/dtb
mkdir -p "$DS/$(dirname "$FDTFILE")" "$DR/DEBIAN"
cp "$DTB" "$DS/$FDTFILE"
(cd "$DS" && sha256sum "$FDTFILE" > SHA256SUMS.dtb)
doc_files "$DPKG" "$DR"
finish_pkg "$DR"
DSIZE=$(inst_size "$DR")
cat > "$DR/DEBIAN/control" <<EOF
Package: $DPKG
Version: $PKGVER
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
 separate boot staging tool copies file into /boot.
EOF
touch -d "@$SOURCE_DATE_EPOCH" "$DR/DEBIAN/control" "$DR/DEBIAN"

ARCH=arm64
KDEB=$OUT/${KPKG}_${PKGVER}_$ARCH.deb
DDEB=$OUT/${DPKG}_${PKGVER}_$ARCH.deb
heavy dpkg-deb --root-owner-group -Zxz --build "$KR" "$KDEB"
heavy dpkg-deb --root-owner-group -Zxz --build "$DR" "$DDEB"
(cd "$OUT" && sha256sum "$(basename "$KDEB")" "$(basename "$DDEB")" > SHA256SUMS)
sync
cat "$OUT/SHA256SUMS"
