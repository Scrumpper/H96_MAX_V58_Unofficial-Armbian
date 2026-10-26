#!/bin/sh
# h96-display-wake: re-drive HDMI output when connector is connected but not enabled
#
# HDMI PHY/VOP path is not reinitialised automatically after DPMS-off or a power-cycle:
# kernel logs "User-defined mode not supported" on re-probe and connector stays
# enabled=disabled while X believes monitor is on. explicit X modeset re-drives it
#
# callers: h96-display-wake.service (key/button press), udev hotplug rule
# (97-h96-display-wake.rules via h96-display-wake-once.service), manual "h96-display wake".
# no-op when output is healthy or returns within H96_WAKE_WAIT seconds (default 8)

CON="${H96_DRM_CONN:-/sys/class/drm/card0-HDMI-A-1}"   # H96_*: host test overrides
CMDLINE="${H96_CMDLINE:-/proc/cmdline}"
UNPLUG="${H96_UNPLUG:-/run/h96-hdmi-unplugged}"

x_env() {
  XA=""
  # active session first (h96-xdisplay); Wayland: KWin drives the output
  if [ -z "${H96_XAUTH:-}" ] && [ -r /usr/lib/h96/h96-xdisplay ]; then
    . /usr/lib/h96/h96-xdisplay
    if h96_xdisplay; then
      [ "$H96_XD_TYPE" = x11 ] || return 1
      if [ -n "$H96_XD_XAUTH" ] && [ -f "$H96_XD_XAUTH" ]; then
        export DISPLAY="$H96_XD_DISPLAY" XAUTHORITY="$H96_XD_XAUTH"; return 0
      fi
    fi
  fi
  for f in ${H96_XAUTH:-/var/run/lightdm/root/:* /root/.Xauthority}; do
    [ -f "$f" ] && { XA="$f"; break; }
  done
  [ -n "$XA" ] || return 1   # no X server (console or Wayland)
  case "$XA" in
    */:*) D=":${XA##*/:}" ;;
    *)    D=":0" ;;
  esac
  export DISPLAY="$D" XAUTHORITY="$XA"
}

# Plasma Wayland: KWin DPMS on through kscreen-doctor as session user; rc 1 = no Wayland session
wl_dpms_on() {
  [ -z "${H96_XAUTH:-}" ] && [ -r /usr/lib/h96/h96-xdisplay ] || return 1
  . /usr/lib/h96/h96-xdisplay
  h96_xdisplay && [ "$H96_XD_TYPE" = wayland ] || return 1
  h96_session_run kscreen-doctor --dpms on >/dev/null 2>&1
}

# hotplug: remember a disconnect; on the next connect (TV powered on) turn a blanked display back on
st="$(cat "$CON/status" 2>/dev/null)"
if [ "$st" = disconnected ]; then
  touch "$UNPLUG"; exit 0
fi
if [ "$st" = connected ] && [ -e "$UNPLUG" ] && [ "$(cat "$CON/enabled" 2>/dev/null)" = enabled ]; then
  rm -f "$UNPLUG"
  if wl_dpms_on; then
    logger -t h96-display-wake "display on after HDMI reconnect (KWin DPMS)"
  elif x_env && xset q 2>/dev/null | grep -q "Monitor is Off"; then
    xset dpms force on 2>/dev/null && logger -t h96-display-wake "display on after HDMI reconnect"
  fi
fi

dead() {
  [ -d "$CON" ] || return 1
  [ "$(cat "$CON/status" 2>/dev/null)" = connected ] || return 1
  [ "$(cat "$CON/enabled" 2>/dev/null)" = disabled ]
}

dead || exit 0

# output often returns by itself (TV wake, desktop DPMS-on): poll first; needless modeset drops
# RandR output and X clients can exit on it (Steam client signal 11 after long screen-off)
WAIT="${H96_WAKE_WAIT:-8}"; n=0
while [ "$n" -lt $((WAIT * 2)) ]; do
  sleep 0.5; n=$((n + 1))
  dead && continue
  t="$((n / 2)).$((n % 2 * 5))"
  if [ "$(cat "$CON/status" 2>/dev/null)" = connected ] && grep -q . "$CON/modes" 2>/dev/null; then
    logger -t h96-display-wake "output returned on its own after ${t} s (connected, enabled, $(grep -c . "$CON/modes") modes); no re-drive"
  else
    logger -t h96-display-wake "connector $(cat "$CON/status" 2>/dev/null || echo absent) after ${t} s; no re-drive"
  fi
  exit 0
done
if wl_dpms_on; then
  logger -t h96-display-wake "output still disabled after ${WAIT} s; Wayland: KWin DPMS on requested, no modeset re-drive"
  exit 0
fi
logger -t h96-display-wake "output still connected but disabled after ${WAIT} s; re-driving"

# X server auth: lightdm keeps running server's auth under /var/run/lightdm/root/:<display>
x_env || exit 0

OUT="$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')"
[ -n "$OUT" ] || exit 0

# forced boot mode from kernel cmdline first; no video= (DVI profile): display's preferred
# mode first (1920x1080 is not listed on most DVI displays), 1080p60 last
M="$(sed -n 's/.*video=HDMI-A-1:\([0-9]*x[0-9]*\)@\([0-9]*\).*/\1 \2/p' "$CMDLINE")"
if [ -n "$M" ]; then
  W="${M% *}"; R="${M#* }"; HOW="${W}@${R}"
  xrandr --output "$OUT" --mode "$W" --rate "$R" 2>/dev/null \
    || { HOW=auto; xrandr --output "$OUT" --auto 2>/dev/null; }
  rc=$?
else
  HOW=auto
  xrandr --output "$OUT" --auto 2>/dev/null \
    || { HOW=1920x1080@60; xrandr --output "$OUT" --mode 1920x1080 --rate 60 2>/dev/null; }
  rc=$?
fi
if [ "$rc" -eq 0 ]; then
  xset dpms force on 2>/dev/null
  logger -t h96-display-wake "re-drove $OUT ($HOW); connector was connected but disabled"
  echo "h96-display-wake: re-drove $OUT ($HOW)"
else
  logger -t h96-display-wake "modeset on $OUT failed; output still down"
  echo "h96-display-wake: modeset on $OUT failed" >&2
  exit 1
fi
