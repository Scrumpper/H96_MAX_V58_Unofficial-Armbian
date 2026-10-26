#!/bin/bash
# Stage 4 repo, second half (laptop): provenance of downloaded closure, flat index of closure + carried debs, signing.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"
EV=$EVR/repo; RI=$W/repo-in; SIG=$H96_REPO/build/debian/repo-sig
python3 -I "$H/debian-provenance.py" "$EV/log/lists" "$IN/keys/debian-archive-keyring.gpg,$IN/keys/armbian-archive-keyring.gpg" "$W"/repo-dl/*.deb | tee "$EV/provenance.txt"
# flat repo: downloaded closure + carried debs
D=$W/repo; rm -rf "$D"; mkdir -p "$D"; cp -p "$W"/repo-dl/*.deb "$RI"/carry/*.deb "$D/"
for f in "$D"/*.deb; do dpkg-scanpackages -m "$f" /dev/null 2>/dev/null | sed "s#^Filename: .*#Filename: ./$(basename "$f")#"; echo; done | python3 -I -c '
import sys,re
st=[s for s in sys.stdin.read().split("\n\n") if s.strip()]
st.sort(key=lambda s:(re.search(r"^Package: (.+)$",s,re.M).group(1), re.search(r"^Architecture: (.+)$",s,re.M).group(1)))
sys.stdout.write("\n\n".join(st)+"\n")' > "$D/Packages"
gzip -9n -c "$D/Packages" > "$D/Packages.gz"
# H96_REPO_GNUPG set: sign with owner key; unset: published signatures from repo-sig (valid when Release is byte-identical)
if [ -n "${H96_REPO_GNUPG:-}" ]; then python3 -I "$H/repo-sign.py" "$D"; else python3 -I "$H/repo-sign.py" --release-only "$D"; cp -p "$SIG/InRelease" "$SIG/Release.gpg" "$D/"; fi
gpgv --keyring "$KEYRING" "$D/InRelease" 2>&1 | grep -q 'Good signature' && echo "PASS InRelease gpgv"
find "$D" -path '*gnupg*' -o -name '*.key' | grep -q . && { echo "key material in repo"; exit 1; }
(cd "$D" && sha256sum Packages Packages.gz Release InRelease Release.gpg) | tee "$EV/index.sha256"
echo "repo stanzas $(grep -c '^Package:' "$D/Packages") debs $(ls "$D"/*.deb | wc -l) size $(du -sh "$D" | cut -f1)"
