# Changelog

Versions refer to the board-support/image revisions this repo reproduces.

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
