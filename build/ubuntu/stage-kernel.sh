#!/bin/bash
# Inside image chroot: install default and fallback kernel + DTB debs, build uInitrd per release, stage into image /boot.
# r11: deb names from inputs; h96-kernel-switch installed, units left disabled (new feature off).
# r15: kernel release from stage file krel (laptop.sh H96_RC_KREL).
# r16: default krel (6.12) on /boot links + board DTB; fallback fbkrel (6.1) plain files + .dtb.6.1; v7.2 kernel removed.
# r18: kernel switch installed before mkinitramfs (r15 init-bottom script in uInitrd); r14+ saved trees + modules unit.
set -uo pipefail
D=/root/f5-in; K=$(cat "$D/krel" 2>/dev/null || echo 6.12.69-h96v58-8.0); FB=$(cat "$D/fbkrel" 2>/dev/null || echo none)
OLDK=6.1.172-h96v58-7.1; L=/root/f5-log/kernel; mkdir -p "$L"
echo "kernel release $K, fallback $FB"
DTBN=rockchip/rk3588-h96-max-v58-panthor.dtb
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1792281600}  # default 2026-10-18 00:00 UTC
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
snap() { find /boot -xdev -printf '%M %U:%G %s %p -> %l\n' | sort -k5 > "$L/boot-$1.lst"; find /boot -xdev -type f -print0 | sort -z | xargs -0 sha256sum > "$L/boot-$1.sha"; }
snap pre
RELS="$K"; [ "$FB" != none ] && RELS="$FB $K"
debof() { local m; m=$(compgen -G "$D/${1}_*.deb"); [ "$(printf '%s\n' "$m" | grep -c .)" = 1 ] && echo "$m"; }
for r in $RELS; do for p in h96-kernel-$r h96-dtb-$r; do
  f=$(debof "$p") || { bad "input deb $p not exactly one"; continue; }
  dpkg -i "$f" < /dev/null > "$L/install-$p.txt" 2>&1 && ok "dpkg -i $p" || bad "dpkg -i $p"
done; done
snap debs
cmp -s "$L/boot-pre.sha" "$L/boot-debs.sha" && cmp -s "$L/boot-pre.lst" "$L/boot-debs.lst" && ok "kernel debs left /boot unchanged" || bad "kernel debs changed /boot"
# kernel switch before initramfs: r15+ init-bottom script and hooks land in uInitrd; package only, no try
snap staged
f=$(debof h96-kernel-switch) && dpkg -i "$f" < /dev/null > "$L/install-h96-kernel-switch.txt" 2>&1 && ok "dpkg -i h96-kernel-switch" || bad "dpkg -i h96-kernel-switch"
for u in h96-kernel-switch-guard.service h96-kernel-switch-confirm.timer h96-kernel-switch-confirm.service; do
  st=$(systemctl is-enabled "$u" 2>&1); echo "$u: $st"
  case "$st" in disabled|static) ok "$u not enabled" ;; *) bad "$u $st" ;; esac
done
# r14+: postinst saves module tree of each staged build and enables h96-kernel-switch-modules.service (first save)
if dpkg --compare-versions "$(dpkg-query -W -f '${Version}' h96-kernel-switch)" ge 8.0.0~r14; then
  [ -L /etc/systemd/system/sysinit.target.wants/h96-kernel-switch-modules.service ] && ok "h96-kernel-switch-modules.service enabled (sysinit.target)" || bad "h96-kernel-switch-modules.service not enabled"
  [ -z "$(find /etc/systemd/system \( -name 'h96-kernel-switch-guard*' -o -name 'h96-kernel-switch-confirm*' \) 2>/dev/null)" ] && ok "no guard or confirm links" || bad "guard or confirm links present"
  for r in $RELS; do
    d=/var/lib/h96-kernel-switch/modules/$r/$(sha256sum < "/usr/lib/h96-kernel/$r/Image" | cut -c1-16)
    [ -f "$d/meta" ] && [ -d "$d/tree" ] && ok "saved module tree $r ${d##*/}" || bad "saved module tree $r missing ($d)"
  done
  [ ! -e /var/lib/h96-kernel-switch/trial ] && ok "no trial record" || bad "trial record present"
else
  [ -z "$(find /etc/systemd/system -name 'h96-kernel-switch*' 2>/dev/null)" ] && ok "no h96-kernel-switch unit links" || bad "h96-kernel-switch unit links"
  [ ! -e /var/lib/h96-kernel-switch ] && ok "no kernel switch state" || bad "kernel switch state present"
fi
snap switch
cmp -s "$L/boot-staged.sha" "$L/boot-switch.sha" && cmp -s "$L/boot-staged.lst" "$L/boot-switch.lst" && ok "kernel switch install left /boot unchanged" || bad "kernel switch install changed /boot"
KSIB=$(dpkg -L h96-kernel-switch | grep '/initramfs-tools/scripts/init-bottom/.' || true)   # r15+ init-bottom scripts
. /etc/armbian-release; echo "INITRD_ARCH=$INITRD_ARCH"
T=$(mktemp -d /tmp/kstage.XXXX)
for r in $RELS; do
  S=/usr/lib/h96-kernel/$r
  (cd "$S" && sha256sum -c --status SHA256SUMS.kernel) && ok "$r SHA256SUMS.kernel" || bad "$r SHA256SUMS.kernel"
  (cd "$S/dtb" && sha256sum -c --status SHA256SUMS.dtb) && ok "$r SHA256SUMS.dtb" || bad "$r SHA256SUMS.dtb"
  [ -s "/usr/lib/modules/$r/modules.dep.bin" ] && ok "$r depmod outputs" || bad "$r depmod outputs"
  echo "modules $r: $(find "/usr/lib/modules/$r" -name '*.ko*' | wc -l) ko"
  dpkg -S "/usr/lib/modules/$r/kernel" > /dev/null && ok "dpkg owns $r module tree" || bad "dpkg owns $r module tree"
  # initramfs: mkinitramfs only (no update-initramfs, no post-update hooks), u-boot legacy header as Armbian 99-uboot
  mkinitramfs -o "$T/initrd.img-$r" "$r" > "$L/mkinitramfs-$r.txt" 2>&1 && ok "mkinitramfs $r" || bad "mkinitramfs $r"
  mkimage -A "$INITRD_ARCH" -O linux -T ramdisk -C gzip -n uInitrd -d "$T/initrd.img-$r" "$T/uInitrd-$r" > "$L/mkimage-$r.txt" 2>&1 && ok "mkimage $r" || bad "mkimage $r"
  lsinitramfs "$T/initrd.img-$r" | sort > "$L/initrd-$r.lst"
  grep -q "usr/lib/modules/$r/modules.dep" "$L/initrd-$r.lst" && ok "initrd $r holds own modules" || bad "initrd $r holds own modules"
  [ -z "$(grep -E '^usr/lib/modules/' "$L/initrd-$r.lst" | grep -v "^usr/lib/modules/$r")" ] && ok "initrd $r holds no other module tree" || bad "initrd $r holds other module tree"
  grep -qx 'usr/lib/firmware/edid/h96-sink-audio.bin' "$L/initrd-$r.lst" && ok "initrd $r holds EDID" || bad "initrd $r EDID"
  for b in $KSIB; do grep -qx "usr/share/initramfs-tools/${b#*/initramfs-tools/}\|${b#*/initramfs-tools/}" "$L/initrd-$r.lst" && ok "initrd $r holds ${b##*/} (kernel switch init-bottom)" || bad "initrd $r lacks kernel switch ${b#*/initramfs-tools/}"; done
  install -m 0644 -o root -g root "$S/Image" "/boot/Image-$r"
  install -m 0644 -o root -g root "$T/uInitrd-$r" "/boot/uInitrd-$r"
  cmp -s "$S/Image" "/boot/Image-$r" && ok "boot Image-$r == staged" || bad "boot Image-$r"
  dumpimage -l "/boot/uInitrd-$r" > "$L/uinitrd-header-$r.txt" 2>&1; cat "$L/uinitrd-header-$r.txt"
done
# board DTB = default release; fallback DTB copy for manual relink
install -m 0644 -o root -g root "/usr/lib/h96-kernel/$K/dtb/$DTBN" "/boot/dtb/$DTBN"
if [ "$FB" != none ]; then install -m 0644 -o root -g root "/usr/lib/h96-kernel/$FB/dtb/$DTBN" "/boot/dtb/$DTBN.6.1"; fi
ln -sfn "Image-$K" /boot/Image; ln -sfn "uInitrd-$K" /boot/uInitrd
# v7.2 kernel out of image (owner D4): /boot files and unowned module tree
if dpkg -S "/usr/lib/modules/$OLDK" > /dev/null 2>&1; then bad "v7.2 module tree owned by a package"
else rm -rf "/usr/lib/modules/$OLDK"; fi
rm -f "/boot/Image-$OLDK" "/boot/uInitrd-$OLDK" "/boot/dtb/$DTBN.v7.2"
rm -rf "$T"; sync
# read-back
[ "$(readlink /boot/Image)" = "Image-$K" ] && [ "$(readlink /boot/uInitrd)" = "uInitrd-$K" ] && ok "Image/uInitrd links on $K" || bad "links"
cmp -s "/usr/lib/h96-kernel/$K/dtb/$DTBN" "/boot/dtb/$DTBN" && ok "boot DTB == $K staged" || bad "boot DTB"
if [ "$FB" != none ]; then
  cmp -s "/usr/lib/h96-kernel/$FB/dtb/$DTBN" "/boot/dtb/$DTBN.6.1" && ok "boot DTB .6.1 == $FB staged" || bad "boot DTB .6.1"
  [ -f "/boot/Image-$FB" ] && [ -f "/boot/uInitrd-$FB" ] && ok "fallback $FB plain files in /boot" || bad "fallback files"
fi
grep -qx "fdtfile=$DTBN" /boot/armbianEnv.txt && ok "armbianEnv fdtfile" || bad "armbianEnv fdtfile"
[ ! -e /boot/extlinux ] && ok "no /boot/extlinux" || bad "/boot/extlinux exists"
[ ! -e "/boot/Image-$OLDK" ] && [ ! -e "/boot/uInitrd-$OLDK" ] && [ ! -e "/boot/dtb/$DTBN.v7.2" ] && [ ! -e "/usr/lib/modules/$OLDK" ] && ok "v7.2 kernel files removed" || bad "v7.2 kernel files left"
grep -q '^Package: linux-image-\* linux-dtb-\* linux-u-boot-\* armbian-bsp-\*' /etc/apt/preferences.d/00-h96-protect-boot && ok "apt pin 00-h96-protect-boot" || bad "apt pin"
grep -qx 'update_initramfs=no' /etc/initramfs-tools/update-initramfs.conf && ok "update_initramfs=no" || bad "update_initramfs"
snap post
ls -laR /boot > "$L/boot-lsR-post.txt"
diff "$L/boot-pre.lst" "$L/boot-post.lst" > "$L/boot-diff.txt"; cat "$L/boot-diff.txt"
echo "fail=$fail"; exit $fail
