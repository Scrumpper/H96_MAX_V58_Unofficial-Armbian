#!/bin/bash
LOG=/var/log/h96-firstboot.log
exec > >(tee -a "$LOG") 2>&1
REL="$(sed -n 's/^H96_RELEASE=//p' /etc/h96-release 2>/dev/null)"
echo "=== H96 Max V58 First Boot ${REL:-} ==="
date

echo "[0] Expanding root filesystem to fill eMMC..."
parted -s /dev/mmcblk0 resizepart 2 100% 2>&1 || true
partprobe /dev/mmcblk0 2>/dev/null || true
udevadm settle 2>/dev/null || true
# armbian-resize-filesystem grows root later when kernel still sees old partition size
resize2fs /dev/mmcblk0p2 2>&1 || echo "  resize2fs failed (see above)"
echo "  root filesystem size: $(df -h / | awk 'NR==2{print $2}')"

chattr -i /etc/armbian-release 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-h96.conf 2>/dev/null || true

# armbian-config's gnome.sh postinst runs dconf update before GNOME packages are
# installed, dconf not available yet gives "not found"; patch to skip if missing
if [ -f /usr/share/armbian-config/desktops/postinst/gnome.sh ]; then
    sed -i 's/^dconf update$/command -v dconf \&\& dconf update || true/' \
        /usr/share/armbian-config/desktops/postinst/gnome.sh
fi

chmod +x /usr/lib/h96/h96-firstboot.sh \
         /usr/lib/h96/h96-gaming-setup.sh \
         /usr/lib/h96/h96-gpu-setup.sh \
         /usr/lib/h96/h96-power-profiles.py \
         /usr/lib/h96/h96-gnome-configure.sh \
         /usr/lib/h96/h96-kde-configure.sh \
         /usr/bin/settings-launch 2>/dev/null || true

systemctl set-default multi-user.target 2>/dev/null || true

# gdm may not be installed yet; add to GPU groups if it is
usermod -aG video,render gdm 2>/dev/null && \
    echo "  gdm added to video,render" || \
    echo "  gdm not present yet (path unit will handle it)"

# ensure python3-dbus + python3-gi available for h96-power-profiles
python3 -c 'import dbus; from gi.repository import GLib' 2>/dev/null || \
    apt-get install -y --no-install-recommends python3-dbus python3-gi 2>/dev/null || true

# mask power-profiles-daemon only, upowerd still runs for battery/lid/device management;
# h96-power-profiles claims org.freedesktop.UPower.PowerProfiles and net.hadess.PowerProfiles
systemctl mask power-profiles-daemon.service 2>/dev/null || true
systemctl enable h96-power-profiles.service 2>/dev/null || true

# enable desktop path watchers, fire when armbian-config installs gdm3 or sddm
systemctl enable h96-gnome-configure.path 2>/dev/null || true
systemctl enable h96-kde-configure.path 2>/dev/null || true

for svc in h96-vfd h96-leds h96-gaming-setup h96-gpu-setup; do
    systemctl enable "${svc}.service" 2>/dev/null || true
done

echo "[+] Masking unnecessary services..."
for svc in \
    ModemManager.service avahi-daemon.service avahi-daemon.socket \
    apt-daily.service apt-daily.timer apt-daily-upgrade.service \
    apt-daily-upgrade.timer man-db.timer motd-news.timer motd-news.service \
    ua-timer.timer update-notifier-download.timer fwupd-refresh.timer \
    e2scrub_all.timer \
    bluetooth.service \
    colord.service; do
    systemctl mask "$svc" 2>/dev/null && echo "  masked $svc" || echo "  skip $svc (ok)"
done
systemctl disable e2scrub_reap.service 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true
systemctl enable h96-tune.service 2>/dev/null || true
systemctl start h96-tune.service 2>/dev/null || true

touch /var/lib/h96-firstboot-done
# self-retire: Wants=armbian-firstrun.service re-pulls firstrun every boot (systemd
# resolves Wants before conditions), and armbian-fix regenerates /etc/machine-id each
# time, churning SSH host keys and losing the journal; remove both pull-points
systemctl disable h96-firstboot.service 2>/dev/null || true
rm -f /usr/lib/systemd/system/multi-user.target.wants/h96-firstboot.service
echo "  firstboot done"
