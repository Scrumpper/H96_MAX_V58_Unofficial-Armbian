#!/bin/bash
# Inside image chroot, first step: offline repo index built and signed on laptop (repo-build.py, repo-sign.py) replaces image index;
# libmali debs dropped, add debs copied, MANIFEST libmali line removed, signature and file sums checked.
set -uo pipefail
R=/opt/h96-pkgs; I=/root/f5-in/repo; L=/root/f5-log/repo; mkdir -p "$L/pre"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
cp -p "$R"/Packages "$R"/Packages.gz "$R"/Release "$R"/InRelease "$R"/Release.gpg "$R"/MANIFEST.txt "$L/pre/" 2>/dev/null
# index must be the v7.2 one repo-build.py started from
(cd "$R" && sha256sum -c --status "$I/base.sha256") && ok "image Packages = laptop base" || { bad "image Packages differs from base"; echo "fail=$fail"; exit 1; }
(cd "$I" && sha256sum -c --status add.sha256) && ok "add debs match add.sha256" || { bad "add debs"; echo "fail=$fail"; exit 1; }
while read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */*|..*) bad "drop name $f"; continue ;; esac
  rm -f "$R/$f" && echo "dropped $f"
done < "$I/drop.list"
while read -r _ f; do install -m 0644 -o root -g root "$I/$f" "$R/$f" && echo "added $f"; done < "$I/add.sha256"
for f in Packages Packages.gz Release InRelease Release.gpg; do install -m 0644 -o root -g root "$I/$f" "$R/$f"; done
if [ -f "$R/MANIFEST.txt" ]; then sed -i '/^libmali/d' "$R/MANIFEST.txt"; fi
grep -q '^libmali' "$R/MANIFEST.txt" 2>/dev/null && bad "MANIFEST libmali line" || ok "MANIFEST without libmali"
K=/usr/share/keyrings/h96-local-archive-keyring.gpg
gpgv --keyring "$K" "$R/InRelease" > "$L/gpgv.txt" 2>&1 && ok "InRelease gpgv" || bad "InRelease gpgv"
gpgv --keyring "$K" "$R/Release.gpg" "$R/Release" >> "$L/gpgv.txt" 2>&1 && ok "Release.gpg gpgv" || bad "Release.gpg gpgv"
(cd "$R" && awk '/^SHA256:/{f=1;next} /^[^ ]/{f=0} f{print $1"  "$3}' Release | sha256sum -c --status) && ok "Release sums" || bad "Release sums"
(cd "$R" && awk '/^Filename:/{f=substr($2,3)} /^SHA256:/{print $2"  "f}' Packages | sha256sum -c --quiet) > "$L/files.txt" 2>&1 && ok "every stanza file present, sha match" || bad "stanza files: $(head -3 "$L/files.txt")"
s=$(grep -c '^Package:' "$R/Packages"); n=$(find "$R" -maxdepth 1 -name '*.deb' | wc -l)
[ "$s" = "$n" ] && ok "debs = stanzas ($n)" || bad "debs $n stanzas $s"
find "$R" -maxdepth 1 -iname '*libmali*' | grep -q . && bad "libmali deb left" || ok "no libmali deb"
echo "fail=$fail"; exit $fail
