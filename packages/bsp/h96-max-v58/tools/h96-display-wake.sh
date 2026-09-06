#!/bin/sh
# h96-display-wake: re-drive the HDMI output when the connector is connected
# but not enabled (screen blanked and never came back).
#
# On this BSP kernel the HDMI PHY/VOP path is not re-initialised automatically
# after DPMS-off or a monitor power-cycle: the kernel logs "User-defined mode
# not supported" on the re-probe and the connector stays enabled=disabled while
# X believes the monitor is on. An explicit X modeset re-drives it (validated
# live 2026-08-26: hdptx "phy lane locked", "vop enable intf" -> picture back).
#
# Callers: h96-display-wake.service daemon (key/button press), udev hotplug
# rule (97-h96-display-wake.rules via h96-display-wake-once.service), and
# "h96-display wake" by hand. Silent no-op when the output is healthy.

CON=/sys/class/drm/card0-HDMI-A-1

dead() {
  [ -d "$CON" ] || return 1
  [ "$(cat "$CON/status" 2>/dev/null)" = connected ] || return 1
  [ "$(cat "$CON/enabled" 2>/dev/null)" = disabled ]
}

dead || exit 0

# Give the desktop's own DPMS-on / hotplug handling a moment; only act if the
# output is still down afterwards.
sleep 2
dead || exit 0

# X server auth: lightdm keeps the running server's auth under
# /var/run/lightdm/root/:<display> regardless of who is logged in.
XA=""
for f in /var/run/lightdm/root/:* /root/.Xauthority; do
  [ -f "$f" ] && { XA="$f"; break; }
done
[ -n "$XA" ] || exit 0   # no X server (console or Wayland): nothing to re-drive
case "$XA" in
  */:*) D=":${XA##*/:}" ;;
  *)    D=":0" ;;
esac
export DISPLAY="$D" XAUTHORITY="$XA"

OUT="$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')"
[ -n "$OUT" ] || exit 0

# Prefer the forced boot mode from the kernel cmdline; fall back to 1080p60.
M="$(sed -n 's/.*video=HDMI-A-1:\([0-9]*x[0-9]*\)@\([0-9]*\).*/\1 \2/p' /proc/cmdline)"
W="${M% *}"; R="${M#* }"
[ -n "$W" ] && [ -n "$R" ] || { W=1920x1080; R=60; }

if xrandr --output "$OUT" --mode "$W" --rate "$R" 2>/dev/null \
   || xrandr --output "$OUT" --auto 2>/dev/null; then
  xset dpms force on 2>/dev/null
  logger -t h96-display-wake "re-drove $OUT (${W}@${R}); connector was connected but disabled"
  echo "h96-display-wake: re-drove $OUT (${W}@${R})"
else
  logger -t h96-display-wake "modeset on $OUT failed; output still down"
  echo "h96-display-wake: modeset on $OUT failed" >&2
  exit 1
fi
