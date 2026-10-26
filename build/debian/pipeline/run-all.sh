#!/bin/bash
# Whole Debian edition image pipeline after base and repo stages: prep, dryrun, build, assemble, loader + pack, tests.
# Each stage under systemd-run scope (MemoryMax=20G, CPUQuota 600%, nice 10) and heavy lock. Logs in $EVR/*.log.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; EV=$EVR; mkdir -p "$EV"; LOCK=${H96_HEAVY_LOCK:-$W/heavy.lock}
run() { flock "$LOCK" systemd-run --user --scope -q -p MemoryMax=20G -p CPUQuota=600% nice -n10 bash "$H/$1" "${@:2}" > "$EV/${1%.sh}.log" 2>&1 || { echo "$1 FAILED (see $EV/${1%.sh}.log)"; tail -20 "$EV/${1%.sh}.log"; exit 1; }; echo "$1 ok"; }
for s in "$@"; do run "$s"; done
