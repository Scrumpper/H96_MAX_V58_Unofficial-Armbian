#!/bin/bash
# Inside image chroot after repo, F5, kernel stage, branding (Debian edition): rc-r15 gate set adapted to two kernels
# and trixie, plus Debian gates (os-release, Mesa pin, no Ubuntu/PPA source, NetworkManager renderer, file caps);
# removes policy-rc.d.
set -uo pipefail
export F5_LOG=/root/f5-log; L=/root/f5-log/final; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
declare -a ID GT; row() { ID+=("$1"); GT+=("$4"); }
. /root/f5-in/f5-rows-debian.sh
# kernel switch r14+ saved trees (hard links of package module trees) hold rfcomm.ko by design: s8-rfcomm-stash gate re-run without them
KSS=/var/lib/h96-kernel-switch/modules
p=0; for i in "${!ID[@]}"; do
  if bash -c "${GT[$i]}" >/dev/null 2>&1; then p=$((p+1))
  elif [ "${ID[$i]}" = s8-rfcomm-stash ] && test ! -e /usr/local/lib/h96/rfcomm.ko && [ -z "$(find / -xdev -name rfcomm.ko -not -path '/usr/lib/modules/*' -not -path "$KSS/*" 2>/dev/null | head -1)" ]; then
    p=$((p+1)); echo "PASS gate s8-rfcomm-stash with kernel switch saved trees excluded ($KSS)"
  else bad "gate ${ID[$i]}"; fi
done
echo "F5 gates ${p}/${#ID[@]}"; [ "$p" = "${#ID[@]}" ] || fail=1
K=$(cat /root/f5-in/krel); KF=$(cat /root/f5-in/krel-fallback); echo "kernel default $K fallback $KF"
DV=8.0.0~r39+deb13.1; FB=$KF
dpkg --audit > "$L/audit.txt" 2>&1; [ ! -s "$L/audit.txt" ] && ok "dpkg --audit empty" || bad "dpkg --audit"
PK="h96-audio h96-base h96-boot h96-desktop h96-gaming h96-media h96-net h96-tools steam-arm-setup h96-kernel-$K h96-dtb-$K h96-kernel-$KF h96-dtb-$KF h96-kernel-switch"
# shellcheck disable=SC2086
dpkg -V $PK > "$L/dpkg-V-h96.txt" 2>&1
[ ! -s "$L/dpkg-V-h96.txt" ] && ok "dpkg -V 14 packages empty" || bad "dpkg -V h96: $(head -3 "$L/dpkg-V-h96.txt")"
dpkg -V > "$L/dpkg-V-all.txt" 2>&1; echo "dpkg -V all lines=$(wc -l < "$L/dpkg-V-all.txt")"
apt-get -s check > "$L/apt-check.txt" 2>&1 && ok "apt-get -s check" || bad "apt-get -s check"
dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' 'h96-*' steam-arm-setup > "$L/installed.txt"; cat "$L/installed.txt"
[ "$(grep -c '^ii ' "$L/installed.txt")" = 14 ] && [ "$(wc -l < "$L/installed.txt")" = 14 ] && ok "14 packages ii" || bad "package count"
for q in $PK; do grep -Eq "^ii +$q " "$L/installed.txt" || bad "$q not ii"; done
for q in h96-audio h96-base h96-boot h96-desktop h96-gaming h96-media h96-net h96-tools; do
  [ "$(dpkg-query -W -f '${Version}' "$q")" = "$DV" ] || bad "$q version $(dpkg-query -W -f '${Version}' "$q")"
done; ok "userland $DV"
# steam-arm-setup: installed version and packaged install.sh must equal the staged deb (Steam ARM 3.1 final)
SAD=$(find /root/f5-in -maxdepth 1 -name 'steam-arm-setup_*_arm64.deb' | head -1); SAX=$(mktemp -d)
SAV=$(dpkg-query -W -f '${Version}' steam-arm-setup)
[ -n "$SAD" ] && [ "$SAV" = "$(dpkg-deb -f "$SAD" Version)" ] && case "$SAV" in 3.1|3.1[.~+-]*) true ;; *) false ;; esac && ok "steam-arm-setup $SAV = staged deb" || bad "steam-arm-setup version $SAV vs ${SAD:-no staged deb}"
if [ -n "$SAD" ] && dpkg-deb -x "$SAD" "$SAX" && [ -f "$SAX/usr/share/steam-arm-setup/install.sh" ]; then
  a=$(sha256sum < /usr/share/steam-arm-setup/install.sh | cut -d' ' -f1); b=$(sha256sum < "$SAX/usr/share/steam-arm-setup/install.sh" | cut -d' ' -f1)
  [ "$a" = "$b" ] && ok "Steam ARM install.sh = deb install.sh (${a:0:8})" || bad "install.sh sha ${a:0:8} != deb ${b:0:8}"
else bad "install.sh: staged deb not extractable"; fi; rm -rf "$SAX"
grep -Eqx 'SA_VERSION="?3\.1([.~+-][^"]*)?"?' /usr/share/steam-arm-setup/install.sh && ok "SA_VERSION 3.1" || bad "SA_VERSION"
systemctl list-unit-files --state=enabled --no-legend --no-pager > "$L/enabled-units.txt" 2>&1; echo "enabled units: $(wc -l < "$L/enabled-units.txt")"
grep -i 'panthor-setup' "$L/enabled-units.txt" && bad "h96-panthor-setup enabled" || ok "no h96-panthor-setup enabled"
# kernel switch block as rc-r22 (r14 saved trees and modules unit, r15 init-bottom, r16 one dumper and OFFS, uInitrd size)
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
      # list captured first: grep -q under pipefail can SIGPIPE lsinitramfs and read as no match (rc-r22 line)
      tail -c +65 "/boot/uInitrd-$r" > /tmp/fc-initrd && lsinitramfs /tmp/fc-initrd > /tmp/fc-initrd.lst 2>/dev/null && grep -qx "${b#*/initramfs-tools/}" /tmp/fc-initrd.lst && ok "uInitrd-$r holds ${b#*/initramfs-tools/}" || bad "uInitrd-$r lacks ${b#*/initramfs-tools/}"
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
[ -f /usr/lib/systemd/system/h96-wol.service ] && ok "h96-wol.service installed" || bad "h96-wol.service missing"
st=$(systemctl is-enabled h96-wol.service 2>&1); [ "$st" = disabled ] && ok "h96-wol.service disabled" || bad "h96-wol.service $st"
[ -z "$(find /etc/systemd/system -name h96-wol.service 2>/dev/null)" ] && ok "no h96-wol.service link" || bad "h96-wol.service link"
find / -xdev -name rfcomm.ko -not -path '/usr/lib/modules/*' -not -path "$KSS/*" 2>/dev/null > "$L/rfcomm-left.txt"
[ ! -s "$L/rfcomm-left.txt" ] && [ ! -e /usr/local/lib/h96 ] && ok "no rfcomm.ko stash, no /usr/local/lib/h96" || bad "rfcomm stash or /usr/local/lib/h96"
[ -f /etc/machine-id ] && [ ! -s /etc/machine-id ] && ok "machine-id empty (no first-boot presets)" || bad "machine-id: $(head -c 40 /etc/machine-id 2>&1)"
systemctl is-enabled -q h96-branding.service && systemctl is-enabled -q h96-branding.path && ok "h96-branding units enabled" || bad "h96-branding units"
systemctl is-enabled -q h96-gaming-setup.service && systemctl is-enabled -q h96-gpu-setup.service && ok "first-boot GPU and gaming units enabled" || bad "first-boot units"
find / -xdev \( -name 'h96-panthor-setup*' -o -name 'h96-panthor-firstboot*' -o -name 'panthor-deploy.sh' \) 2>/dev/null > "$L/panthor-left.txt"
[ ! -s "$L/panthor-left.txt" ] && ok "no h96-panthor-setup files" || bad "panthor-setup files left"
find / -xdev \( -iname '*libmali*' -o -name 'mali.json' -o -name '00-aarch64-mali.conf' -o -name 'gbm_shim.so' \) 2>/dev/null > "$L/mali-left.txt"
[ ! -s "$L/mali-left.txt" ] && ok "no libmali files (repo included)" || { cat "$L/mali-left.txt"; bad "libmali files left"; }
dpkg-query -W 'libmali*' > /dev/null 2>&1 && bad "libmali package installed" || ok "no libmali package"
# grep -c reads all input: grep -q under pipefail can SIGPIPE the writer and read as no match
[ "$(ldconfig -p | grep -ci libmali)" != 0 ] && bad "ldconfig libmali" || ok "ldconfig clean"
grep -qi mali /etc/environment && bad "/etc/environment mali" || ok "/etc/environment no mali"
[ ! -e /boot/extlinux ] && ok "no /boot/extlinux" || bad "/boot/extlinux"
[ "$(readlink /boot/Image)" = "Image-$K" ] && [ "$(readlink /boot/uInitrd)" = "uInitrd-$K" ] && ok "boot links on $K" || bad "boot links"
for r in "$K" "$KF"; do [ -f "/boot/Image-$r" ] && [ -f "/boot/uInitrd-$r" ] && ok "/boot holds $r Image and uInitrd" || bad "/boot $r files"; done
cmp -s "/usr/lib/h96-kernel/$KF/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb" /boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb.6.1 && ok ".dtb.6.1 = fallback DTB" || bad ".dtb.6.1"
[ ! -e /boot/Image-6.1.172-h96v58-7.1 ] && [ ! -e /boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb.v7.2 ] && [ ! -e /usr/lib/modules/6.1.172-h96v58-7.1 ] && ok "no v7.2 kernel (D4)" || bad "v7.2 kernel left"
for r in "$K" "$KF"; do
  s=$(stat -c %s "/boot/uInitrd-$r"); echo "uInitrd-$r $s B"
  [ "$s" -lt 67108864 ] && ok "uInitrd-$r below 64 MiB (load 0x0a200000, end 0x$(printf '%x' $((0x0a200000 + s))))" || bad "uInitrd-$r size $s"
done
[ -f /etc/apt/preferences.d/00-h96-protect-boot ] && ok "apt pin present" || bad "apt pin"
fdtget -t s /boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb /watchdog@feaf0000 status 2>/dev/null | grep -qx okay && ok "DTB watchdog okay" || bad "DTB watchdog node"
ls -laR /boot > "$L/boot-lsR.txt"; find /boot -xdev -type f -print0 | sort -z | xargs -0 sha256sum > "$L/boot-sha.txt"
cat /etc/h96-release
rel=$(sed -n 's/^H96_RELEASE=//p' /etc/h96-release)
grep -qx H96_EDITION=debian /etc/h96-release && ok "H96_EDITION=debian" || bad "H96_EDITION"
cmp -s /etc/h96-issue /etc/issue && cmp -s /etc/h96-issue.net /etc/issue.net && grep -q 'Unofficial Port v8\.0 Debian Edition)' /etc/issue && ! grep -q beta /etc/issue && ok "issue branded: $(head -1 /etc/issue)" || bad "issue branding"
grep -qxF "VARIANT=\"H96 Max V58 Unofficial Port $rel Debian Edition\"" /etc/os-release && [ "$rel" = v8.0 ] && ok "os-release VARIANT $rel Debian Edition" || bad "os-release VARIANT"
[ "$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | sed -n 's/^Storage=//p' | tail -1)" = persistent ] && ok "journald Storage=persistent effective" || bad "journald Storage"
grep -q 'journalctl --header' /usr/lib/h96/h96-journal-orphans && ok "h96-journal-orphans adopts old-id files" || bad "h96-journal-orphans"
grep -qs 'h96-journal-orphans' /etc/systemd/system/h96-firstboot-reboot.service.d/zz-h96-journal-orphans.conf && ok "journal-orphans drop-in" || bad "journal-orphans drop-in"
[ -d /var/log/journal ] && [ -z "$(find /var/log/journal -mindepth 1 -maxdepth 1 2>/dev/null)" ] && ok "/var/log/journal empty" || bad "/var/log/journal not empty"
R=/opt/h96-pkgs; KR=/usr/share/keyrings/h96-local-archive-keyring.gpg
gpgv --keyring "$KR" "$R/InRelease" > "$L/repo-gpgv.txt" 2>&1 && ok "offline repo InRelease gpgv (packaged keyring)" || bad "offline repo gpgv"
(cd "$R" && awk '/^Filename:/{f=substr($2,3)} /^SHA256:/{print $2"  "f}' Packages | sha256sum -c --quiet) > "$L/repo-files.txt" 2>&1 && ok "offline repo $(grep -c '^Package:' $R/Packages) stanzas, files match" || bad "offline repo files"
# Debian gates
grep -qx 'ID=debian' /etc/os-release && grep -qx 'VERSION_CODENAME=trixie' /etc/os-release && ok "os-release ID=debian VERSION_CODENAME=trixie" || bad "os-release distro"
grep -A2 '26.1.6-1~bpo13+1' /etc/apt/preferences.d/01-h96-protect-mesa | grep -qx 'Pin-Priority: 1001' && ok "Mesa pin 26.1.6-1~bpo13+1 at 1001" || bad "Mesa pin Debian stanza"
grep -rlsiE 'kisak|xtradeb|ubuntu\.com|launchpad|ppa\.' /etc/apt/sources.list.d /etc/apt/sources.list > "$L/ubuntu-sources.txt"
[ ! -s "$L/ubuntu-sources.txt" ] && ok "no kisak, xtradeb, PPA or Ubuntu source" || bad "Ubuntu-side source: $(cat "$L/ubuntu-sources.txt")"
dpkg-query -W plasma-session-x11 > /dev/null 2>&1 && bad "plasma-session-x11 installed" || ok "no plasma-session-x11"
grep -qs 'renderer: NetworkManager' /etc/netplan/00-default-use-network-manager.yaml && [ ! -e /etc/netplan/10-dhcp-all-interfaces.yaml ] && dpkg-query -W -f '${db:Status-Abbrev}' network-manager | grep -q '^ii' && ok "NetworkManager renderer, network-manager ii" || bad "network renderer"
python3 - <<'PY' > "$L/caps.txt"
import os
for root, ds, fs in os.walk("/", topdown=True):
    ds[:] = [d for d in ds if os.path.join(root, d) not in ("/proc", "/sys", "/dev", "/run", "/root/f5-in", "/root/f5-log")]
    for f in fs:
        p = os.path.join(root, f)
        try:
            v = os.getxattr(p, "security.capability", follow_symlinks=False)
            print(p, v.hex())
        except OSError:
            pass
PY
cat "$L/caps.txt"
grep -q '^/usr/bin/fping 0100000200200000' "$L/caps.txt" && ok "file caps kept (fping cap_net_raw, v2)" || bad "file caps: $(head -3 "$L/caps.txt")"
for b in nmcli dhcpcd wpa_supplicant iw rfkill ethtool python3 mkimage mkinitramfs fdtget fuser zstd gpg curl; do command -v "$b" > /dev/null || bad "command $b missing"; done; ok "runtime commands present"
# r2 gates (audit findings): base current, console python deps, no root autologin, networkd off, apt lists, leftovers
grep -qx '13\.[0-9]*' /etc/debian_version && ok "debian_version $(cat /etc/debian_version)" || bad "debian_version"
up=$(apt-get -s -o Debug::NoLocking=1 full-upgrade 2>/dev/null | grep -c '^Inst '); [ "$up" != 0 ] && bad "Debian upgrades pending in image" || ok "no pending Debian upgrade (lists of prep)"
python3 -c 'import dbus; from gi.repository import GLib' && ok "python3 dbus + gi import" || bad "python3 dbus/gi"
grep -rqs autologin /etc/systemd/system/getty@.service.d /etc/systemd/system/serial-getty@.service.d && bad "getty autologin" || ok "no getty autologin"
[ "$(systemctl is-enabled systemd-networkd.service 2>/dev/null)" != enabled ] && ok "systemd-networkd not enabled" || bad "systemd-networkd enabled"
[ "$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' | wc -l)" -ge 4 ] && ok "apt lists present" || bad "apt lists missing"
ls -d /vmlinuz* /initrd.img* > /dev/null 2>&1 && bad "root kernel links" || ok "no root kernel links"
dpkg-query -W -f '${db:Status-Abbrev}' armbian-bsp-cli-rock-5b-vendor 2>/dev/null | grep -q . && bad "rock-5b BSP entry" || ok "no rock-5b BSP entry"
[ -f /etc/chromium.d/armbian-flags ] && ok "Chromium flags file" || bad "Chromium flags file"
for m in mesa-opencl-icd mesa-teflon-delegate mesa-drm-shim libgbm-dev; do c=$(LC_ALL=C apt-cache policy "$m" | sed -n 's/^  Candidate: //p'); [ "$c" = 26.1.6-1~bpo13+1 ] || bad "Mesa candidate $m: $c"; done; ok "Mesa pin covers OpenCL, Teflon, drm-shim, dev"
# r3 gates: userland r17..r21 replay (hotplug, mpv audio outputs, CEC default, release keys, COMMANDS), low items
grep -qx "H96_KERNEL=$K" /etc/h96-release && ok "h96-release H96_KERNEL=$K" || bad "h96-release H96_KERNEL"
grep -qx "H96_KERNEL_FALLBACK=$KF" /etc/h96-release && ok "h96-release H96_KERNEL_FALLBACK=$KF" || bad "h96-release H96_KERNEL_FALLBACK"
C=/usr/share/doc/h96-base/COMMANDS.md
cmp -s "$C" /etc/skel/Desktop/COMMANDS.md && [ "$(wc -l < "$C")" = 2212 ] && ok "skel COMMANDS.md = packaged (2212 lines, = Ubuntu r36)" || bad "skel COMMANDS.md: $(wc -l < "$C") lines, cmp $(cmp -s "$C" /etc/skel/Desktop/COMMANDS.md && echo same || echo differs)"
[ "$(grep -c 'Ubuntu 26.04' "$C")" = 0 ] && [ "$(grep -c 'Steam ARM 3.1' "$C")" = 2 ] && [ "$(grep -c 'Steam ARM 3.0' "$C")" = 0 ] && ok "COMMANDS.md Debian wording (deb13.2: no Ubuntu 26.04, Steam ARM 3.1 x2)" || bad "COMMANDS.md Debian wording"
[ "$(grep -c 'Debian Edition' "$C")" = 3 ] && [ "$(grep -c 'armbian-sync. copies\|scripts .armbian-sync. updates' "$C")" = 0 ] && ok "COMMANDS.md Debian text (ophub guard, h96-vulkan-wsi not provided)" || bad "COMMANDS.md ophub text"
grep -q "bluetooth.autoswitch-to-headset-profile = false" /etc/wireplumber/wireplumber.conf.d/30-h96-bluetooth.conf && ok "30-h96-bluetooth.conf: autoswitch off (r39)" || bad "30-h96-bluetooth.conf autoswitch"
[ "$(readlink /etc/systemd/system/dev-cec0.device.wants/h96-cec.service 2>/dev/null)" = /usr/lib/systemd/system/h96-cec.service ] && [ ! -e /etc/systemd/system/multi-user.target.wants/h96-cec.service ] && [ -f /var/lib/h96/cec-default-on ] && ok "h96-cec on by default (dev-cec0.device link, marker)" || bad "h96-cec default link or marker"
[ -x /usr/sbin/h96-hdmi-hotplug ] && [ -f /usr/lib/systemd/system/h96-hdmi-hotplug.service ] && grep -q h96-hdmi-hotplug /usr/lib/udev/rules.d/99-h96-hdmi-audio.rules && ok "h96-hdmi-hotplug handler, unit, udev rule" || bad "h96-hdmi-hotplug"
[ -x /usr/sbin/h96-vrr ] && [ ! -e /etc/h96/display-vrr.on ] && ok "h96-vrr present, off" || bad "h96-vrr"
S=/usr/lib/h96/video/h96-video-stack.tar.gz
[ "$(tar -xzOf "$S" usr/bin/mpv | grep -ac 'libpipewire-0\.3\.so\.0')" != 0 ] && [ "$(tar -xzOf "$S" usr/bin/mpv | grep -ac 'libpulse\.so\.0')" != 0 ] && ok "bundled mpv links libpipewire and libpulse" || bad "bundled mpv audio outputs"
for q in libpipewire-0.3-0t64 libpulse0 libspa-0.2-modules; do grep -qx "Package: $q" /opt/h96-pkgs/Packages || bad "offline repo lacks $q"; done; ok "offline repo carries libpipewire-0.3-0t64, libpulse0, libspa-0.2-modules"
grep -q 'libpipewire-0.3-0t64 libpulse0' /usr/lib/h96/h96-video-setup.sh && ok "video setup Debian list names libpipewire, libpulse" || bad "video setup list"
E=/boot/armbianEnv.txt
grep -qx 'fdtfile=rockchip/rk3588-h96-max-v58-panthor.dtb' "$E" && grep -q '^extraargs=.* drm\.edid_firmware=HDMI-A-1:edid/h96-sink-audio\.bin' "$E" && [ -f /usr/lib/firmware/edid/h96-sink-audio.bin ] && grep -q '^extraargs=.* video=HDMI-A-1:1920x1080@60' "$E" && ok "armbianEnv fdtfile, forced EDID token and blob, video= token" || bad "armbianEnv tokens"
for u in armbian-firstrun.service h96-firstboot.service h96-video-setup.service; do systemctl is-enabled -q "$u" || bad "first-boot $u not enabled"; done; ok "first-boot armbian-firstrun, h96-firstboot, h96-video-setup enabled"
[ "$(readlink /etc/systemd/system-generators/systemd-gpt-auto-generator)" = /dev/null ] && ok "gpt-auto-generator masked (as v7.2)" || bad "gpt-auto-generator mask"
[ "$(ls /usr/lib/sysctl.d/55-*.conf 2>/dev/null | wc -l)" = 9 ] && grep -qx 'kernel.yama.ptrace_scope = 1' /usr/lib/sysctl.d/55-ptrace.conf && ok "Ubuntu 55-* sysctl defaults present (9 files)" || bad "55-* sysctl defaults"
# r4 gates: userland r22..r31 replay (MPRIS plugin trixie build, keymap, labels), h96-vulkan-wsi edition difference; r5: loader instead of link
echo "4ef1c47a295cdd665f61f056a408de7a7ea8eaa3b31e90d3297338e408addf0d  /usr/lib/h96/mpv-mpris/mpris.so" | sha256sum -c --status 2>/dev/null && ok "mpv-mpris mpris.so 4ef1c47a (trixie build)" || bad "mpv-mpris mpris.so missing or sha"
[ ! -e /etc/mpv/scripts/h96-mpris.so ] && echo "65f9291aab4969cd2b7a7e654491f016ad852be005259a8923556ef90e8903b9  /etc/mpv/scripts/h96-mpris.lua" | sha256sum -c --status 2>/dev/null && ok "MPRIS loader h96-mpris.lua (r33/r34), no h96-mpris.so link" || bad "MPRIS loader: link present or h96-mpris.lua missing/sha"
# r5/r6 gates: userland r32..r37 replay (h96-perf busctl path, first-login waits for first-boot reboot)
grep -q "busctl get-property" /usr/bin/h96-perf && grep -q "ppd_set" /usr/bin/h96-perf && ok "h96-perf busctl fallback (r36)" || bad "h96-perf busctl fallback"
[ ! -e /etc/systemd/system/getty@tty1.service.d ] && [ ! -e /etc/systemd/system/ssh.service.d ] && ok "no getty/ssh first-boot drop-ins (r36 ordering cycle, removed r37)" || bad "getty/ssh drop-in present"
[ "$(grep -c h96_fb_pending /usr/lib/armbian/armbian-firstlogin)" = 3 ] && ok "firstlogin waits for first-boot reboot (r37)" || bad "firstlogin first-boot guard"
[ ! -e /etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service ] && ok "no static ttyFIQ0 getty link (r38, 90 s boot wait on 6.12)" || bad "static ttyFIQ0 getty link present"
grep -Eq '^back[[:space:]]*=[[:space:]]*KEY_ESC([[:space:]]|$)' /etc/h96/cec-keymap.conf && grep -Eq '^return[[:space:]]*=[[:space:]]*KEY_ESC([[:space:]]|$)' /etc/h96/cec-keymap.conf && ok "cec-keymap back and return = KEY_ESC" || bad "cec-keymap back/return"
! dpkg-query -W h96-vulkan-wsi > /dev/null 2>&1 && ! ls /opt/h96-pkgs/h96-vulkan-wsi_*.deb > /dev/null 2>&1 && [ ! -e /etc/h96/vulkan-wsi.on ] && ok "h96-vulkan-wsi absent (edition difference: Mesa pin 26.1.4~kisak1~r)" || bad "h96-vulkan-wsi present"
[ ! -e /etc/modules-load.d/h96-bcmdhd.conf ] && [ "$(readlink /etc/systemd/system/run-rpc_pipefs.mount 2>/dev/null)" != /dev/null ] && [ -f /var/lib/h96/rpc-pipefs-unmask-r27 ] && ok "no bcmdhd modules-load entry, rpc_pipefs not masked, r27 marker" || bad "bcmdhd entry or rpc_pipefs mask"
for e in $(cat /etc/modules-load.d/*.conf 2>/dev/null | sed 's/#.*//' | xargs); do
  for r in $K $KF; do grep -q "/${e//-/[_-]}\.ko" "/usr/lib/modules/$r/modules.dep" || grep -q "/${e//-/[_-]}\.ko" "/usr/lib/modules/$r/modules.builtin" || bad "modules-load entry $e not in $r"; done
done; ok "modules-load.d entries present in both kernels"
# userland r29 / switch r17: no internal labels in h96 docs, man pages, /etc/h96 (Debian changelog.gz keeps package versions; ravu-lite-ar-r4 is a name)
{ dpkg-query -W -f '${Package}\n' 'h96-*' | xargs dpkg-query -L 2>/dev/null | grep -E '^/usr/share/(doc|man)/' ; find /etc/h96 -type f 2>/dev/null; } | sort -u |
  while read -r f; do [ -f "$f" ] && [ ! -L "$f" ] && case "$f" in */changelog*.gz) ;; *) echo "$f" ;; esac; done > "$L/label-scan-files.txt"
: > "$L/label-hits.txt"
while read -r f; do zgrep -HnE '8\.0\.0|\br[0-9]+\b' "$f" 2>/dev/null | grep -vE 'ravu(\\)?-lite(\\)?-ar(\\)?-r4' >> "$L/label-hits.txt"; done < "$L/label-scan-files.txt"
[ ! -s "$L/label-hits.txt" ] && ok "no 8.0.0 or rN label in $(wc -l < "$L/label-scan-files.txt") h96 doc, man and /etc/h96 files" || { head -5 "$L/label-hits.txt"; bad "internal labels in docs ($(wc -l < "$L/label-hits.txt") lines, $L/label-hits.txt)"; }
rm -f /usr/sbin/policy-rc.d; [ ! -e /usr/sbin/policy-rc.d ] && ok "policy-rc.d removed" || bad "policy-rc.d"
df -B1 / | awk 'NR>1{print "free / " $4}'
echo "fail=$fail"; exit $fail
