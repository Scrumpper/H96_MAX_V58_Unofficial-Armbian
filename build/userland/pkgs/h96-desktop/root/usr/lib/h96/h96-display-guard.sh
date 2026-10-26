#!/bin/bash
# h96-display-guard: boot-once revert of an unconfirmed forced-mode trial (h96-display <mode>)
# Boot 1 after trial: marks it seen. Boot 2 still unconfirmed: video= back to lastgood, or
# removed when lastgood is absent (trial started without video=), then reboot.
GUARD_API=2   # h96-display checks this before a trial without video= (versioned together)
ENV="${H96_BOOT_ENV:-/boot/armbianEnv.txt}"
B="$(dirname "$ENV")"
TRIAL=$B/h96-display.trial
SEEN=$B/h96-display.trial.seen
LG=$B/h96-display.lastgood
LOCK="${H96_ENV_LOCK:-/run/lock/h96-armbianenv.lock}"   # shared armbianEnv writer lock
REBOOT="${H96_GUARD_REBOOT:-systemctl reboot}"

log() { [ "${H96_SELFTEST:-0}" = 1 ] || logger -t h96-display "$*" 2>/dev/null; }

replace() {  # $1 tmp $2 dst: fsync tmp, rename, fsync directory
  python3 -c 'import os, sys
t, d = sys.argv[1:3]
os.chmod(t, os.stat(d).st_mode & 0o7777)
fd = os.open(t, os.O_RDONLY); os.fsync(fd); os.close(fd)
os.replace(t, d)
fd = os.open(os.path.dirname(os.path.abspath(d)), os.O_RDONLY); os.fsync(fd); os.close(fd)' "$1" "$2" \
    2>/dev/null || { sync; mv -f "$1" "$2"; sync; }
}

[ -f "$TRIAL" ] || exit 0
mkdir -p "$(dirname "$LOCK")" 2>/dev/null
exec 8>"$LOCK"
flock -w 30 8 || log "armbianEnv lock busy; trial guard continues"
[ -f "$TRIAL" ] || exit 0
if [ -f "$SEEN" ]; then
  if grep -q '^extraargs=' "$ENV"; then
    lg="$(grep -o 'video=HDMI-A-1:[^ ]*' "$LG" 2>/dev/null | head -1)"
    awk -v lg="$lg" '/^extraargs=/ && !d {gsub(/ *video=HDMI-A-1:[^ ]*/, ""); print $0 (lg == "" ? "" : " " lg); d = 1; next}
      {print}' "$ENV" > "$ENV.h96guard" && replace "$ENV.h96guard" "$ENV"
    log "trial mode unconfirmed; reverted to ${lg:-no forced mode}"
  fi
  rm -f "$TRIAL" "$SEEN"
  flock -u 8
  $REBOOT
else
  : > "$SEEN"
fi
exit 0
