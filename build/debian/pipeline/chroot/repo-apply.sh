#!/bin/bash
# Inside image chroot, first step (Debian edition): offline repo built and signed on laptop (pipeline/repo.sh) installed
# as /opt/h96-pkgs (trixie base has none); signature checked with public keyring from stage, every stanza file sha.
set -uo pipefail
R=/opt/h96-pkgs; I=/root/f5-in/repo; L=/root/f5-log/repo; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
[ ! -e "$R" ] && ok "no offline repo in base" || bad "$R exists in base"
K=/root/f5-in/h96-local-archive-keyring.gpg
(cd "$I" && sha256sum -c --status index.sha256) && ok "stage index = laptop index.sha256" || bad "stage index sha"
gpgv --keyring "$K" "$I/InRelease" > "$L/gpgv.txt" 2>&1 && ok "InRelease gpgv" || bad "InRelease gpgv"
gpgv --keyring "$K" "$I/Release.gpg" "$I/Release" >> "$L/gpgv.txt" 2>&1 && ok "Release.gpg gpgv" || bad "Release.gpg gpgv"
mkdir -p "$R"
for f in "$I"/*.deb "$I"/Packages "$I"/Packages.gz "$I"/Release "$I"/InRelease "$I"/Release.gpg; do install -m 0644 -o root -g root "$f" "$R/"; done
(cd "$R" && awk '/^SHA256:/{f=1;next} /^[^ ]/{f=0} f{print $1"  "$3}' Release | sha256sum -c --status) && ok "Release sums" || bad "Release sums"
(cd "$R" && awk '/^Filename:/{f=substr($2,3)} /^SHA256:/{print $2"  "f}' Packages | sha256sum -c --quiet) > "$L/files.txt" 2>&1 && ok "every stanza file present, sha match" || bad "stanza files: $(head -3 "$L/files.txt")"
s=$(grep -c '^Package:' "$R/Packages"); n=$(find "$R" -maxdepth 1 -name '*.deb' | wc -l)
[ "$s" = "$n" ] && ok "debs = stanzas ($n)" || bad "debs $n stanzas $s"
find "$R" -maxdepth 1 -iname '*libmali*' | grep -q . && bad "libmali deb" || ok "no libmali deb"
grep -qx 'Version: 26.1.6-1~bpo13+1' "$R/Packages" && ok "Mesa 26.1.6-1~bpo13+1 in repo" || bad "Mesa backports build missing"
grep -q 'kisak' "$R/Packages" && bad "kisak build in repo" || ok "no kisak build"
grep -qx 'Version: 0.5.18-1~h96.1+deb13.1' "$R/Packages" && ok "WirePlumber 0.5.18-1~h96.1+deb13.1 in repo" || bad "WirePlumber rebuild missing"
echo "fail=$fail"; exit $fail
