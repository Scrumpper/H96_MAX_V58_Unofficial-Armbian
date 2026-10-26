#!/bin/bash
# Inside image chroot after repo step, F5, kernel stage and branding: all gates again, dpkg state, units, mali, /boot; removes policy-rc.d.
# r11: 12 packages (kernel switch, Steam ARM 3.0), kernel switch off, branding, journald fix, offline repo, machine-id.
# r15: kernel release from stage file krel; h96-wol.service not enabled; no rfcomm.ko outside module trees.
# r16: 14 packages (default + fallback kernel/DTB), 6.12 DTB gates, .dtb.6.1, v7.2 kernel gone, armbianEnv tokens, first-boot units.
# r26: modules-load entries exist in both kernels, no h96-bcmdhd.conf, rpc_pipefs mount not masked (r27), lxc-net not enabled.
# r30 (Steam ARM 3.1 final): packaged install.sh = install.sh in staged steam-arm-setup deb.
# r29 (userland r39: Bluetooth autoswitch off, COMMANDS Steam ARM 3.1); r28 (userland r38, Steam ARM 3.1): COMMANDS.md line count per userland version; first-login wizard waits for first-boot reboot; no r36 getty/ssh drop-ins.
set -uo pipefail
export F5_LOG=/root/f5-log; L=/root/f5-log/final; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
declare -a ID GT; row() { ID+=("$1"); GT+=("$4"); }
. /root/f5-in/f5-rows.sh
# kernel switch r14+ saved trees (hard links of package module trees) hold rfcomm.ko by design: s8-rfcomm-stash gate re-run without them
KSS=/var/lib/h96-kernel-switch/modules
p=0; for i in "${!ID[@]}"; do
  if bash -c "${GT[$i]}" >/dev/null 2>&1; then p=$((p+1))
  elif [ "${ID[$i]}" = s8-rfcomm-stash ] && test ! -e /usr/local/lib/h96/rfcomm.ko && [ -z "$(find / -xdev -name rfcomm.ko -not -path '/usr/lib/modules/*' -not -path "$KSS/*" 2>/dev/null | head -1)" ]; then
    p=$((p+1)); echo "PASS gate s8-rfcomm-stash with kernel switch saved trees excluded ($KSS)"
  else bad "gate ${ID[$i]}"; fi
done
echo "F5 gates ${p}/${#ID[@]}"; [ "$p" = "${#ID[@]}" ] || fail=1
K=$(cat /root/f5-in/krel 2>/dev/null || echo 6.12.69-h96v58-8.0); FB=$(cat /root/f5-in/fbkrel 2>/dev/null || echo none); echo "kernel release $K, fallback $FB"
dpkg --audit > "$L/audit.txt" 2>&1; [ ! -s "$L/audit.txt" ] && ok "dpkg --audit empty" || bad "dpkg --audit"
PK="h96-audio h96-base h96-boot h96-desktop h96-gaming h96-media h96-net h96-tools steam-arm-setup h96-kernel-$K h96-dtb-$K h96-kernel-switch"
[ "$FB" != none ] && PK="$PK h96-kernel-$FB h96-dtb-$FB"
NP=$(echo $PK | wc -w)
# shellcheck disable=SC2086
dpkg -V $PK > "$L/dpkg-V-h96.txt" 2>&1
[ ! -s "$L/dpkg-V-h96.txt" ] && ok "dpkg -V $NP packages empty" || bad "dpkg -V h96"
dpkg -V > "$L/dpkg-V-all.txt" 2>&1; echo "dpkg -V all lines=$(wc -l < "$L/dpkg-V-all.txt")"
apt-get -s check > "$L/apt-check.txt" 2>&1 && ok "apt-get -s check" || bad "apt-get -s check"
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' 'h96-*' steam-arm-setup > "$L/installed.txt"; cat "$L/installed.txt"
[ "$(grep -c '^ii ' "$L/installed.txt")" = "$NP" ] && [ "$(wc -l < "$L/installed.txt")" = "$NP" ] && ok "$NP packages ii" || bad "package count"
for p in $PK; do grep -Eq "^ii +$p " "$L/installed.txt" || bad "$p not ii"; done
[ "$(dpkg-query -W -f '${Version}' steam-arm-setup)" = 3.1 ] && ok "steam-arm-setup 3.1" || bad "steam-arm-setup version"
# r30: packaged install.sh = install.sh extracted from staged (pinned) deb
SD=(/root/f5-in/steam-arm-setup_*_arm64.deb); sx=$(mktemp -d)
if [ "${#SD[@]}" = 1 ] && [ -f "${SD[0]}" ] && [ -f /usr/share/steam-arm-setup/install.sh ] && dpkg-deb -x "${SD[0]}" "$sx" && [ -f "$sx/usr/share/steam-arm-setup/install.sh" ]; then
  a=$(sha256sum < /usr/share/steam-arm-setup/install.sh | cut -d' ' -f1); b=$(sha256sum < "$sx/usr/share/steam-arm-setup/install.sh" | cut -d' ' -f1)
  [ "$a" = "$b" ] && ok "Steam ARM install.sh = deb ${a:0:8} (${SD[0]##*/})" || bad "Steam ARM install.sh ${a:0:8} differs from deb ${b:0:8}"
else bad "Steam ARM install.sh or staged steam-arm-setup deb missing"; fi
rm -rf "$sx"
grep -qx 'SA_VERSION=3.1' /usr/share/steam-arm-setup/install.sh && ok "SA_VERSION=3.1" || bad "SA_VERSION"
systemctl list-unit-files --state=enabled --no-legend --no-pager > "$L/enabled-units.txt" 2>&1; echo "enabled units: $(wc -l < "$L/enabled-units.txt")"
grep -i 'panthor-setup' "$L/enabled-units.txt" && bad "h96-panthor-setup enabled" || ok "no h96-panthor-setup enabled"
if dpkg --compare-versions "$(dpkg-query -W -f '${Version}' h96-kernel-switch)" ge 8.0.0~r14; then
  # r14: modules unit enabled at first saved tree (postinst in image); guard and confirm timer stay off
  grep 'h96-kernel-switch' "$L/enabled-units.txt" | grep -v '^h96-kernel-switch-modules.service' && bad "kernel switch guard or timer enabled" || ok "kernel switch guard and timer disabled"
  systemctl is-enabled -q h96-kernel-switch-modules.service && ok "h96-kernel-switch-modules.service enabled (saved tree mount at boot)" || bad "h96-kernel-switch-modules.service not enabled"
  for r in $K $([ "$FB" != none ] && echo "$FB"); do
    d=/var/lib/h96-kernel-switch/modules/$r/$(sha256sum < "/usr/lib/h96-kernel/$r/Image" | cut -c1-16)
    [ -f "$d/meta" ] && [ -d "$d/tree" ] && ok "saved module tree $r ${d##*/} ($(find "$d/tree" -name '*.ko*' | wc -l) ko)" || bad "saved module tree $r missing"
  done
  [ ! -e /var/lib/h96-kernel-switch/trial ] && ok "no kernel switch trial record" || bad "kernel switch trial record"
  grep -q 'snapshot-modules' /etc/apt/apt.conf.d/80h96-kernel-switch && ok "apt Pre-Invoke hook present" || bad "apt Pre-Invoke hook missing"
  # r15+: kernel switch init-bottom scripts inside image uInitrd of each release (legacy u-boot header 64 B)
  for b in $(dpkg -L h96-kernel-switch | grep '/initramfs-tools/scripts/init-bottom/.'); do
    for r in $K $([ "$FB" != none ] && echo "$FB"); do
      # list to file first: grep -q closing the pipe early reads as failure under pipefail
      tail -c +65 "/boot/uInitrd-$r" > /tmp/fc-initrd && lsinitramfs /tmp/fc-initrd > /tmp/fc-initrd.lst 2>/dev/null
      grep -qx "${b#*/initramfs-tools/}" /tmp/fc-initrd.lst && ok "uInitrd-$r holds ${b#*/initramfs-tools/}" || bad "uInitrd-$r lacks ${b#*/initramfs-tools/}"
    done
  done; rm -f /tmp/fc-initrd /tmp/fc-initrd.lst
  # r15: tools copied by initramfs hook; staged.meta per release (SIG has build-tree inode: stale after mke2fs -d, init-bottom then defers to boot unit; refreshed by next snapshot-modules)
  if dpkg --compare-versions "$(dpkg-query -W -f '${Version}' h96-kernel-switch)" ge 8.0.0~r15; then
    for r in $K $([ "$FB" != none ] && echo "$FB"); do
      tail -c +65 "/boot/uInitrd-$r" > /tmp/fc-initrd; lsinitramfs /tmp/fc-initrd 2>/dev/null > "$L/uinitrd-$r.lst"
      m=/var/lib/h96-kernel-switch/modules/$r/staged.meta
      if dpkg --compare-versions "$(dpkg-query -W -f '${Version}' h96-kernel-switch)" ge 8.0.0~r16; then
        # r16: exactly one hex dumper (no file over 1 MiB), staged.meta with note offsets
        x=$(grep '^usr/libexec/h96-kernel-switch/.' "$L/uinitrd-$r.lst" | grep -v '\.so' | xargs)
        case "$x" in usr/libexec/h96-kernel-switch/od|usr/libexec/h96-kernel-switch/hexdump) ok "uInitrd-$r holds one dumper: $x" ;; *) bad "uInitrd-$r dumper set: '$x'" ;; esac
        mkdir -p /tmp/fc-x && (cd /tmp/fc-x && zcat /tmp/fc-initrd | cpio -id --quiet 2>/dev/null)
        big=$(find /tmp/fc-x/usr/libexec/h96-kernel-switch -type f -size +1024k 2>/dev/null | head -1); rm -rf /tmp/fc-x
        [ -z "$big" ] && ok "uInitrd-$r kernel switch files under 1 MiB" || bad "uInitrd-$r large file $big"
        grep -q '^OFFS=.' "$m" 2>/dev/null && [ -n "$(sed -n 's/^IDS=//p' "$m")" ] && ok "staged.meta $r OFFS $(sed -n 's/^OFFS=//p' "$m")" || bad "staged.meta $r lacks OFFS or IDS"
      else
        n=0; for t in od stat mount sed grep cut tr basename; do grep -qx "usr/libexec/h96-kernel-switch/$t" "$L/uinitrd-$r.lst" && n=$((n+1)) || bad "uInitrd-$r lacks usr/libexec/h96-kernel-switch/$t"; done
        [ "$n" = 8 ] && ok "uInitrd-$r holds 8 kernel switch tools"
        grep -q '^SIG=' "$m" 2>/dev/null && [ -n "$(sed -n 's/^IDS=//p' "$m")" ] && ok "staged.meta $r ($(sed -n 's/^IDS=//p' "$m" | cut -c1-16))" || bad "staged.meta $r missing or empty"
      fi
      sz=$(stat -c %s "/boot/uInitrd-$r"); echo "uInitrd-$r $sz B, load end $(printf '0x%08x' $((0x0a200000 + sz)))"
      [ "$sz" -le 29628434 ] && ok "uInitrd-$r $sz B, load end within rc-r15 end 0x0bd41812 + 1 MiB" || bad "uInitrd-$r $sz B (rc-r17 6.12 24475147, 6.1 28579858)"
    done; rm -f /tmp/fc-initrd
  fi
else
  grep 'h96-kernel-switch' "$L/enabled-units.txt" && bad "kernel switch unit enabled" || ok "kernel switch units disabled"
  [ -z "$(find /etc/systemd/system -name 'h96-kernel-switch*' 2>/dev/null)" ] && [ ! -e /var/lib/h96-kernel-switch ] && ok "no kernel switch links or state" || bad "kernel switch links or state"
fi
# WoL opt-in: unit installed, never enabled in image
[ -f /usr/lib/systemd/system/h96-wol.service ] && ok "h96-wol.service installed" || bad "h96-wol.service missing"
st=$(systemctl is-enabled h96-wol.service 2>&1); [ "$st" = disabled ] && ok "h96-wol.service disabled" || bad "h96-wol.service $st"
[ -z "$(find /etc/systemd/system -name h96-wol.service 2>/dev/null)" ] && ok "no h96-wol.service link" || bad "h96-wol.service link: $(find /etc/systemd/system -name h96-wol.service | head -1)"
# v7.2 6.1.115 rfcomm.ko stash dropped (F5 row s8-rfcomm-stash)
find / -xdev -name rfcomm.ko -not -path '/usr/lib/modules/*' -not -path "$KSS/*" 2>/dev/null > "$L/rfcomm-left.txt"
[ ! -s "$L/rfcomm-left.txt" ] && [ ! -e /usr/local/lib/h96 ] && ok "no rfcomm.ko stash, /usr/local/lib/h96 gone" || { cat "$L/rfcomm-left.txt"; bad "rfcomm.ko stash or /usr/local/lib/h96 left"; }
# empty machine-id: no first-boot preset-all (would enable units without preset rule)
[ -f /etc/machine-id ] && [ ! -s /etc/machine-id ] && ok "machine-id empty (no first-boot presets)" || bad "machine-id: $(head -c 40 /etc/machine-id 2>&1)"
systemctl is-enabled -q h96-branding.service && systemctl is-enabled -q h96-branding.path && ok "h96-branding units enabled" || bad "h96-branding units"
find / -xdev \( -name 'h96-panthor-setup*' -o -name 'h96-panthor-firstboot*' -o -name 'panthor-deploy.sh' \) 2>/dev/null > "$L/panthor-left.txt"
[ ! -s "$L/panthor-left.txt" ] && ok "no h96-panthor-setup files" || { cat "$L/panthor-left.txt"; bad "panthor-setup files left"; }
find / -xdev \( -iname '*libmali*' -o -name 'mali.json' -o -name '00-aarch64-mali.conf' -o -name 'gbm_shim.so' \) 2>/dev/null > "$L/mali-left.txt"
[ ! -s "$L/mali-left.txt" ] && ok "no libmali files (repo included)" || { cat "$L/mali-left.txt"; bad "libmali files left"; }
dpkg-query -W 'libmali*' > /dev/null 2>&1 && bad "libmali package installed" || ok "no libmali package"
ldconfig -p > "$L/ldconfig.txt" 2>&1; grep -qi libmali "$L/ldconfig.txt" && bad "ldconfig libmali" || ok "ldconfig clean"
grep -qi mali /etc/environment && bad "/etc/environment mali" || ok "/etc/environment no mali"
[ ! -e /boot/extlinux ] && ok "no /boot/extlinux" || bad "/boot/extlinux"
[ "$(readlink /boot/Image)" = "Image-$K" ] && [ "$(readlink /boot/uInitrd)" = "uInitrd-$K" ] && ok "boot links on $K" || bad "boot links"
[ -f /etc/apt/preferences.d/00-h96-protect-boot ] && ok "apt pin present" || bad "apt pin"
DT=/boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb
[ "$(fdtget -t s "$DT" /watchdog@feaf0000 status 2>/dev/null)" = okay ] && ok "DTB watchdog okay" || bad "DTB watchdog not okay"
cmp -s "$DT" "/usr/lib/h96-kernel/$K/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb" && ok "board DTB = $K DTB" || bad "board DTB not $K"
case "$K" in 6.12.*)
  dtc -I dtb -O dts "$DT" 2>/dev/null > "$L/board-dtb.dts"
  [ -s "$L/board-dtb.dts" ] && ! grep -q 'wl_reg_on_hog' "$L/board-dtb.dts" && ok "6.12 DTB has no wl_reg_on_hog" || bad "6.12 DTB wl_reg_on_hog or dtc"
  fdtget "$DT" /wireless-wlan WIFI,poweren-gpios > /dev/null 2>&1 && ok "6.12 DTB WIFI,poweren-gpios" || bad "6.12 DTB WIFI,poweren-gpios" ;;
esac
if [ "$FB" != none ]; then
  cmp -s "$DT.6.1" "/usr/lib/h96-kernel/$FB/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb" && ok ".dtb.6.1 = $FB DTB ($(sha256sum < "$DT.6.1" | cut -c1-8))" || bad ".dtb.6.1"
  [ -f "/boot/Image-$FB" ] && [ -f "/boot/uInitrd-$FB" ] && [ -s "/usr/lib/modules/$FB/modules.dep.bin" ] && ok "fallback $FB Image, uInitrd, modules" || bad "fallback $FB files"
fi
[ ! -e /boot/Image-6.1.172-h96v58-7.1 ] && [ ! -e /boot/uInitrd-6.1.172-h96v58-7.1 ] && [ ! -e "$DT.v7.2" ] && [ ! -e /usr/lib/modules/6.1.172-h96v58-7.1 ] && ok "v7.2 kernel removed" || bad "v7.2 kernel files left"
ls /usr/lib/modules > "$L/module-trees.txt"; echo "module trees: $(xargs < "$L/module-trees.txt")"
nr=1; [ "$FB" != none ] && nr=2
[ "$(find /boot -maxdepth 1 -name 'Image-*' | wc -l)" = "$nr" ] && [ "$(find /boot -maxdepth 1 -name 'uInitrd-*' | wc -l)" = "$nr" ] && ok "/boot holds $nr kernel generations: $(find /boot -maxdepth 1 -name 'Image-*' -printf '%f ')" || bad "/boot kernel file count"
# armbianEnv: image default forced EDID and mode tokens, board DTB name
E=/boot/armbianEnv.txt; cp "$E" "$L/armbianEnv.txt"
grep -qx 'fdtfile=rockchip/rk3588-h96-max-v58-panthor.dtb' "$E" && ok "armbianEnv fdtfile" || bad "armbianEnv fdtfile"
grep -q '^extraargs=.* drm\.edid_firmware=HDMI-A-1:edid/h96-sink-audio\.bin' "$E" && [ -f /usr/lib/firmware/edid/h96-sink-audio.bin ] && ok "armbianEnv forced EDID token, blob present" || bad "armbianEnv forced EDID token"
grep -q '^extraargs=.* video=HDMI-A-1:1920x1080@60' "$E" && ok "armbianEnv video= token" || bad "armbianEnv video= token"
grep -q "^rootdev=UUID=$(findmnt -no UUID / 2>/dev/null || true)" "$E" || echo "INFO rootdev $(grep ^rootdev= "$E")"
# h96-cec on by default from userland r20 (owner 2026-10-21): device-bound enable link
v=$(dpkg-query -W -f '${Version}' h96-media 2>/dev/null)
if dpkg --compare-versions "$v" ge 8.0.0~r20; then
  [ "$(readlink /etc/systemd/system/dev-cec0.device.wants/h96-cec.service 2>/dev/null)" = /usr/lib/systemd/system/h96-cec.service ] && ok "h96-cec enabled on dev-cec0.device" || bad "h96-cec device enable link: $(ls -l /etc/systemd/system/dev-cec0.device.wants/ 2>&1 | tail -1)"
  [ ! -e /etc/systemd/system/multi-user.target.wants/h96-cec.service ] && ok "no multi-user h96-cec link" || bad "multi-user h96-cec link"
fi
# h96-vulkan-wsi (offline repo add, r25): in repo, not installed (opt-in)
if [ -s /root/f5-in/repo/add.sha256 ] && grep -q 'h96-vulkan-wsi_' /root/f5-in/repo/add.sha256; then
  ls /opt/h96-pkgs/h96-vulkan-wsi_*.deb > /dev/null 2>&1 && ! dpkg-query -W h96-vulkan-wsi > /dev/null 2>&1 && ok "h96-vulkan-wsi in offline repo, not installed" || bad "h96-vulkan-wsi repo or install state"
fi
# userland r28: mpv MPRIS plugin and CEC Back/Return keys
echo "ed48470207b66110b79c0d0f7d4b7c768f87c6287de21ab9b76802a0f412f638  /usr/lib/h96/mpv-mpris/mpris.so" | sha256sum -c --status 2>/dev/null && ok "mpv-mpris mpris.so ed484702" || bad "mpv-mpris mpris.so missing or sha"
if dpkg --compare-versions "$(dpkg-query -W -f '${Version}' h96-media)" ge 8.0.0~r33; then
  # r33: Lua loader loads plugin only with session bus; no direct .so link in scripts dir
  ML=01078c6de3ef83b419adb4f968a314172093864629bbe4e82649ef735d6c9976   # r33
  dpkg --compare-versions "$(dpkg-query -W -f '${Version}' h96-media)" ge 8.0.0~r34 && ML=65f9291aab4969cd2b7a7e654491f016ad852be005259a8923556ef90e8903b9   # r34: bus socket reachability check
  echo "$ML  /etc/mpv/scripts/h96-mpris.lua" | sha256sum -c --status 2>/dev/null && ok "h96-mpris.lua loader ${ML:0:8}" || bad "h96-mpris.lua missing or sha (want ${ML:0:8})"
  [ ! -e /etc/mpv/scripts/h96-mpris.so ] && [ ! -L /etc/mpv/scripts/h96-mpris.so ] && ok "no /etc/mpv/scripts/h96-mpris.so link" || bad "h96-mpris.so link still present"
  if command -v mpv > /dev/null 2>&1; then
    timeout 3 env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR=/nonexistent mpv --no-config --script=/etc/mpv/scripts/h96-mpris.lua --idle=no --vo=null --ao=null av://lavfi:anullsrc=d=0.1 > "$L/mpv-nobus.txt" 2>&1
    [ "$?" != 124 ] && ok "mpv without session bus exits within 3 s" || bad "mpv without session bus hangs"
  else echo "INFO mpv not in image rootfs (video stack extracted at first boot): 3 s no-bus test not run, file gates only"; fi
else
  [ "$(readlink /etc/mpv/scripts/h96-mpris.so)" = /usr/lib/h96/mpv-mpris/mpris.so ] && ok "/etc/mpv/scripts/h96-mpris.so link" || bad "h96-mpris.so link"
fi
grep -Eq '^back[[:space:]]*=[[:space:]]*KEY_ESC([[:space:]]|$)' /etc/h96/cec-keymap.conf && grep -Eq '^return[[:space:]]*=[[:space:]]*KEY_ESC([[:space:]]|$)' /etc/h96/cec-keymap.conf && ok "cec-keymap back and return = KEY_ESC" || bad "cec-keymap back/return"
# userland r29 / switch r17: no internal labels in h96 docs, man pages, /etc/h96 (Debian changelog.gz keeps package versions; ravu-lite-ar-r4 is a name)
{ dpkg-query -W -f '${Package}\n' 'h96-*' | xargs dpkg-query -L 2>/dev/null | grep -E '^/usr/share/(doc|man)/' ; find /etc/h96 -type f 2>/dev/null; } | sort -u |
  while read -r f; do [ -f "$f" ] && [ ! -L "$f" ] && case "$f" in */changelog*.gz) ;; *) echo "$f" ;; esac; done > "$L/label-scan-files.txt"
: > "$L/label-hits.txt"
while read -r f; do zgrep -HnE '8\.0\.0|\br[0-9]+\b' "$f" 2>/dev/null | grep -vE 'ravu(\\)?-lite(\\)?-ar(\\)?-r4' >> "$L/label-hits.txt"; done < "$L/label-scan-files.txt"
[ ! -s "$L/label-hits.txt" ] && ok "no 8.0.0 or rN label in $(wc -l < "$L/label-scan-files.txt") h96 doc, man and /etc/h96 files" || { head -5 "$L/label-hits.txt"; bad "internal labels in docs ($(wc -l < "$L/label-hits.txt") lines, $L/label-hits.txt)"; }
# first-boot units (enabled in image, run once on box)
for u in armbian-firstrun.service h96-firstboot.service h96-gaming-setup.service h96-gpu-setup.service h96-video-setup.service; do
  systemctl is-enabled -q "$u" && ok "first-boot $u enabled" || bad "first-boot $u not enabled"
done
# userland r37 (h96-base): wizard guard in armbian-firstlogin (waits while first-boot reboot pending); r36 getty@tty1/ssh drop-ins gone (ordering cycle with armbian-firstrun)
bv=$(dpkg-query -W -f '${Version}' h96-base)
if dpkg --compare-versions "$bv" ge 8.0.0~r37; then
  n=$(grep -c 'h96_fb_pending' /usr/lib/armbian/armbian-firstlogin 2>/dev/null); n=${n:-0}
  [ "$n" = 3 ] && ok "armbian-firstlogin first-boot guard (h96_fb_pending x3)" || bad "armbian-firstlogin guard: $n h96_fb_pending hits, want 3"
  for d in getty@tty1.service.d ssh.service.d; do
    [ ! -e "/etc/systemd/system/$d/h96-firstboot.conf" ] && ok "no /etc/systemd/system/$d/h96-firstboot.conf" || bad "/etc/systemd/system/$d/h96-firstboot.conf present (r36 ordering cycle)"
  done
elif dpkg --compare-versions "$bv" ge 8.0.0~r36; then bad "h96-base $bv carries r36 getty/ssh drop-ins (ordering cycle), need r37"; fi
# userland r38: static ttyFIQ0 getty link gone (6.12 has no /dev/ttyFIQ0; 90 s device wait)
if dpkg --compare-versions "$bv" ge 8.0.0~r38; then [ ! -e /etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service ] && ok "no static serial-getty@ttyFIQ0 link (r38)" || bad "static serial-getty@ttyFIQ0 link present"; fi
# userland r39 (h96-audio): Bluetooth profile autoswitch off; (h96-base): COMMANDS names Steam ARM 3.1
if dpkg --compare-versions "$bv" ge 8.0.0~r39; then grep -q "bluetooth.autoswitch-to-headset-profile = false" /etc/wireplumber/wireplumber.conf.d/30-h96-bluetooth.conf && ok "30-h96-bluetooth.conf autoswitch off (r39)" || bad "30-h96-bluetooth.conf autoswitch (r39)"; [ "$(grep -c 'Steam ARM 3.1' /usr/share/doc/h96-base/COMMANDS.md)" = 2 ] && [ "$(grep -c 'Steam ARM 3.0' /usr/share/doc/h96-base/COMMANDS.md)" = 0 ] && ok "COMMANDS.md Steam ARM 3.1 (r39)" || bad "COMMANDS.md Steam ARM version (r39)"; fi
ls -laR /boot > "$L/boot-lsR.txt"; find /boot -xdev -type f -print0 | sort -z | xargs -0 sha256sum > "$L/boot-sha.txt"
ls -la /boot/Image* /boot/uInitrd* /boot/armbianEnv.txt /boot/boot.scr /boot/boot.cmd /boot/dtb/rockchip/*panthor*
cat /etc/h96-release
# r21 h96-base: release kernel keys follow default and fallback kernel
grep -qx "H96_KERNEL=$K" /etc/h96-release && ok "h96-release H96_KERNEL=$K" || bad "h96-release H96_KERNEL"
if [ "$FB" != none ]; then grep -qx "H96_KERNEL_FALLBACK=$FB" /etc/h96-release && ok "h96-release H96_KERNEL_FALLBACK=$FB" || bad "h96-release H96_KERNEL_FALLBACK"; fi
C=/usr/share/doc/h96-base/COMMANDS.md
cl=$(wc -l < "$C")
cmp -s "$C" /etc/skel/Desktop/COMMANDS.md && grep -q 'h96-kernel-switch' "$C" && ok "skel COMMANDS.md = packaged ($cl lines, kernel-switch section)" || bad "skel COMMANDS.md differs from packaged or lacks kernel-switch"
# line count per userland RESULTS (r35, r36, r37: 2212); other versions print only
case "$bv" in 8.0.0~r35|8.0.0~r36|8.0.0~r37|8.0.0~r38|8.0.0~r39) [ "$cl" = 2212 ] && ok "COMMANDS.md $cl lines (userland $bv)" || bad "COMMANDS.md $cl lines, want 2212 for userland $bv" ;; *) echo "INFO COMMANDS.md $cl lines (no pinned count for userland $bv)" ;; esac
rel=$(sed -n 's/^H96_RELEASE=//p' /etc/h96-release)
cmp -s /etc/h96-issue /etc/issue && cmp -s /etc/h96-issue.net /etc/issue.net && grep -q 'Unofficial Port v8\.0)' /etc/issue && ! grep -q beta /etc/issue && ok "issue and issue.net branded: $(head -1 /etc/issue)" || bad "issue branding"
grep -qxF "VARIANT=\"H96 Max V58 Unofficial Port $rel\"" /etc/os-release && case "$rel" in v8.0) true ;; *) false ;; esac && ok "os-release VARIANT $rel" || bad "os-release VARIANT"
# journald: persistent from boot 1, orphan adoption (r10 fix)
[ "$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | sed -n 's/^Storage=//p' | tail -1)" = persistent ] && ok "journald Storage=persistent effective" || bad "journald Storage"
grep -q 'journalctl --header' /usr/lib/h96/h96-journal-orphans && ok "h96-journal-orphans adopts old-id files" || bad "h96-journal-orphans old version"
grep -qs 'h96-journal-orphans' /etc/systemd/system/h96-firstboot-reboot.service.d/zz-h96-journal-orphans.conf && ok "journal-orphans drop-in" || bad "journal-orphans drop-in"
[ -d /var/log/journal ] && [ -z "$(find /var/log/journal -mindepth 1 -maxdepth 1 2>/dev/null)" ] && ok "/var/log/journal empty" || { find /var/log/journal -maxdepth 2 | head; bad "/var/log/journal not empty"; }
# offline repo: signature, every stanza file present with its sha, adds present
R=/opt/h96-pkgs
gpgv --keyring /usr/share/keyrings/h96-local-archive-keyring.gpg "$R/InRelease" > "$L/repo-gpgv.txt" 2>&1 && ok "offline repo InRelease gpgv" || bad "offline repo gpgv"
gpgv --keyring /usr/share/keyrings/h96-local-archive-keyring.gpg "$R/Release.gpg" "$R/Release" >> "$L/repo-gpgv.txt" 2>&1 && ok "offline repo Release.gpg gpgv" || bad "offline repo Release.gpg"
(cd "$R" && awk '/^SHA256:/{f=1;next} /^[^ ]/{f=0} f{print $1"  "$3}' Release | sha256sum -c --status) && ok "Release sums Packages and Packages.gz" || bad "Release sums"
(cd "$R" && awk '/^Filename:/{f=substr($2,3)} /^SHA256:/{print $2"  "f}' Packages | sha256sum -c --quiet) > "$L/repo-files.txt" 2>&1 && ok "offline repo $(grep -c '^Package:' $R/Packages) stanzas, files match" || bad "offline repo files: $(head -3 "$L/repo-files.txt")"
n=$(find "$R" -maxdepth 1 -name '*.deb' | wc -l); [ "$n" = "$(grep -c '^Package:' $R/Packages)" ] && ok "offline repo debs = stanzas ($n)" || bad "offline repo $n debs vs stanzas"
if [ -s /root/f5-in/repo/add.sha256 ]; then
  (cd "$R" && sha256sum -c --status /root/f5-in/repo/add.sha256) && ok "offline repo adds present ($(wc -l < /root/f5-in/repo/add.sha256))" || bad "offline repo adds"
else echo "INFO no offline repo adds"; fi
find / -xdev -name '*.h96-v72' 2>/dev/null | head -3
# r26 (userland r26): systemd-modules-load passes on both kernels; rpc_pipefs mount not masked (r27 reverts r26 mask); lxc-net not enabled
[ ! -e /etc/modules-load.d/h96-bcmdhd.conf ] && ok "no h96-bcmdhd modules-load entry (udev loads bcmdhd by PCI alias)" || bad "h96-bcmdhd.conf present"
for m in $(cat /etc/modules-load.d/*.conf /usr/lib/modules-load.d/*.conf 2>/dev/null | sed 's/#.*//' | tr -s ' \t' '\n' | grep .); do
  for k in "$K" $([ "$FB" != none ] && echo "$FB"); do
    grep -Eq "(^|/)${m//_/[_-]}\.ko(\.[a-z]+)?:" "/usr/lib/modules/$k/modules.dep" 2>/dev/null || grep -Eq "/${m//_/[_-]}\.ko$" "/usr/lib/modules/$k/modules.builtin" 2>/dev/null ||
      bad "modules-load entry $m not in $k modules.dep or modules.builtin"
  done
done; ok "modules-load entries checked against $K${FB:+ and $FB}"
[ ! -L /etc/systemd/system/run-rpc_pipefs.mount ] && ok "run-rpc_pipefs.mount not masked" || bad "run-rpc_pipefs.mount masked"
grep -q '^lxc-net.service' "$L/enabled-units.txt" && bad "lxc-net.service enabled" || ok "lxc-net.service not enabled"
# kernel-switch r14: modules unit file present, apt hook installed
[ -f /usr/lib/systemd/system/h96-kernel-switch-modules.service ] && [ -f /etc/apt/apt.conf.d/80h96-kernel-switch ] && ok "h96-kernel-switch r14 modules unit and apt hook present" || bad "h96-kernel-switch modules unit or apt hook missing"
rm -f /usr/sbin/policy-rc.d; [ ! -e /usr/sbin/policy-rc.d ] && ok "policy-rc.d removed" || bad "policy-rc.d"
df -B1 / /boot | awk 'NR>1{print "free", $6, $4}'
[ "$(df -B1 --output=avail / | tail -1)" -gt 67108864 ] && ok "rootfs free > 64 MiB" || bad "rootfs free space"
echo "fail=$fail"; exit $fail
