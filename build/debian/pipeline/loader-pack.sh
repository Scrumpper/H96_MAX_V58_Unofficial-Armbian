#!/bin/bash
# Stages 8 and 9 (laptop): loader set H96_LOADER (default A1) by loader-pin.py (pins, read back, preflight
# checker by path, unchanged), bytes past sector 32767 unchanged, then xz -9, round trip, sums into out/.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR/loader; LOADER=${H96_LOADER:-A1}
IMG=$W/$NAME.img; LDR=$IN/loader
mkdir -p "$EV" "$OUT"
[ "$(sha256sum < "$IMG" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$EVR/assemble/img.sha256")" ] || { echo "assembled img sha"; exit 1; }
cp "$OUT/$NAME.img.sha256" "$OUT/$NAME.img.assembled.sha256"
for f in old-idbloader.img old-u-boot.itb A1-u-boot.itb; do [ "$(sha256sum < "$LDR/$f" | cut -d' ' -f1)" = "$(pin "loader/$f")" ] || { echo "loader $f sha vs pins"; exit 1; }; done
tail -c +16777217 "$IMG" | sha256sum | cut -d' ' -f1 > "$EV/past-32767.pre"
python3 -I "$H/loader-pin.py" "$IMG" "$LOADER" "$LDR" "$H/preflight_check.py" | tee "$EV/loader-pin.txt"
tail -c +16777217 "$IMG" | sha256sum | cut -d' ' -f1 > "$EV/past-32767.post"
cmp -s "$EV/past-32767.pre" "$EV/past-32767.post" && echo "PASS bytes past sector 32767 unchanged by loader step" || { echo "FAIL loader step changed image body"; exit 1; }
i=$(sha256sum < "$IMG" | cut -d' ' -f1)
echo "$i  $NAME.img" > "$OUT/$NAME.img.sha256"; printf 'loader %s\nimg %s\n' "$LOADER" "$i" > "$OUT/$NAME.img.loader"
xz -T6 -9 -k -f -c "$IMG" > "$OUT/$NAME.img.xz"
xz -t "$OUT/$NAME.img.xz" && echo "PASS xz -t"
[ "$(xz -dc "$OUT/$NAME.img.xz" | sha256sum | cut -d' ' -f1)" = "$i" ] && echo "PASS xz round trip" || { echo "FAIL xz round trip"; exit 1; }
x=$(sha256sum < "$OUT/$NAME.img.xz" | cut -d' ' -f1)
echo "$x  $NAME.img.xz" > "$OUT/$NAME.img.xz.sha256"
(cd "$OUT" && sha256sum "$NAME.img.xz" > SHA256SUMS && sha256sum -c SHA256SUMS)
ls -l "$OUT/$NAME.img.xz"; echo "img $i ($(stat -c %s "$IMG") B), xz $x"
