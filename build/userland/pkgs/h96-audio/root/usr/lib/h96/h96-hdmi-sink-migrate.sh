#!/bin/bash
# h96-hdmi-sink-migrate.sh -- rewrite old HDMI sink node name to the current
# ACP name in a user's WirePlumber state (default-nodes, stream-properties).
# Exact substring rewrite only, no other content touched. Idempotent: no
# match, no write. Usage: h96-hdmi-sink-migrate.sh [HOME] (default: every
# home under /root and /home when no argument).
set -euo pipefail

OLD='alsa_output.platform-hdmi0-sound.playback.0.0'
NEW='alsa_output.platform-hdmi0-sound.hdmi-stereo'

migrate_one() {
  local home="$1" wpdir file
  wpdir="$home/.local/state/wireplumber"
  [ -d "$wpdir" ] || return 0
  for file in "$wpdir/default-nodes" "$wpdir/stream-properties"; do
    [ -f "$file" ] || continue
    grep -qF "$OLD" "$file" || continue
    python3 - "$file" "$OLD" "$NEW" <<'PY'
import os
import sys
path, old, new = sys.argv[1:4]
st = os.stat(path)
tmp = path + ".h96new"
with open(path, "r") as f:
    data = f.read()
with open(tmp, "w") as f:
    f.write(data.replace(old, new))
os.chmod(tmp, st.st_mode)
os.chown(tmp, st.st_uid, st.st_gid)
os.replace(tmp, path)
PY
    echo "migrated: $file"
  done
}

if [ $# -ge 1 ]; then
  migrate_one "$1"
else
  for h in /root /home/*; do
    [ -d "$h" ] || continue
    migrate_one "$h"
  done
fi
