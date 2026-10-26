#!/bin/bash
# Stage 4 repo download, inside prepped trixie rootfs (network): closure of first-boot offline set, Mesa at backports
# version, h96 rebuilt WirePlumber and carried Rockchip/box64 debs, against this rootfs state. Nothing installed.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
I=/root/f5-in; L=/root/f5-log/repo; A=/root/repo-dl; mkdir -p "$L" "$A/partial"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
MESA=26.1.6-1~bpo13+1
rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
# box64/box86 sources need keyrings from h96-gaming (not installed yet): left out of this run
S=/root/repo-srcd; mkdir -p "$S"; cp /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/armbian.sources /etc/apt/sources.list.d/armbian-config.sources "$S/"
# Mesa pin of h96-base Debian edition for this run, so every libgbm1/mesa dependency resolves to the backports build
install -m 0644 "$I/01-h96-protect-mesa" /etc/apt/preferences.d/01-h96-protect-mesa
apt_() { apt-get -o Acquire::PDiffs=false -o Dir::Cache::archives="$A" -o Dir::Etc::sourceparts="$S" "$@"; }
apt_ update > "$L/update.txt" 2>&1 && ok "apt-get update" || bad "update: $(grep -m2 '^[EW]:' "$L/update.txt")"
cp -a /var/lib/apt/lists "$L/lists"
WANT=$(grep -v '^#' "$I/repo-wanted.txt" | xargs)
MESA_PK=$(xargs < "$I/repo-mesa.txt")
LOCAL=""; for f in "$I"/local/*.deb; do case "$f" in *_armhf.deb) ;; *) LOCAL="$LOCAL $f" ;; esac; done
# shellcheck disable=SC2086
apt_ install -y --download-only $MESA_PK $WANT $LOCAL > "$L/dl-rest.txt" 2>&1 && ok "offline set closure downloaded" || bad "rest: $(grep -m3 '^E:' "$L/dl-rest.txt")"
# shellcheck disable=SC2086
apt_ install -s $MESA_PK $WANT $LOCAL > "$L/sim-rest.txt" 2>&1; grep '^Inst' "$L/sim-rest.txt" > "$L/inst-rest.txt" || true
ls "$A"/*.deb | wc -l | sed 's/^/debs downloaded: /'
for p in $MESA_PK; do ls "$A/${p}_"*"$(echo "$MESA" | sed 's/:/%3a/')"_arm64.deb >/dev/null 2>&1 && ok "$p $MESA present" || bad "$p $MESA missing"; done
rm -f /etc/apt/preferences.d/01-h96-protect-mesa; rm -rf /var/lib/apt/lists/* "$S"; mkdir -p /var/lib/apt/lists/partial
echo "fail=$fail"; exit $fail
