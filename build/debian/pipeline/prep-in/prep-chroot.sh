#!/bin/bash
# Stage 3 prep, inside trixie rootfs chroot (network): vendor kernel, DTB and U-Boot packages out, BSP odroidn2-current
# 26.8.3 in place of rock-5b-vendor (same lineage as Ubuntu 8.0), H96 armbian-release, NetworkManager renderer, base
# packages the Ubuntu 8.0 base carries, v7.2 payload rows, backports pin. /boot of this tree is discarded later.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
I=/root/f5-in; L=/root/f5-log/prep; mkdir -p "$L"; fail=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
dpkg-query -W -f '${Package} ${Version}\n' | sort > "$L/pkgs-pre.txt"
# lists from base image (2026-08-21) plus pdiffs gave a stale index (404 on superseded debs): fresh full lists
rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
apt-get -o Acquire::PDiffs=false update > "$L/apt-update.txt" 2>&1 && ok "apt-get update" || bad "apt-get update: $(tail -2 "$L/apt-update.txt")"
apt-get purge -y linux-image-vendor-rk35xx linux-dtb-vendor-rk35xx linux-u-boot-rock-5b-vendor > "$L/purge-kernel.txt" 2>&1 && ok "vendor kernel, DTB, U-Boot purged" || bad "purge kernel"
[ -z "$(ls /usr/lib/modules 2>/dev/null)" ] && ok "no module tree left" || echo "INFO modules left: $(ls /usr/lib/modules)"
# BSP swap: remove keeps conffiles; odroidn2 26.8.3 installs over them (sha checked on laptop against signed Armbian index)
dpkg -r armbian-bsp-cli-rock-5b-vendor > "$L/bsp-remove.txt" 2>&1 && ok "rock-5b-vendor BSP removed" || bad "BSP remove"
dpkg -i --force-confnew "$I/bsp.deb" > "$L/bsp-install.txt" 2>&1 && ok "odroidn2-current 26.8.3 BSP installed" || bad "BSP install: $(tail -3 "$L/bsp-install.txt")"
install -m 0644 "$I/armbian-release" /etc/armbian-release && ok "H96 armbian-release (INITRD_ARCH=arm64, bootscript update off)"
BASEPKGS="network-manager network-manager-config-connectivity-debian dhcpcd-base irqbalance rfkill python3-tk i2c-tools
pciutils gnupg file unzip bzip2 iptables evtest zstd psmisc python3-dbus python3-gi qrencode stress"
# mirror may lag behind its own index for a few minutes: retry with fresh lists
for t in 1 2 3 4; do
  # shellcheck disable=SC2086
  apt-get install -y $BASEPKGS > "$L/install-base.txt" 2>&1 && break
  echo "INFO base packages attempt $t failed: $(grep -m1 '^E:' "$L/install-base.txt")"; sleep 60; apt-get -o Acquire::PDiffs=false update > "$L/apt-update-$t.txt" 2>&1
done
# shellcheck disable=SC2086
dpkg-query -W $BASEPKGS > /dev/null 2>&1 && ok "base packages" || bad "base packages: $(tail -3 "$L/install-base.txt")"
# point release + security updates (base image 13.6); verified BSP held at 26.8.3
apt-mark hold armbian-bsp-cli-odroidn2-current > /dev/null
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade > "$L/full-upgrade.txt" 2>&1 && ok "full-upgrade ($(grep -cE '^(Setting up|Unpacking) ' "$L/full-upgrade.txt") dpkg lines)" || bad "full-upgrade: $(tail -3 "$L/full-upgrade.txt")"
apt-mark unhold armbian-bsp-cli-odroidn2-current > /dev/null
[ -z "$(apt-get -s full-upgrade 2>/dev/null | grep '^Inst ')" ] && ok "no pending upgrade" || bad "upgrades pending after full-upgrade"
python3 -c 'import dbus; from gi.repository import GLib' && ok "python3 dbus + gi import (h96-power-profiles, h96-bt-*)" || bad "python3 dbus/gi"
# left by base: rock-5b BSP conffiles (rc), root links to purged vendor kernel, root autologin on getty, networkd
dpkg --purge armbian-bsp-cli-rock-5b-vendor > "$L/bsp-purge.txt" 2>&1
dpkg-query -W -f '${db:Status-Abbrev}' armbian-bsp-cli-rock-5b-vendor 2>/dev/null | grep -q . && bad "rock-5b BSP entry left" || ok "rock-5b BSP purged"
for f in /vmlinuz /vmlinuz.old /initrd.img /initrd.img.old; do [ -L "$f" ] && [ ! -e "$f" ] && rm -f "$f"; done
ls -d /vmlinuz* /initrd.img* > /dev/null 2>&1 && bad "root kernel links left" || ok "no dangling root kernel links"
rm -f /etc/systemd/system/getty@.service.d/override.conf /etc/systemd/system/serial-getty@.service.d/override.conf
rmdir /etc/systemd/system/getty@.service.d /etc/systemd/system/serial-getty@.service.d 2>/dev/null
grep -rqs autologin /etc/systemd/system/getty@.service.d /etc/systemd/system/serial-getty@.service.d && bad "getty autologin left" || ok "no getty autologin (login root/1234 or SSH, as Ubuntu 8.0)"
systemctl disable systemd-networkd.service systemd-networkd.socket systemd-network-generator.service > "$L/networkd.txt" 2>&1
[ "$(systemctl is-enabled systemd-networkd.service 2>/dev/null)" != enabled ] && ok "systemd-networkd off (NetworkManager renderer, as Ubuntu 8.0)" || bad "systemd-networkd enabled"
# payload rows from v7.2 (pipeline/prep-payload.tsv)
(cd "$I/payload" && find . ! -type d | sort) > "$L/payload.lst"
while read -r p; do p=${p#.}; mkdir -p "$(dirname "$p")"; cp -a "$I/payload$p" "$p" && chown -h root:root "$p"; done < "$L/payload.lst"
ok "payload rows copied: $(wc -l < "$L/payload.lst")"
rm -f /etc/netplan/10-dhcp-all-interfaces.yaml
[ -f /etc/netplan/00-default-use-network-manager.yaml ] && [ ! -e /etc/netplan/10-dhcp-all-interfaces.yaml ] && ok "netplan NetworkManager renderer" || bad "netplan"
chmod 600 /etc/netplan/*.yaml
install -m 0644 "$I/02-h96-debian-backports" /etc/apt/preferences.d/02-h96-debian-backports && ok "backports pin src:pipewire 600"
apt-config dump APT::Install-Recommends | grep -qx 'APT::Install-Recommends "0";' && ok "Install-Recommends 0" || bad "Install-Recommends"
grep -qx INITRD_ARCH=arm64 /etc/armbian-release && ok "INITRD_ARCH=arm64" || bad "INITRD_ARCH"
for f in /etc/dhcpcd.conf /etc/default/irqbalance; do [ -f "$f" ] && ok "$f present" || bad "$f missing"; done
apt-get -s check > "$L/apt-check.txt" 2>&1 && ok "apt-get -s check" || bad "apt-get -s check"
dpkg --audit > "$L/audit.txt" 2>&1; [ ! -s "$L/audit.txt" ] && ok "dpkg --audit empty" || bad "dpkg --audit"
# apt lists kept (as Ubuntu 8.0): h96 tools install from Debian mirrors without a prior apt-get update
apt-get clean
[ "$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' | wc -l)" -ge 4 ] && ok "apt lists kept: $(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' | wc -l) Packages files" || bad "apt lists"
rm -f /usr/sbin/policy-rc.d
dpkg-query -W -f '${Package} ${Version}\n' | sort > "$L/pkgs-post.txt"
diff "$L/pkgs-pre.txt" "$L/pkgs-post.txt" > "$L/pkgs-diff.txt"; echo "package delta lines: $(grep -c '^[<>]' "$L/pkgs-diff.txt")"
echo "fail=$fail"; exit $fail
