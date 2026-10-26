#!/bin/bash
# F5 chroot install of h96 userland debs with every F5 row of f5-rows.sh (PARITY s5/s8); run inside image chroot.
# r8: set-aside check over whole tree, packaged-path check, optional selftest invariants.
# r9: nothing new under /usr/local after install and rows; first-boot scripts not run (no session).
# r10: run-time rewritten files are unowned seeds; dpkg -V stays clean after a rewrite.
# r11: deb names from inputs (one file per package), missing Depends from offline repo first, release-neutral seed checks.
# Debian edition (copy of rc-r15): rows file f5-rows-debian.sh; issue banner names v8.0 Debian Edition.
set -uo pipefail
export F5_LOG=/root/f5-log; L=$F5_LOG; D=/root/f5-in; mkdir -p "$L"
fail=0
declare -a ID PH AP GT
row() { ID+=("$1"); PH+=("$2"); AP+=("$3"); GT+=("$4"); }
# shellcheck source=/dev/null
. "$D/f5-rows-debian.sh"
echo "rows=${#ID[@]} pre=$(printf '%s\n' "${PH[@]}" | grep -cx pre) post=$(printf '%s\n' "${PH[@]}" | grep -cx post)"
gates() {  # tag: run every gate, count
  local i n=0 p=0
  for i in "${!ID[@]}"; do
    n=$((n + 1))
    if bash -c "${GT[$i]}" >/dev/null 2>&1; then echo "PASS $1 ${ID[$i]}"; p=$((p + 1)); else echo "FAIL $1 ${ID[$i]}"; fi
  done
  echo "$1 gates executed=$n pass=$p"
  [ "$n" = "${#ID[@]}" ] && [ "$p" = "$n" ]
}
apply() {  # phase
  local i
  for i in "${!ID[@]}"; do
    [ "${PH[$i]}" = "$1" ] || continue
    if [ "${AP[$i]}" = - ]; then echo "apply ${ID[$i]}: base"; continue; fi
    ( eval "${AP[$i]}" ); echo "apply ${ID[$i]} rc=$?"
  done
}
snap() {  # tag: /boot listing with sha, dpkg db sums
  find /boot -xdev -printf '%M %U:%G %s %p -> %l\n' | sort -k5 > "$L/boot-$1.lst"
  find /boot -xdev -type f -print0 | sort -z | xargs -0 sha256sum > "$L/boot-$1.sha"
  md5sum /var/lib/dpkg/status /var/lib/dpkg/diversions /var/lib/dpkg/statoverride > "$L/dpkgdb-$1.md5"
}
ROWFILES="/etc/adduser.conf /etc/default/cron /etc/dhcpcd.conf /etc/initramfs-tools/update-initramfs.conf
/etc/initramfs-tools/initramfs.conf /etc/sysctl.conf /etc/default/armbian-ramlog /etc/default/armbian-zram-config
/etc/default/cpufrequtils /etc/default/irqbalance /etc/environment /var/lib/dpkg/status"
echo "== policy-rc.d"
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
snap pre
dpkg -V > "$L/dpkg-V-pre.txt" 2>&1; echo "dpkg -V pre rc=$? lines=$(wc -l < "$L/dpkg-V-pre.txt")"
dpkg --audit > "$L/audit-pre.txt" 2>&1; echo "audit pre rc=$? lines=$(wc -l < "$L/audit-pre.txt")"
apt-get -s check > "$L/apt-check-pre.txt" 2>&1; echo "apt-get -s check pre rc=$?"
dpkg-divert --list | sort > "$L/divert-pre.txt"
for f in $ROWFILES; do cp "$f" "$L/pre-$(echo "${f#/}" | tr / _)"; done
ls -la /opt/panthor > "$L/opt-panthor-pre.txt" 2>&1
find /usr/local -xdev | sort > "$L/usr-local-pre.find"
echo "== gates before rows (base state, informational)"
gates base || true
echo "== pre rows"
apply pre
PKGS="h96-base h96-boot h96-net h96-audio h96-desktop h96-media h96-tools steam-arm-setup h96-gaming"
debof() { local m; m=$(compgen -G "$D/${1}_*.deb"); [ "$(printf '%s\n' "$m" | grep -c .)" = 1 ] && echo "$m"; }
DEBS=(); for p in $PKGS; do f=$(debof "$p") || { echo "FAIL input deb $p not exactly one"; exit 1; }; DEBS+=("$f"); done
echo "== Depends not in base, from offline repo"
python3 "$D/repo-closure.py" /var/lib/dpkg/status /opt/h96-pkgs/Packages --deb "${DEBS[@]}" --files > "$L/repo-deps.txt"; rc=$?
cat "$L/repo-deps.txt"; [ $rc = 0 ] || { echo "FAIL unresolved Depends"; exit 1; }
if [ -s "$L/repo-deps.txt" ]; then
  (cd /opt/h96-pkgs && xargs -a "$L/repo-deps.txt" -d '\n' dpkg -i) < /dev/null > "$L/install-repo-deps.txt" 2>&1; rc=$?
  echo "dpkg -i repo deps rc=$rc"; [ $rc = 0 ] || fail=1
else echo "repo deps: none"; fi
echo "== install (dependency order)"
for p in $PKGS; do
  f=$(debof "$p")
  dpkg -i "$f" < /dev/null > "$L/install-$p.txt" 2>&1; rc=$?
  echo "dpkg -i $p rc=$rc"; [ $rc = 0 ] || fail=1
done
grep -h 'files list file' "$L"/install-*.txt | sort -u | sed 's/^/install warn: /'
echo "== post rows (twice, second run must change nothing)"
apply post
for f in $ROWFILES; do sha256sum "$f"; done > "$L/rowfiles-1.sha"
apply post > /dev/null
for f in $ROWFILES; do sha256sum "$f"; done > "$L/rowfiles-2.sha"
cmp -s "$L/rowfiles-1.sha" "$L/rowfiles-2.sha" && echo "rows idempotent" || { echo "ROWS NOT IDEMPOTENT"; fail=1; }
for f in $ROWFILES; do cp "$f" "$L/post-$(echo "${f#/}" | tr / _)"; done
ls -la /opt/panthor > "$L/opt-panthor-post.txt" 2>&1
echo "== all gates after install and rows"
gates final || fail=1
echo "== enablement"
for u in h96-panthor-setup.service h96-gaming-setup.service h96-gpu-setup.service; do
  echo "$u: $(systemctl is-enabled "$u" 2>&1 | tr '\n' ' ')"
done
systemctl is-enabled -q h96-gaming-setup.service && systemctl is-enabled -q h96-gpu-setup.service && echo "PASS first-boot units enabled" || { echo "FAIL first-boot units enabled"; fail=1; }
echo "== dpkg checks"
dpkg -V h96-audio h96-base h96-boot h96-desktop h96-gaming h96-media h96-net h96-tools steam-arm-setup > "$L/dpkg-V-h96.txt" 2>&1; echo "dpkg -V h96-* rc=$? lines=$(wc -l < "$L/dpkg-V-h96.txt")"
dpkg -V > "$L/dpkg-V-post.txt" 2>&1; echo "dpkg -V all rc=$? lines=$(wc -l < "$L/dpkg-V-post.txt")"
dpkg --audit > "$L/audit-post.txt" 2>&1; echo "dpkg --audit rc=$? lines=$(wc -l < "$L/audit-post.txt")"
apt-get -s check > "$L/apt-check-post.txt" 2>&1; echo "apt-get -s check rc=$?"
dpkg-divert --list | sort > "$L/divert-post.txt"
dpkg-statoverride --list > "$L/statoverride-post.txt"
dpkg-query -W -f '${Package} ${Version} ${db:Status-Abbrev}\n' 'h96-*' steam-arm-setup > "$L/installed.txt"
find / -xdev -name '*.h96-v72' > "$L/saved-left.txt"; echo "saved .h96-v72 left: $(wc -l < "$L/saved-left.txt")"
[ -s "$L/saved-left.txt" ] && fail=1
dpkg-query -L h96-audio h96-base h96-boot h96-desktop h96-gaming h96-media h96-net h96-tools | grep -E '^/(usr/local|opt)(/|$)' > "$L/pkg-usrlocal-opt.txt"
echo "h96-* paths under /usr/local or /opt: $(wc -l < "$L/pkg-usrlocal-opt.txt")"; [ -s "$L/pkg-usrlocal-opt.txt" ] && fail=1
ls -la /usr/local/bin /usr/local/sbin /usr/local/lib /usr/local/share > "$L/usr-local-post.txt" 2>&1
find /usr/local -xdev | sort > "$L/usr-local-post.find"
comm -13 "$L/usr-local-pre.find" "$L/usr-local-post.find" > "$L/usr-local-new.txt"
echo "new paths under /usr/local: $(wc -l < "$L/usr-local-new.txt")"; [ -s "$L/usr-local-new.txt" ] && fail=1
echo "removed paths under /usr/local: $(comm -23 "$L/usr-local-pre.find" "$L/usr-local-post.find" | wc -l)"
if [ -f "$D/h96-selftest.py" ]; then
  python3 "$D/h96-selftest.py" invariants > "$L/selftest-invariants.txt" 2>&1; echo "selftest invariants rc=$? (informational: no booted session in chroot)"
  grep -E 'hardcoded usernames|literal home paths|scan scope|scan exception' "$L/selftest-invariants.txt"
fi
echo "== seeds (r10 on)"
R10S="/etc/h96-issue /etc/h96-issue.net /etc/alsa-card-profile/mixer/profile-sets/h96-hdmi.conf /etc/wireplumber/wireplumber.conf.d/51-h96-iec958.conf /usr/lib/firmware/edid/h96-sink-audio.bin"
for f in $R10S; do
  if [ -f "$f" ] && ! dpkg-query -S "$f" >/dev/null 2>&1; then echo "PASS seed unowned $f"; else echo "FAIL seed unowned $f"; fail=1; fi
done
grep -q "Unofficial Port v8\.0 Debian Edition)" /etc/h96-issue && ! grep -q beta /etc/h96-issue && echo "PASS h96-issue v8.0 Debian Edition" || { echo "FAIL h96-issue v8.0 Debian Edition"; fail=1; }
for f in $R10S; do cp -p "$f" "$f.f5bak"; echo "# run-time rewrite" >> "$f"; done
dpkg -V h96-audio h96-base h96-boot > "$L/dpkg-V-r10.txt" 2>&1
[ -s "$L/dpkg-V-r10.txt" ] && { echo "FAIL dpkg -V after rewrite"; cat "$L/dpkg-V-r10.txt"; fail=1; } || echo "PASS dpkg -V clean after run-time rewrite of seeds"
for f in $R10S; do mv -f "$f.f5bak" "$f"; done
echo "INFO silence $(grep -h 'priority.session' /etc/pipewire/pipewire.conf.d/95-h96-silence-source.conf | tr -s ' ')"
grep -q 'PPD_DSH=' /usr/lib/h96/h96-kde-configure.sh && echo "PASS kde-configure ppd preset guard" || { echo "FAIL kde-configure ppd guard"; fail=1; }
grep -q 'journalctl --header' /usr/lib/h96/h96-journal-orphans && echo "PASS journal-orphans r10" || { echo "FAIL journal-orphans r10"; fail=1; }
snap post
echo "== /boot diff (pre vs post)"
if cmp -s "$L/boot-pre.sha" "$L/boot-post.sha" && cmp -s "$L/boot-pre.lst" "$L/boot-post.lst"; then
  echo "boot unchanged ($(wc -l < "$L/boot-pre.lst") entries, $(wc -l < "$L/boot-pre.sha") files)"
else echo "BOOT CHANGED"; fail=1; fi
echo "fail=$fail"
exit $fail
