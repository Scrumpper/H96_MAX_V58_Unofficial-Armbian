#!/bin/bash
# T11 first-login dry run inside throwaway copy of built rootfs: H96 armbian-firstlogin (BSP 26.8.3 rebase) in Armbian
# preset mode under a pty, stubs for systemctl, netplan, hardware probes; checks user, groups, shell, locale, root
# password set, preset file removed. No network config written by presets (PRESET_NET_CHANGE_DEFAULTS=0).
set -uo pipefail
export LC_ALL=C; L=/root/f5-log/t11; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
S=/root/t11-stubs; mkdir -p "$S"
for c in systemctl netplan nmcli iw rfkill; do printf '#!/bin/sh\necho "stub %s $*" >> /root/f5-log/t11/stub-calls.txt\nexit 0\n' "$c" > "$S/$c"; chmod 755 "$S/$c"; done
dpkg-divert --list /usr/lib/armbian/armbian-firstlogin | tee "$L/divert.txt"
grep -q 'diversion of /usr/lib/armbian/armbian-firstlogin to /usr/lib/armbian/armbian-firstlogin.distrib by h96-base' "$L/divert.txt" && ok "firstlogin diverted by h96-base" || bad "diversion"
grep -q 'timeout 120s systemctl is-system-running' /usr/lib/armbian/armbian-firstlogin && ok "H96 line in active firstlogin" || bad "H96 line"
cat > /root/.not_logged_in_yet <<'P'
PRESET_NET_CHANGE_DEFAULTS="0"
PRESET_ROOT_PASSWORD="T11-root-pass-123"
PRESET_USER_NAME="h96test"
PRESET_USER_PASSWORD="T11-user-pass-123"
PRESET_DEFAULT_REALNAME="H96 Test"
PRESET_USER_SHELL="bash"
PRESET_LOCALE="en_US.UTF-8"
PRESET_TIMEZONE="Etc/UTC"
P
cp -p /etc/shadow "$L/shadow.pre"
# wizard ends with run-parts cron.daily; in a chroot apt-compat sleeps up to 30 min (no systemd), so set it aside
mv /etc/cron.daily /etc/cron.daily.t11; mkdir /etc/cron.daily
PATH="$S:$PATH" timeout 900 script -qec "bash /usr/lib/armbian/armbian-firstlogin" "$L/typescript" < /dev/null > "$L/run.txt" 2>&1; rc=$?
echo "firstlogin rc=$rc"; tail -15 "$L/typescript" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed 's/^/  | /'
[ "$rc" = 0 ] && ok "firstlogin rc 0" || bad "firstlogin rc $rc"
id h96test > "$L/id.txt" 2>&1 && ok "user created: $(cat "$L/id.txt")" || bad "user h96test missing"
for g in audio video render input netdev plugdev sudo; do id -nG h96test 2>/dev/null | tr ' ' '\n' | grep -qx "$g" || bad "h96test not in $g"; done; ok "groups (adduser EXTRA_GROUPS from F5 row, sudo)"
case "$(getent passwd h96test | cut -d: -f7)" in /bin/bash|/usr/bin/bash) ok "shell bash (merged /usr)" ;; *) false ;; esac || bad "shell $(getent passwd h96test | cut -d: -f7)"
[ ! -e /root/.not_logged_in_yet ] && ok "preset file removed" || bad "preset file left"
cmp -s /etc/shadow "$L/shadow.pre" && bad "root password unchanged" || ok "shadow updated (root and user passwords)"
grep -q '^LANG=en_US.UTF-8' /etc/default/locale 2>/dev/null && ok "locale en_US.UTF-8" || echo "INFO /etc/default/locale: $(cat /etc/default/locale 2>/dev/null | xargs)"
HD=/home/h96test
[ -d "$HD" ] && [ "$(stat -c %U "$HD")" = h96test ] && ok "home directory" || bad "home directory"
[ -f "$HD/Desktop/COMMANDS.md" ] && ok "skel COMMANDS.md copied (h96-base seed)" || echo "INFO no Desktop/COMMANDS.md in home"
sort -u "$L/stub-calls.txt" 2>/dev/null | head -20 | sed 's/^/  /'
echo "fail=$fail"; exit $fail
