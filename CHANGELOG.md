# Changelog

```
 █████╗ ██╗   ██╗██████╗ ██╗ ██████╗   ███████╗██╗██╗  ██╗
██╔══██╗██║   ██║██╔══██╗██║██╔═══██╗  ██╔════╝██║╚██╗██╔╝
███████║██║   ██║██║  ██║██║██║   ██║  █████╗  ██║ ╚███╔╝ 
██╔══██║██║   ██║██║  ██║██║██║   ██║  ██╔══╝  ██║ ██╔██╗ 
██║  ██║╚██████╔╝██████╔╝██║╚██████╔╝  ██║     ██║██╔╝ ██╗
╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝ ╚═════╝   ╚═╝     ╚═╝╚═╝  ╚═╝

                           v3.4                           
```

Versions refer to the board-support/image revisions this repo reproduces.

## v3.4 (released as a pre-built image; the EDID below IS reproducible here)

**⚠️ If you followed the v3.3 instructions below, HDMI audio is disabled on your build.
Apply this instead.**

v3.3 told you to add `drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin` to stop the HDMI EDID
retry storm. It does stop the storm, and it also **silently disables HDMI audio**. Video is
unaffected, so it does not look like a display problem at all.

**Why.** Every EDID blob compiled into the kernel (`drivers/gpu/drm/drm_edid_load.c`,
`generic_edid[]`) is 128 bytes with **no CTA/CEA extension block**. HDMI audio capability is
declared in that block. With no CTA block, `drm_detect_hdmi_monitor()` returns false, the
driver sets `sink_is_hdmi = false`, and `dw_hdmi_qp_setup()` then programs `OPMODE_DVI`,
which drops every data island: audio sample packets and infoframes alike.

Note the consequence: **having no EDID at all is better than having one that declares no
audio.** With no EDID the driver takes an explicit fallback that sets `support_hdmi = true`
and `sink_has_audio = true`. The v3.3 argument moved the board out of that fallback.

Measured on hardware, same board and display, changing only this argument:

| | kernel built-in `1920x1080.bin` | no argument | `h96-1080p-audio.bin` |
|---|---|---|---|
| dmesg | `dw_hdmi_qp_setup DVI mode` | tmds mode | tmds mode |
| `/sys/kernel/debug/dw-hdmi0/status` | `PHY: disabled` | `PHY: enabled  Mode: HDMI` | `Mode: HDMI` |
| ELD | `SAD_Count=0` | zeros | `SAD_Count=1`, LPCM 2ch |
| HDMI audio | **none** | works | works |

**The fix.** This repo now ships a 256-byte EDID that declares 1080p60 plus an HDMI VSDB and
an LPCM audio descriptor:

```
packages/bsp/h96-max-v58/edid/h96-1080p-audio.bin
```

Install it to `/lib/firmware/edid/h96-1080p-audio.bin` (mode 0644) and use:

```
drm.edid_firmware=HDMI-A-1:edid/h96-1080p-audio.bin
```

Keep the existing `video=HDMI-A-1:1920x1080@60` argument alongside it.

**Do not put this file in the initramfs.** It is tempting, because loading it earlier would
also recover about 1.85 seconds of startup, and the file otherwise loads only on the
post-rootfs connector reprobe (you will see two `Direct firmware load ... error -2` lines
before it succeeds). An earlier version of this project tried exactly that and **the box
would not boot**: this U-Boot and kernel will not boot a uImage `uInitrd` with a prepended
early cpio, and the connector probe fails before the root filesystem is mounted. Leave
`uInitrd` alone and accept the startup cost.

**Why not simply drop the argument.** The retry storm is not only a startup cost. The DRM
connector hotplug poll keeps retrying for as long as the board is powered. Measured: with no
argument, 108 timeouts by 99 seconds and still climbing at roughly one per second; with this
EDID, 19 timeouts, and it stays at 19.

## v3.3 (superseded by v3.4: the boot argument below disables HDMI audio, see above)

An efficiency pass on top of v3.2. Most of it is root filesystem configuration and so is
not reproducible from this repo, with **one exception that is**: the HDMI boot argument.

- **HDMI EDID retry storm removed (boot argument, applies to builds from this repo).**
  This board does not route the HDMI DDC lines through to the display controller, so the
  kernel's attempt to read the monitor's EDID can never succeed. It retried 18 times on
  every boot before giving up, then used the resolution already set in the boot
  configuration anyway. Measured cost: 18 timeouts, and kernel startup time of 4.26s.

  Add this to `extraargs` in `/boot/armbianEnv.txt`:

  ```
  drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin
  ```

  **⚠️ DO NOT USE THIS LINE. It disables HDMI audio.**
  Use `edid/h96-1080p-audio.bin` instead, see v3.4 above.

  `edid/1920x1080.bin` is one of the EDID blobs compiled into the kernel
  (`drivers/gpu/drm/drm_edid_load.c`), so no firmware file is loaded and there is no root
  filesystem or initramfs dependency. The kernel confirms this by logging
  `Got built-in EDID`, not `external`. Result: 18 timeouts drop to 1, and kernel startup
  time drops to 2.58s.

  Note there is no `ddc-i2c-bus` property on the HDMI node to fix instead; the driver uses
  an internal DDC controller. This is a boot argument, not a device tree change.

  Setting a resolution still works exactly as before. `video=HDMI-A-1:...` overrides the
  forced EDID: verified by booting `video=HDMI-A-1:1280x720@60` alongside it, which set the
  display controller clock to 74440000 and advertised 1280x720.

The remaining v3.3 changes are root filesystem only and are not reproducible from this
repo: the CPU governor and frequency floor defaults, moving a package retry service off the
startup path, and desktop package selection. See the pre-built image's own CHANGELOG.md.

## v3.2 (released as a pre-built image; not yet reproducible from this repo)

A pass over the faults that appear once a desktop environment is installed and
used day to day, on top of v3.1:

- **Software installation (Discover) works.** Three separate faults: no polkit
  agent was running, no rule authorized the `sudo` group, and polkit's socket
  helper requires `SO_PEERPIDFD` (Linux 6.5+), which the 6.1 vendor kernel does
  not provide, so every password prompt failed. Reported and partly diagnosed by
  **MetallixX974** in
  [issue #2](https://github.com/Scrumpper/H96_MAX_V58_Unofficial-Armbian/issues/2).
- **Bluetooth audio.** A2DP connects, and the HCI UART is raised from its 115200
  baud default to 3 Mbps after attach, which stereo audio requires. LDAC, aptX HD
  and aptX are enabled alongside SBC.
- **HDMI audio** is the default output; S/PDIF remains available.
- **WiFi works on a fresh install.** The radio came up rfkill soft-blocked with nothing
  in the image clearing it, so `wpa_supplicant` could never associate and dhcpcd refused
  to start. `systemd-rfkill` persists the unblocked state across reboots, so only
  freshly flashed boxes were affected. The WiFi unit now runs
  `rfkill unblock wifi` before starting.
- **WiFi** uses a standalone `wpa_supplicant` with a tray applet, because
  NetworkManager cannot complete this chip's multi-AKM association.
- **Hardware video** completes its first-boot setup headless, with no desktop
  installed.
- **Desktop installs keep the tier** (`minimal` / `mid` / `full`) chosen in
  `armbian-config`, instead of upgrading every install to `kde-full`.
- **The Mesa/Panthor userspace stack is pinned**, so `apt upgrade` cannot move it
  to a version that breaks GPU acceleration.

**Scope.** All of the above is userspace: systemd units, package selection and
first-boot scripts. None of it touches the kernel, device tree or BSP package
published here, so building from these sources reproduces the v3.1 feature set
(open GPU, WiFi 6, hardware video, front panel), not v3.2.

## v3.1
- **Working front-panel VFD.** Added the `h96-vfd` daemon (`packages/bsp/.../src/h96-vfd.c`
  + `h96-vfd.service`): shows the clock (HH:MM + blinking colon) and lights the
  Ethernet / WiFi / USB / play status icons from live system state. The panel is a
  **TM1650** driven by bit-banging GPIO3. See the comments in `h96-vfd.c`.

## v3: open GPU + WiFi + reduced boot output
- **Open Mali GPU (Panthor).** Dropped the closed vendor Mali blob for the open
  **Panthor** kernel driver + **Mesa (Panfrost + PanVK)**. GPU-composited KDE/GNOME
  desktop, open **Vulkan (PanVK 1.4)**, GPU at up to **1000 MHz**. Requires the
  device-tree `gpu-supply` + `CLK_GPU` + OPP changes (see `docs/DEVICE-TREE-CHANGES.md`)
  and the `QT_XCB_GL_INTEGRATION` / `KWIN_COMPOSE` environment settings.
- **Onboard WiFi 6.** Enabled the **PCIe BCM43752 / AP6275P** (802.11ax), running
  simultaneously with Ethernet. Enable `pcie2x1l0`, disable the vestigial `&sdio`
  node, pair with `bcmdhd` PCIe (or mainline `brcmfmac`) + firmware.
- **Hardware video** via mpv + Rockchip MPP (VPU decode).
- **Reduced boot output.** Disabled the unused `es8311` codec + `i2s0` sound, dropped
  the serial `dmas` that emitted repeated errors, and lowered the kernel log level
  (`printk 3 4 1 7`, `loglevel=3`).
- **IR** as a userspace-learnable `gpio-ir-receiver` overlay (see `patch/overlays/`).

Earlier revisions (v1/v2) were vendor-blob GPU builds and are superseded by v3.
