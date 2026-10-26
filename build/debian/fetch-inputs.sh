#!/bin/bash
# Fetch every pins row with an https URL into $IN/<name>, verify sha256; list rows that need a local file.
# Usage: fetch-inputs.sh [--check]   (--check: verify files already in $IN, no download)
# H96_DEB_SNAPSHOT (default 20261023T060000Z): snapshot.debian.org fallback for Debian pool files gone from mirrors.
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/env.sh"; SNAP=${H96_DEB_SNAPSHOT:-20261023T060000Z}
ok=0; miss=0; badn=0
while IFS=$'\t' read -r name url sha _size role; do
  [ "$name" = name ] && continue; [ "$sha" = - ] && continue
  case "$role" in expected*) continue ;; esac
  case "$url" in generated:*|"in repo:"*) continue ;; esac; case "$name" in *.img) continue ;; esac   # made by pipeline
  f=$IN/$name; url=${url%% (*}
  if [ ! -f "$f" ] && [ "${1:-}" != --check ]; then
    case "$url" in https://*)
      mkdir -p "$(dirname "$f")"
      curl -fsSL -o "$f.part" "$url" || { case "$url" in
        https://deb.debian.org/debian/*) curl -fsSL -o "$f.part" "https://snapshot.debian.org/archive/debian/$SNAP/${url#https://deb.debian.org/debian/}" ;;
        https://security.debian.org/debian-security/*) curl -fsSL -o "$f.part" "https://snapshot.debian.org/archive/debian-security/$SNAP/${url#https://security.debian.org/debian-security/}" ;;
        *) false ;; esac; } && mv "$f.part" "$f" || rm -f "$f.part" ;;
    esac
  fi
  if [ ! -f "$f" ]; then echo "NEED $name  ($url)"; miss=$((miss+1))
  elif [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$sha" ]; then ok=$((ok+1))
  else echo "BAD  $name sha differs"; badn=$((badn+1)); fi
done < "$PINS"
echo "inputs ok=$ok need=$miss bad=$badn (dir $IN)"
[ "$miss" = 0 ] && [ "$badn" = 0 ]
