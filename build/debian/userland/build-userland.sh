#!/bin/bash
# Debian Edition userland debs: Ubuntu pkgs tree of build/userland (blobs filled by prepare-pkgs.py), pkgs-debian.patch,
# overlay/ and Debian video blobs from pins; two builds compared, then compared with pins. Output $W/userland-debs.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"
UB=${H96_UB_USERLAND:-$H96_REPO/build/userland}
python3 -I "$UB/prepare-pkgs.py" --check || { echo "FAIL Ubuntu pkgs tree incomplete (prepare-pkgs.py --blobs-from, docs/REPRODUCE.md)"; exit 1; }
G=$W/userland-debian; rm -rf "$G"; mkdir -p "$G"; cp -a "$UB/build-userland-debs.sh" "$UB/pkgs" "$G/"
(cd "$G/pkgs" && patch -p1 -s --no-backup-if-mismatch < "$H/pkgs-debian.patch") && echo "PASS pkgs-debian.patch applied"
# overlay files are man pages: mode 0644 whatever checkout umask gave
(cd "$H/overlay" && find . -type f) | while read -r f; do install -m 0644 "$H/overlay/$f" "$G/pkgs/$f"; done
M=$G/pkgs/h96-media/root/usr/lib/h96
for f in video/h96-video-stack.tar.gz video/mpris.so; do [ "$(sha256sum < "$IN/$f" | cut -d' ' -f1)" = "$(pin "$f")" ] || { echo "FAIL $f sha vs pins"; exit 1; }; done
install -m 0644 "$IN/video/h96-video-stack.tar.gz" "$M/video/"; install -m 0644 "$IN/video/mpris.so" "$M/mpv-mpris/"
rm -rf "$W/userland-debs" "$W/userland-debs-b"
bash "$G/build-userland-debs.sh" --out "$W/userland-debs"; bash "$G/build-userland-debs.sh" --out "$W/userland-debs-b" > /dev/null
diff <(cd "$W/userland-debs" && sha256sum ./*.deb) <(cd "$W/userland-debs-b" && sha256sum ./*.deb) && echo "PASS two builds byte-identical" || { echo "FAIL two builds differ"; exit 1; }
fail=0; for f in "$W"/userland-debs/*.deb; do b=$(basename "$f"); s=$(sha256sum < "$f" | cut -d' ' -f1)
  [ "$s" = "$(pin "debs/$b")" ] && echo "PASS $b = pins (${s:0:8})" || { echo "FAIL $b ${s:0:8} != pins"; fail=1; }; done
exit $fail
