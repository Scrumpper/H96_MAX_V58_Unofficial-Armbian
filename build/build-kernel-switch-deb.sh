#!/bin/bash
# Builds h96-kernel-switch deb from packages/h96-kernel-switch; no root needed.
# Usage: build-kernel-switch-deb.sh OUTDIR
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=$HERE/packages/h96-kernel-switch
OUT=${1:?usage: $0 OUTDIR}
P=h96-kernel-switch
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1792346400}
case "$(realpath -m "$OUT")/" in /boot/*) echo "ERROR: refusing OUTDIR under /boot" >&2; exit 1 ;; esac
[ "$(id -u)" != 0 ] || { echo "ERROR: run as normal user" >&2; exit 1; }
mkdir -p "$OUT"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
R=$D/$P
cp -a "$SRC/root" "$R"
mkdir -p "$R/DEBIAN" "$R/usr/share/doc/$P" "$R/usr/share/man/man8"
gzip -9n -c "$SRC/man/$P.8" > "$R/usr/share/man/man8/$P.8.gz"
gzip -9n -c "$SRC/debian/changelog" > "$R/usr/share/doc/$P/changelog.gz"
cp "$SRC/debian/copyright" "$R/usr/share/doc/$P/copyright"
VER=$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$SRC/debian/changelog")
find "$R" -path "$R/DEBIAN" -prune -o -type f -print0 | xargs -0 chmod 0644
chmod 0755 "$R/usr/sbin/$P"
for f in prerm postrm; do install -m 0755 "$SRC/debian/$f" "$R/DEBIAN/$f"; done
(cd "$R" && find . -path ./DEBIAN -prune -o -type f -print0 | sort -z | xargs -0 md5sum | sed 's#  \./#  #') > "$R/DEBIAN/md5sums"
SIZE=$(find "$R" -path "$R/DEBIAN" -prune -o -type f -printf '%s\n' | awk '{s += int(($1 + 1023) / 1024)} END {print s}')
{
    awk '/^Package:/ {p=1} p && !/^Description:/ && !/^ / {print} /^Package:/ {print "Version: '"$VER"'"}' "$SRC/debian/control"
    sed -n 's/^\(Maintainer\|Section\|Priority\):/&/p' "$SRC/debian/control"
    echo "Installed-Size: $SIZE"
    sed -n '/^Description:/,$p' "$SRC/debian/control"
} > "$R/DEBIAN/control"
chmod 0644 "$R/DEBIAN/control" "$R/DEBIAN/md5sums"
find "$R" -type d -exec chmod 0755 {} +
find "$R" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
if find "$R" -path "$R/DEBIAN" -prune -o -print | sed "s|^$R||" | grep -qE '^/boot(/|$)'; then
    echo "ERROR: payload contains /boot" >&2; exit 1
fi
DEB=$OUT/${P}_${VER}_all.deb
dpkg-deb --root-owner-group -Zxz --build "$R" "$DEB" > /dev/null
(cd "$OUT" && sha256sum "$(basename "$DEB")")
