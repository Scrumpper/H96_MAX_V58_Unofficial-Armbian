 # H96 Max V58 — Unofficial Armbian v2 — Changelog

Built on Armbian 26.05 / Ubuntu 26.04 Resolute, BSP kernel 6.1.x-rk3588-ophub.

---

## v2 *(current)*

# WORKING **LightDM** plus a fully-offline
desktop and gaming stack.

### LightDM fix

LightDM was non-functional in every prior release — the greeter started an X server that
died on the spot. The cause is in the RK3588 BSP HDMI driver: it collapses the DDC i2c bus
when Xorg polls EDID, killing the X session before the greeter can draw.

The fix has two parts, now both in place:

1. **Global Xorg workaround, baked in.** `/etc/X11/xorg.conf.d/20-h96-display.conf` ships
   unconditionally with `modesetting` + `ShadowFB "true"` + `PageFlip "false"` and screen
   blanking disabled. This sidesteps the i2c collapse for **every** X11 session, not just
   LightDM. (Earlier builds applied this only via a per-LightDM path unit; it's now global.)
2. **LightDM installs offline.** `lightdm` and `lightdm-gtk-greeter` are in the baked local
   APT repo, so `apt install lightdm lightdm-gtk-greeter` works with no internet. The
   `h96-lightdm-configure` path unit still fires on install to set `minimum-vt=1`, add
   `lightdm` to the `video`/`render` groups, and enable the service.

Result: install an X11 desktop + LightDM and you get a working login screen out of the box.

### Other bug fixes & improvements

- **Fully-offline desktop + gaming installs.** `/opt/h96-pkgs/` is a real
  `dpkg-scanpackages` APT repo (456 debs, ~448 MB) registered as
  `deb [trusted=yes] file:///opt/h96-pkgs ./`. It carries the full dependency closure of
 , LightDM, Wine/Wine64, DXVK, and the firstboot Python deps, alongside the
  existing gaming/GPU packages. Verified on the live unit: with all online repos removed,
  `apt install cinnamon lightdm wine dxvk` resolves **288 packages with zero errors**.
- **No boot-time network fetches.** Firstboot's DXVK / Wine / `python3-dbus` / `python3-gi`
  installs now resolve from the local repo, so a first boot with no internet completes
  without errors.
- **One global X11 display config** replaces the old per-desktop configure path units —
  covers Cinnamon, XFCE, MATE, i3, and Enlightenment with a single baked file.

### Carried over from the previous release

- **Ethernet reconnect fix** — removed the stale `wpasupplicant` ifupdown symlinks from
  `/etc/network/if-up.d/` and `/etc/network/if-post-down.d/`. NetworkManager owns every
  interface on this image, so those hooks were firing `wpa_supplicant` with no config and
  throwing "network binary not found" on ethernet plug/unplug.
- **Bluetooth (experimental, manual)** — `h96_bt.py` userspace BCM4345C0 firmware loader.
  Not auto-enabled (bluez isn't in the base image). Firmware loads cleanly; post-firmware
  HCI attach is still best-effort.

---

For the complete project history (v001 → present), see the running changelog in the
project root.
