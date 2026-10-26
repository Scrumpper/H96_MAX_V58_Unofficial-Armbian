#!/bin/bash
# Build h96-* binary debs from pkgs/<name>/{root,debian} with dpkg-deb, no root needed.
# Usage: build-userland-debs.sh --out DIR [PKG...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=""
PKGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n 2,3p "$0"; exit 0 ;;
    *) PKGS+=("$1"); shift ;;
  esac
done
[ -n "$OUT" ] || { echo "usage: $0 --out DIR [PKG...]" >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[ ${#PKGS[@]} -gt 0 ] || mapfile -t PKGS < <(cd "$HERE/pkgs" && ls -d h96-* | sort)
# fixed timestamps so repeated builds give identical debs
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1792152000}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
for p in "${PKGS[@]}"; do
  src="$HERE/pkgs/$p"
  [ -d "$src/debian" ] || { echo "missing $src/debian" >&2; exit 1; }
  d="$STAGE/$p"
  cp -a "$src/root" "$d"
  mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$p"
  cp "$src/debian/copyright" "$d/usr/share/doc/$p/copyright"
  gzip -9n -c "$src/debian/changelog" > "$d/usr/share/doc/$p/changelog.gz"
  chmod 644 "$d/usr/share/doc/$p/copyright" "$d/usr/share/doc/$p/changelog.gz"
  if [ -f "$src/debian/lintian-overrides" ]; then
    install -D -m644 "$src/debian/lintian-overrides" "$d/usr/share/lintian/overrides/$p"
  fi
  ver="$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$src/debian/changelog")"
  # binary control: Package stanza of debian/control plus Version, Maintainer, Section, Priority, Installed-Size
  awk -v ver="$ver" '
    /^Maintainer:/ {m=$0} /^Section:/ {s=$0} /^Priority:/ {pr=$0}
    /^Package:/ {inpkg=1}
    inpkg {print; if ($0 ~ /^Package:/) {print "Version: " ver}}
    END {print m; print s; print pr}' "$src/debian/control" > "$d/DEBIAN/control.tmp"
  size="$(du -sk --apparent-size --exclude=DEBIAN "$d" | cut -f1)"
  { grep -v -e '^Description:' -e '^ ' "$d/DEBIAN/control.tmp"; echo "Installed-Size: $size"
    sed -n '/^Description:/,$p' "$d/DEBIAN/control.tmp" | grep -e '^Description:' -e '^ '; } > "$d/DEBIAN/control"
  rm "$d/DEBIAN/control.tmp"
  for f in conffiles postinst postrm preinst prerm; do
    [ -f "$src/debian/$f" ] || continue
    cp "$src/debian/$f" "$d/DEBIAN/$f"
    case "$f" in conffiles) chmod 644 "$d/DEBIAN/$f" ;; *) chmod 755 "$d/DEBIAN/$f" ;; esac
  done
  (cd "$d" && find . -path ./DEBIAN -prune -o -type f -print0 | sort -z | xargs -0 -r md5sum | sed 's#  \./#  #') > "$d/DEBIAN/md5sums"
  chmod 644 "$d/DEBIAN/control" "$d/DEBIAN/md5sums"
  find "$d" -type d -exec chmod 755 {} +
  find "$d" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
  arch="$(sed -n 's/^Architecture: //p' "$d/DEBIAN/control")"
  deb="$OUT/${p}_${ver}_${arch}.deb"
  dpkg-deb --root-owner-group -Zxz --build "$d" "$deb" >/dev/null
  echo "built $(basename "$deb") $(sha256sum "$deb" | cut -c1-16)"
done
