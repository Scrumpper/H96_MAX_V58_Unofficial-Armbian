#!/bin/bash
# h96-edid-adapt: make the desktop see the attached display's native resolutions
# and refresh rates. The kernel cannot read EDID on this box (DDC controller
# defect), so the desktop otherwise only sees the baked default modes.
#
# DESIGN (learned from hardware): this ENUMERATES modes, it does NOT switch the
# output. It reads the display's EDID over the i2c-ddc bus, strips the CEA
# color-format triggers (YCbCr, deep colour, wide colorimetry, HDR, 4:2:0) so
# the driver keeps plain RGB 8-bit, keeps every mode timing, and writes it to
# the DRM edid_override. It NEVER forces a re-detect or a modeset, so the live
# console/desktop output is never re-driven: no black screen, no colour tint.
# The desktop reads the override on its own probe (X startup) and lists the
# native modes; the user picks one, and KDE remembers it per display.
LOG=/var/log/h96-edid-adapt.log
exec >> "$LOG" 2>&1
echo "=== h96-edid-adapt $(date) (trigger: ${1:-boot}) ==="

FLAG=/etc/h96/display-autodetect.enabled
[ -f "$FLAG" ] || { echo "display autodetect is off (opt-in); doing nothing"; exit 0; }
OVR=/sys/kernel/debug/dri/0/HDMI-A-1/edid_override
CACHE=/run/h96-edid-adapt.last
PARSER=/usr/local/lib/h96/edid_modes.py
[ -w "$OVR" ] || { echo "no writable edid_override; doing nothing"; exit 0; }

bus=""
for d in /sys/class/i2c-dev/i2c-*; do
  [ "$(cat "$d/name" 2>/dev/null)" = "i2c-ddc" ] && { bus="${d##*i2c-}"; break; }
done
[ -n "$bus" ] || { echo "no i2c-ddc bus; doing nothing"; exit 0; }

b0=$(i2ctransfer -y "$bus" w1@0x50 0x00 r128@0x50 2>/dev/null) || {
  echo "no EDID answer at 0x50 (no display?); doing nothing"; exit 0; }
ext=$(python3 -c "import sys;b=[int(x,16) for x in sys.argv[1:]];print(min(b[126],7))" $b0 2>/dev/null)
blocks="$b0"; i=1
while [ "${ext:-0}" -ge "$i" ]; do
  seg=$((i / 2)); off=$(( (i % 2) * 128 ))
  if [ "$seg" -eq 0 ]; then
    bn=$(i2ctransfer -y "$bus" w1@0x50 $off r128@0x50 2>/dev/null) || break
  else
    bn=$(i2ctransfer -y "$bus" w1@0x30 $seg w1@0x50 $off r128@0x50 2>/dev/null) || break
  fi
  blocks="$blocks $bn"; i=$((i + 1))
done
raw=$(mktemp)
python3 -c "import sys;sys.stdout.buffer.write(bytes(int(x,16) for x in sys.argv[1:]))" $blocks > "$raw"

if ! python3 "$PARSER" "$raw" >/dev/null 2>&1; then
  echo "EDID failed validation; doing nothing"; rm -f "$raw"; exit 0
fi

# Sanitize: strip the CEA color-format triggers in place, keep all mode timings.
python3 - "$raw" <<'PYSAN'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
# Rewrite block-0 preferred detailed timing to 1080p60 (keeps the display's
# physical-size bytes) so a fresh desktop's first-run mode pick is always safe;
# the native modes still enumerate from the other timings. Fix block-0 checksum.
if len(d) >= 128:
    dtd = bytes([0x02,0x3A,0x80,0x18,0x71,0x38,0x2D,0x40,0x58,0x2C,0x45,0x00,
                 d[54+12], d[54+13], d[54+14], 0x00,0x00,0x1E])
    d[54:72] = dtd
    s = 0
    for k in range(127): s = (s + d[k]) & 0xFF
    d[127] = (-s) & 0xFF
if len(d) >= 256 and d[126] >= 1 and d[128] == 0x02:
    c = memoryview(d)[128:256]
    c[3] &= ~0x30                      # clear YCbCr 4:4:4 / 4:2:2 support
    dtd = c[2]; i = 4
    while 4 <= i < dtd and i < 128:
        tag = (c[i] >> 5) & 0x7; ln = c[i] & 0x1f; p = i + 1
        if tag == 3 and ln >= 6 and c[p] == 0x03 and c[p+1] == 0x0c and c[p+2] == 0x00:
            c[p+5] &= ~0x78            # HDMI VSDB: clear deep-colour flags
        elif tag == 7 and ln >= 1:
            et = c[p]
            if et == 5:                # Colorimetry DB -> none
                for k in range(1, ln): c[p+k] = 0
            elif et == 6 and ln >= 2:  # HDR Static -> SDR only
                c[p+1] = 0
            elif et in (0x0e, 0x0f):   # YCbCr 4:2:0 blocks -> none
                for k in range(1, ln): c[p+k] = 0
        i += 1 + ln
    s = 0
    for k in range(127): s = (s + c[k]) & 0xFF
    c[127] = (-s) & 0xFF
open(sys.argv[1], "wb").write(bytes(d))
PYSAN

if [ -f "$CACHE" ] && cmp -s "$raw" "$CACHE"; then
  echo "sanitized EDID unchanged; nothing to do"; rm -f "$raw"; exit 0
fi

# Write the override ONLY. No `force`, no re-detect: the live output is never
# re-driven, so this cannot tint or blank the screen. The desktop picks up the
# modes on its next connector probe (X startup).
cat "$raw" > "$OVR"
cp "$raw" "$CACHE"; rm -f "$raw"
echo "sanitized EDID written to edid_override (enumeration only, no modeset)"
exit 0
