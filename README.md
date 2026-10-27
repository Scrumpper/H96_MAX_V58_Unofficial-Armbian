# H96 Max V58 · Unofficial Armbian v8.0 (RK3588)

**Board sources and release docs** · kernel 6.12 with 6.1 fallback · Panthor GPU · Ubuntu and Debian Edition images

---

Unofficial Armbian for **H96 Max V58** TV box (Rockchip **RK3588**, Mali-G610 MC4,
64 GB eMMC). GPU runs open **Panthor** kernel driver with **Mesa** (Panfrost GL, PanVK
Vulkan); no closed Mali blob. Video decodes and encodes on Rockchip VPU, onboard WiFi 6 runs
on PCIe beside Ethernet, front-panel display shows clock and status icons.

This repository holds board sources (device tree overlay, kernel configuration, kernel and
device tree package builder, `h96-kernel-switch`, board support files, front-panel daemon)
and docs to rebuild and verify release images. Sources are GPL-2.0; see
[`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md).

> **Unofficial.** Not affiliated with, endorsed by, or supported by Armbian,
> Rockchip, or H96 manufacturer. It has been tested only on author's own unit and
> comes with **no warranty**. Always keep recovery plan before overwriting your device.

---

## Contents

1. [Downloads](#downloads)
2. [Editions](#editions)
3. [What v8.0 includes](#what-v80-includes)
4. [Kernels: 6.12 default, 6.1 fallback](#kernels-612-default-61-fallback)
5. [Hardware status](#hardware-status)
6. [Verify download](#verify-download)
7. [Flashing](#flashing)
8. [First boot](#first-boot)
9. [Build and verify from source](#build-and-verify-from-source)
10. [Repository layout](#repository-layout)
11. [Docs](#docs)
12. [Known limitations](#known-limitations)
13. [License and credits](#license-and-credits)

---

## Downloads

Images are published on [Releases page](https://github.com/Scrumpper/H96_MAX_V58_Unofficial-Armbian/releases).
v8.0 release carries one zip per edition:

| Asset | Contents |
|---|---|
| `Unofficial.Armbian.v8.0.zip` | Ubuntu image `H96-MAX-V58_Unofficial-Armbian_v8.0.img.xz`, sha256 sidecars, `flash.py`, `MiniLoaderAll.bin`, `FLASHER-SHA256SUMS.txt`, release docs (`README.md`, `FLASHING.md`, `COMMANDS.md`, `CHANGELOG-v8.0.md`, `KERNEL-COMPARISON.md`) |
| `Unofficial.Armbian.v8.0.Debian.Edition.zip` | Debian Edition image `H96-MAX-V58_Unofficial-Armbian_v8.0-debian.img.xz`, same sidecars, flasher and doc set, plus `DEBIAN-EDITION.md` |
| `CHANGELOG-v8.0.md` | v8.0 change list |

Release `README.md` inside each zip is full instruction booklet: desktop install,
networking, hardware video, power profiles, Steam, Android container, Bluetooth, TV remote,
backup and restore.

---

## Editions

Both editions carry same boot chain, kernels, `h96-kernel-switch` and eight H96 userland
packages. Both boot to text console with SSH; desktop installs on demand.

| Area | Ubuntu image | Debian Edition |
|---|---|---|
| Distribution | Ubuntu 26.04 Resolute, Armbian 26.05 | Debian 13 trixie, Armbian 26.8.3 root filesystem |
| KDE Plasma (on demand) | 6.6 | 6.3 |
| Mesa | 26.1.4 | 26.1.6 (trixie-backports), pinned exact |
| PipeWire, WirePlumber | 1.6.2, 0.5.18 | 1.6.9, 0.5.18 rebuilt for trixie |
| `h96-vulkan-wsi` (opt-in PanVK Wayland presentation) | in offline repository | not provided |
| ophub tools (`armbian-sync`, `armbian-ddbr`) | present | absent |

Debian Edition build method and full difference list: [docs/DEBIAN-EDITION.md](docs/DEBIAN-EDITION.md).

---

## What v8.0 includes

v8.0 is platform release over v7.2. Full list: `CHANGELOG-v8.0.md` in release, history in
[CHANGELOG.md](CHANGELOG.md).

- **Kernel 6.12.69 default**, Rockchip `rk-6.12-rkr1` with H96 patch series (cursor fixes,
  HDMI-CEC, HDMI 2.0 modes over GPIO DDC bus, colour-format switch, HDR, RGA). Kernel
  6.1.172 installed beside it as fallback.
- **Panthor GPU interface 1.5** on 6.12: Vulkan timestamps, global priority query, per-process
  GPU memory in `/proc/<pid>/fdinfo`, per-process GPU time with profiling switch (off by
  default).
- **RAM scaling** on 6.12: DDR 528 to 2112 MHz on demand, floor follows display bandwidth.
- **Power Save profile**: `schedutil` with capped big and little cores and GPU 300 to
  600 MHz; 4K60 mpv playback with 0 dropped frames in 60 s on test unit.
- **Kernel hardening** on 6.12: `LIST_HARDENED`, `RANDOM_KMALLOC_CACHES`, `SLAB_BUCKETS`;
  eMMC host software queue on.
- **Variable refresh**: FreeSync over HDMI in Plasma X11 session with `sudo h96-vrr on`
  (off by default).
- **TV remote over HDMI-CEC**, on by default with CEC TV; display wake turns TV on and
  switches input.
- **Display hotplug** on 6.12: EDID read again at every probe; short HPD drops keep desktop
  output.
- **Packages**: H96 userland in eight dpkg packages (`h96-base`, `h96-boot`, `h96-net`,
  `h96-audio`, `h96-desktop`, `h96-media`, `h96-tools`, `h96-gaming`), files in `/usr/bin`,
  `/usr/sbin` and `/usr/lib/h96`, manual page per command. `libmali` removed: Mesa only.
- **Boot firmware**: BL31 v1.37 in U-Boot FIT, written when image is flashed.
- **Plasma (Wayland) session**, experimental, beside default Plasma (X11).
- **Steam ARM 3.1** from package `steam-arm-setup`, installed through `h96-steam`.
- **First boot** reboots once; flasher can read whole image back and compare sha256.

---

## Kernels: 6.12 default, 6.1 fallback

| Kernel | Release | Role |
|---|---|---|
| 6.12.69 (`rk-6.12-rkr1`) | `6.12.69-h96v58-8.0` | default: Panthor interface 1.5, RAM scaling, eMMC software queue, hardening options |
| 6.1.172 (`rk-6.1-rkr7.2`) | `6.1.172-h96v58-8.0` | fallback: same feature set as v7.2 kernel; no RAM scaling |

Each kernel has own modules (`/usr/lib/modules/<release>`) and device tree.
`h96-kernel-switch` boots chosen kernel as trial; Image, initramfs and device tree switch
together through one link (`/boot/h96ks/cur`):

```bash
h96-kernel-switch list                              # staged kernels: running, default, trial
sudo h96-kernel-switch try 6.1.172-h96v58-8.0       # next boot runs fallback kernel as trial
sudo reboot
sudo h96-kernel-switch confirm                      # in trial boot: keep it as default
sudo h96-kernel-switch rollback                     # back to kernel default before last confirm
```

Reboot without `confirm` returns to previous kernel. Kernel packages never write `/boot`;
apt pin `00-h96-protect-boot` keeps foreign kernel, device tree, U-Boot and `flash-kernel`
packages out, so kernels arrive with image releases. Design, refusals and power-loss cases:
[docs/KERNEL-SWITCH.md](docs/KERNEL-SWITCH.md).

---

## Hardware status

| Component | Status | Notes |
|---|---|---|
| CPU (RK3588, 4x A76 + 4x A55) | ✅ | Big cores up to 2208 MHz (vendor OPP table end); A76 on cpu1 to cpu4, A55 on cpu0 and cpu5 to cpu7 |
| Mali-G610 GPU | ✅ | Panthor + Mesa (Panfrost GL, PanVK Vulkan); GPU-composited desktop |
| Hardware video decode | ✅ | Rockchip MPP + mpv; 8-bit H.264, HEVC, VP9 and AV1 on zero-copy path |
| Hardware video encode | ✅ | H.264, HEVC and MJPEG through `h96-encode` |
| HDMI0 + audio | ✅ | One output; EDID over GPIO DDC bus; HDMI 2.0 modes up to 3840x2160 at 60 Hz and 2560x1440 at 144 Hz |
| HDMI-CEC | ✅ | TV remote drives desktop, mpv and Kodi; on by default |
| Ethernet | ✅ | RTL8211F Gigabit |
| WiFi 6 (BCM43752 / AP6275P) | ✅ | **PCIe**, runs beside Ethernet; `h96-wifi-connect` or tray icon |
| Bluetooth | ✅ | BCM4362A2; A2DP, headset microphone over HFP, mSBC where headset supports it |
| Front-panel VFD | ✅ | TM1650 clock and status icons (`h96-vfd`) |
| IR remote | ✅ | Overlay source `patch/overlays/h96-max-v58-gpio-ir.dts`, not in image; see below |
| NPU (3 cores) | ✅ | Per-core load through `h96-npu`; inference runtime fetched on demand by `h96-npu-setup`, never bundled |
| eMMC | ✅ | Host software queue on kernel 6.12 |

**IR remote.** Overlay swaps IR pin (GPIO0_D4) to mainline `gpio-ir-receiver`, so any NEC
remote can be learned with `ir-keytable` (needs network; not in offline repository):

```bash
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo patch/overlays/h96-max-v58-gpio-ir.dts
sudo cp h96-max-v58-gpio-ir.dtbo /boot/overlay-user/
# append to /boot/armbianEnv.txt:   user_overlays=h96-max-v58-gpio-ir
sudo reboot
ir-keytable -p nec -t      # press remote buttons -> prints scancodes
```

**Thermals.** Trip points are SoC BSP defaults: `soc-thermal` passive 80 and 95 C, other
zones passive 75 C, critical 115 C on all. Measured on one unit: idle about 52 to 61 C;
sustained all-core `performance` load reached 85 C and throttles.

---

## Verify download

Every image carries sha256 sidecars. From unpacked release folder, before decompressing:

```bash
sha256sum -c *.sha256 FLASHER-SHA256SUMS.txt   # every line OK
```

`.img.xz.sha256` holds sum of compressed image, `.img.sha256` sum of decompressed `.img`
(flasher read-back compares against it), `FLASHER-SHA256SUMS.txt` sums of `flash.py` and
`MiniLoaderAll.bin`, `SHA256SUMS` repeats `.img.xz` line.

Offline package repository in image (`/opt/h96-pkgs`) is GPG-signed and apt checks every
package against it. Public key is in this repository:
`packages/bsp/h96-max-v58/apt/keyrings/h96-local-archive-keyring.gpg`, fingerprint
`97E5DA90A046ECDC7CE5637131869ED166A6D9EC` (`gpg --show-keys <file>` prints it). Private
key is not published.

---

## Flashing

Flashing erases whole eMMC: desktop, user account, Android images and emulator data are
gone. Back up first (`h96-backup`; boxes on v7.x or earlier install `h96-migrate-kit.zip`
from release). Needed: Linux host with `rkdeveloptool` and `xz`, USB-A to USB-A data cable,
image and `MiniLoaderAll.bin` from release zip. Windows hosts use WSL or Rockchip's
RKDevTool GUI with same loader and image.

**Scripted.** From unpacked release folder:

```bash
python3 flash.py            # puts box in Maskrom, loads loader, writes image, reboots
python3 flash.py --verify   # also reads whole image back and compares sha256 before reboot
```

**By hand.**

1. Enter flashing mode. Box running Armbian: `ssh root@<ip> 'reboot loader'`. Box that will
   not boot: power off, hold recessed pinhole button (rear panel, gap between two WiFi
   antenna posts) while plugging cable into black USB2 port, release after about 3 s.
   `rkdeveloptool ld` reports `Loader` or `Maskrom`.

2. `db` runs in Maskrom only. From Loader, erase and reset into Maskrom:

   ```bash
   rkdeveloptool ef
   rkdeveloptool rd
   sleep 5
   rkdeveloptool ld        # Maskrom
   ```

   Box started through pinhole is already in Maskrom and skips this step.

3. Load loader into RAM, write image, read back, compare, reset:

   ```bash
   xz -dk H96-MAX-V58_Unofficial-Armbian_v8.0.img.xz
   sha256sum -c H96-MAX-V58_Unofficial-Armbian_v8.0.img.sha256
   rkdeveloptool db MiniLoaderAll.bin
   rkdeveloptool wl 0 H96-MAX-V58_Unofficial-Armbian_v8.0.img
   rkdeveloptool rl 0 <sectors> readback.img     # sectors = image bytes / 512
   sha256sum readback.img                        # equal to .img.sha256, then delete readback.img
   rkdeveloptool rd
   ```

   Debian Edition: same steps with `H96-MAX-V58_Unofficial-Armbian_v8.0-debian.img`. Without
   `db`, `wl` fails with `Write LBA failed!`. On read-back mismatch, repeat `db` and `wl`
   before reset. Never interrupt `wl` once it starts.

Full guide with slimming options and troubleshooting: `FLASHING.md` in release zip.

---

## First boot

Console login `root` / `1234` on HDMI and over SSH (`ssh root@h96max` or `ssh root@<ip>`);
change password. First-boot setup (about 5 to 10 min) expands root filesystem and installs
Mesa from signed offline repository, then reboots once. After reboot, network can take
minutes (DHCP, Gigabit negotiation) and DHCP address can change.

Desktop: `armbian-config` (System, Desktop) or `apt install kde-plasma-desktop`, then
`h96-autologin-setup` for LightDM autologin on Plasma (X11) session. Plasma (Wayland) is
experimental: `sudo h96-autologin-setup --session plasma`.

---

## Build and verify from source

- [docs/REPRODUCE.md](docs/REPRODUCE.md): rebuild Ubuntu image, kernels and userland
  packages from pinned inputs and compare against published sha256 sums.
- [docs/REPRODUCE-DEBIAN.md](docs/REPRODUCE-DEBIAN.md): rebuild Debian Edition image.
- [docs/DEBIAN-EDITION.md](docs/DEBIAN-EDITION.md): Debian Edition base, packages, offline
  repository and differences.
- `build/build-kernel-debs.sh` wraps kernel build outputs into `h96-kernel-<krel>` and
  `h96-dtb-<krel>` (payload `/usr/lib/h96-kernel/<krel>`, modules `/usr/lib/modules/<krel>`,
  nothing under `/boot`); `PIN=1` (default) checks each input against pinned sha256.
- `tools/dtb/` builds board DTB from vendor base DTB plus `patch/dt/h96-max-v58.dtso` and
  checks it by tree diff against pinned reference ([docs/DEVICE-TREE-CHANGES.md](docs/DEVICE-TREE-CHANGES.md)).
- CI runs docs gates, shell lint, tree diff and package checks ([docs/CI.md](docs/CI.md)).

---

## Repository layout

```
build/
  build-kernel-debs.sh             kernel + DTB packages from build outputs (pinned sha256)
  build-kernel-switch-deb.sh       h96-kernel-switch package
config/
  boards/h96-max-v58.tvb           Armbian board file (TV-box class)
  linux-rk35xx-vendor.config       full 6.1 vendor kernel .config (v6.x era)
  kernel-h96-max-v58.config        summary of that config against vendor default
dtb/pinned/                        vendor base DTB, reference DTB, SHA256SUMS (tree-diff inputs)
patch/
  dt/h96-max-v58.dtso              board changes as overlay on vendor base DTB
  dt/h96-max-v58.delete            property deletions overlay cannot express
  overlays/h96-max-v58-gpio-ir.dts IR receiver overlay
  kernel/                          v6.x-era board DTS and kernel patches (VOP2 cursor,
                                   board support, HDMI DDC and CEC, EDID, HDMI audio)
packages/
  bsp/h96-max-v58/                 board support files from v6.x and v7.x (tools, units,
                                   udev rules, audio config, VFD daemon source, offline
                                   repo source and public key); 8.0 packages install them
                                   under /usr/bin, /usr/sbin, /usr/lib/h96
  h96-kernel-switch/               h96-kernel-switch package source and manual page
tools/
  h96-selftest.py                  read-only health checks (boot, hw, invariants, report)
  kernel-switch/                   h96-kernel-switch test suite (stub root)
  dtb/                             overlay DTB build and tree-diff gate
  docs/                            docs style gates
  ci/                              CI helpers
docs/                              see docs/README.md
```

Front-panel daemon builds from `packages/bsp/h96-max-v58/src` with `make` (native) or
`make CROSS=aarch64-linux-gnu-`.

---

## Docs

Index of every doc: [docs/README.md](docs/README.md).

---

## Known limitations

- **Power off** enters firmware standby and restarts about 45 s later (hardware watchdog),
  on both kernels. Unplug power after shutdown.
- **One HDMI output** (HDMI0). Multichannel HDMI audio not verified.
- **10-bit video** (HEVC Main10, VP9 profile 2, AV1 10-bit) decodes in software and drops
  frames at 4K60.
- **In-browser video decode** stays on CPU; use ff2mpv "play in mpv" path.
- **WiFi** is managed by `h96-wifi-connect` or tray icon, not `nmcli`.
- **Ethernet link** can take minutes after boot while RTL8211F negotiates Gigabit before
  downshifting; `ethtool -s eth0 speed 100 duplex full autoneg off` skips Gigabit
  negotiation at cost of capping port.
- **Plasma (Wayland) session** is experimental: 4K60 video drops frames at 3840x2160
  output, no RGB range control, no VRR. Run Proton titles in Plasma X11 session.
- **Fallback kernel 6.1** has no RAM scaling.
- **Boot firmware** changes only with fresh flash; package upgrades never touch it.
- **Anti-cheat titles** do not run under x86-on-arm64 emulation; Steam snap does not work
  on this GPU stack.

Full list: release `README.md`, Known limitations.

---

## License and credits

GPL-2.0-only. See [`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md). Built on
Armbian, Linux kernel, Rockchip's BSP, Panthor, and Mesa.

---

This project is not affiliated with, endorsed by or sponsored by Valve Corporation. Steam, Proton, Steam Deck and Steam Frame are trademarks of Valve Corporation. Image contains no Valve artwork.
