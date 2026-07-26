# Changelog

Versions refer to the board-support/image revisions this repo reproduces.

## v3.1
- **Working front-panel VFD.** Added the `h96-vfd` daemon (`packages/bsp/.../src/h96-vfd.c`
  + `h96-vfd.service`): shows the clock (HH:MM + blinking colon) and lights the
  Ethernet / WiFi / USB / play status icons from live system state. The panel is a
  **TM1650** driven by bit-banging GPIO3 — see the comments in `h96-vfd.c`.

## v3 — open GPU + WiFi + tidy boot
- **Open Mali GPU (Panthor).** Dropped the closed vendor Mali blob for the open
  **Panthor** kernel driver + **Mesa (Panfrost + PanVK)**. GPU-composited KDE/GNOME
  desktop, open **Vulkan (PanVK 1.4)**, GPU at up to **1000 MHz**. Requires the
  device-tree `gpu-supply` + `CLK_GPU` + OPP changes (see `docs/DEVICE-TREE-CHANGES.md`)
  and the `QT_XCB_GL_INTEGRATION` / `KWIN_COMPOSE` environment settings.
- **Onboard WiFi 6.** Enabled the **PCIe BCM43752 / AP6275P** (802.11ax), running
  simultaneously with Ethernet. Enable `pcie2x1l0`, disable the vestigial `&sdio`
  node, pair with `bcmdhd` PCIe (or mainline `brcmfmac`) + firmware.
- **Hardware video** via mpv + Rockchip MPP (VPU decode).
- **Tidy boot.** Disabled the unused `es8311` codec + `i2s0` sound, dropped the
  noisy serial `dmas`, quieted the kernel log (`printk 3 4 1 7`, `loglevel=3`).
- **IR** as a userspace-learnable `gpio-ir-receiver` overlay (see `patch/overlays/`).

Earlier revisions (v1/v2) were vendor-blob GPU builds and are superseded by v3.
