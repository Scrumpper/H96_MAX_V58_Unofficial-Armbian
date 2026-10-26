#!/bin/bash
# Stage 4, pinned route (light): offline repo from pinned debs ($IN/repo, pins role offline-repo deb), flat index as
# repo-index.sh, published signatures from repo-sig (or owner key with H96_REPO_GNUPG); index compared with pins.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR/repo; mkdir -p "$EV"; SIG=$H96_REPO/build/debian/repo-sig
D=$W/repo; rm -rf "$D"; mkdir -p "$D"
n=0; while IFS=$'\t' read -r name _url sha _size role; do [ "$role" = "offline-repo deb" ] || continue
  [ "$(sha256sum < "$IN/$name" | cut -d' ' -f1)" = "$sha" ] || { echo "FAIL $name sha vs pins"; exit 1; }; cp -p "$IN/$name" "$D/"; n=$((n+1)); done < "$PINS"
echo "PASS $n pinned offline-repo debs"
for f in "$D"/*.deb; do dpkg-scanpackages -m "$f" /dev/null 2>/dev/null | sed "s#^Filename: .*#Filename: ./$(basename "$f")#"; echo; done | python3 -I -c '
import sys,re
st=[s for s in sys.stdin.read().split("\n\n") if s.strip()]
st.sort(key=lambda s:(re.search(r"^Package: (.+)$",s,re.M).group(1), re.search(r"^Architecture: (.+)$",s,re.M).group(1)))
sys.stdout.write("\n\n".join(st)+"\n")' > "$D/Packages"
gzip -9n -c "$D/Packages" > "$D/Packages.gz"
if [ -n "${H96_REPO_GNUPG:-}" ]; then python3 -I "$H/repo-sign.py" "$D"; else
  python3 -I "$H/repo-sign.py" --release-only "$D"; cp -p "$SIG/InRelease" "$SIG/Release.gpg" "$D/"; fi
for f in Packages Packages.gz Release InRelease Release.gpg; do s=$(sha256sum < "$D/$f" | cut -d' ' -f1)
  [ "$s" = "$(pin "repo/$f")" ] && echo "PASS repo/$f = pins (${s:0:8})" || echo "DIFF repo/$f ${s:0:8} (pins $(pin "repo/$f" | cut -c1-8))"; done
gpgv --keyring "$KEYRING" "$D/InRelease" 2>&1 | grep -q 'Good signature' && echo "PASS InRelease gpgv" || echo "FAIL InRelease gpgv (Release differs from published or key missing)"
(cd "$D" && sha256sum Packages Packages.gz Release InRelease Release.gpg) > "$EV/index.sha256"
