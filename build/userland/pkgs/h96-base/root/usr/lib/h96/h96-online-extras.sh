#!/bin/bash
# h96-online-extras.sh: retry best-effort, network-only packages until they install
#
# h96-gaming-setup.sh installs an offline group (gates the done-flag) and a best-effort
# online group (box64-rk3588, gamescope) that never gates, so one unreachable package
# cannot abort the whole apt transaction; but it tries the online group once, early in
# boot, and never again
#
# Ethernet PHY can take 20-190s to negotiate, so first boot often runs the online half
# before there is connectivity; network-online.target does not guarantee the link is up
#
# waits for connectivity, installs each package on its own so one failure cannot
# abort the rest, sets done-flag only once everything is present; anything missing is
# retried next boot. exits 0 either way so it never shows in systemctl --failed
set -uo pipefail

DONE=/var/lib/h96-online-extras-done
PKGS="box64-rk3588 gamescope libspa-0.2-modules-extra"
LOG=/var/log/h96-online-extras.log

exec > >(tee -a "$LOG") 2>&1
echo "=== h96-online-extras $(date -Is) ==="

all_present() {
  for p in $PKGS; do
    dpkg -s "$p" >/dev/null 2>&1 || return 1
  done
  return 0
}

if all_present; then
  echo "  all extras already installed"
  touch "$DONE"; exit 0
fi

# wait for connectivity, up to 5 minutes; PHY negotiation on this board can take up to 190s
echo "  waiting for connectivity..."
ok=0
for i in $(seq 1 60); do
  if getent hosts ports.ubuntu.com >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [ "$ok" -ne 1 ]; then
  echo "  no connectivity after 5 minutes, will retry on the next boot"
  exit 0
fi
echo "  connectivity is up after ~$(( i * 5 ))s"

# yield dpkg lock to anything holding it; armbian-firstrun wizard runs at this point
# on first boot, barging in kills it with "could not get frontend lock". retry next
# boot is free, same pattern as h96-gaming-setup.sh
echo "  waiting for dpkg lock..."
for i in $(seq 1 180); do
  # check all three locks, not only frontend: apt-get update takes /var/lib/apt/lists/lock,
  # which DPkg::Lock::Timeout does not cover; polling only dpkg lock lets update collide
  # with a concurrent apt (e.g. packagekitd) during first boot
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
        /var/lib/apt/lists/lock >/dev/null 2>&1 || break
  sleep 5
done

apt-get update -qq -o DPkg::Lock::Timeout=600 2>&1 | tail -3 || true

# one package at a time: apt transactions are atomic, a single unreachable package
# must not take the others down with it
for p in $PKGS; do
  if dpkg -s "$p" >/dev/null 2>&1; then
    echo "  [have] $p"
    continue
  fi
  if env DEBIAN_FRONTEND=noninteractive apt-get install -y \
       -o DPkg::Lock::Timeout=600 "$p" >/dev/null 2>&1; then
    echo "  [ ok ] $p"
  else
    echo "  [fail] $p (will retry next boot)"
  fi
done

if all_present; then
  echo "  all extras present, done"
  touch "$DONE"
else
  echo "  some extras still missing, will retry on the next boot"
fi
exit 0
