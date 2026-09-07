# H96 Max V58 · Armbian board support (RK3588)

**Hardware bring-up sources** · kernel · device tree · Panthor GPU · front-panel VFD · onboard WiFi 6

---

Board bring-up **sources** for running Armbian on **H96 Max V58** TV box
(Rockchip **RK3588**, Mali-G610) with an **open GPU** stack: Panthor kernel
driver + Mesa (Panfrost/PanVK), hardware video, onboard WiFi 6, and a working
front-panel display.

This repository exists so anyone can **inspect source and build a matching
image themselves** with official Armbian build framework, rather than
downloading a pre-built image. Everything here (device tree, overlays,
front-panel driver, board config, BSP scripts) is provided as source under
GPL-2.0. See [`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md).

> **Unofficial.** Not affiliated with, endorsed by, or supported by Armbian,
> Rockchip, or H96 manufacturer. It has been tested only on our own unit and
> comes with **no warranty**. Always keep a recovery plan before overwriting your device.

> **Scope: this repo covers hardware bring-up (kernel, device tree, front-panel
> daemon) up through v3.1.** It does not include desktop-completeness and
> reliability fixes from v3.2 and later (except HDMI EDID work, the v4.1
> Bluetooth audio + headset-mic sources, and the v4.1 `xpad` kernel driver +
> media-tool sources, which are documented in CHANGELOG.md /
> docs/BLUETOOTH-AUDIO.md / docs/MEDIA-FEATURES.md and do apply here): WiFi connection tooling,
> Discover/software-install authentication, gaming stack, and related first-boot
> automation. Compiling from these sources reproduces the open GPU, onboard WiFi 6,
> hardware video, front-panel display, and (v4.1) Bluetooth headset mic + AAC. For
> the full current feature set, use pre-built release images until the rest of that
> userspace layer is published here as well.

---

## Release images (v5.0.1)

The current release is **v5.0.1**, shipped as one pre-built full image. It boots to a
text console and does not pre-install a desktop.

| Image | Boots to | GPU | Desktop | Zip size |
|---|---|---|---|---|
| **v5.0.1** (full) | console | Mali-G610 (Panthor) + Mesa | installed on demand via `armbian-config` | 1.22 GB |

- **Kernel rebuilt with `CONFIG_PSI=y`** (`PSI_DEFAULT_DISABLED` off), from
  armbian/linux-rockchip, branch `rk-6.1-rkr5.1`, commit `95e85f6c`. Android 11 and later
  `init`/`lmkd` hard-require `/proc/pressure`; without it the Waydroid container boots and
  then dies in about 15 seconds. This is an **Image-only rebuild**: PSI is built in and the
  kernel release string is unchanged at 6.1.115, so `/lib/modules/6.1.115` stays valid and
  no module is rebuilt. Verified on hardware: 69 modules load with zero ABI errors.
  **Existing users cannot `apt upgrade` into this kernel. It needs the new image.**
- **New `h96-waydroid`**: Android in a container (Waydroid 1.6.2 plus a nested Weston
  window on X11). `init gapps|vanilla`, the default, fetches the official Waydroid
  LineageOS 20 (Android 13, vendor type MAINLINE, about 900 MB) and wires the Mali-G610:
  `dumpsys SurfaceFlinger` reports `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1
  Mesa 26.0.1`, GPU load `0@300000000Hz` at idle, 50 percent at 1000 MHz under UI activity
  and 19 to 26 percent at 600 MHz, with `boot_completed=1` about 8 seconds in and no
  cgroup v1 shims needed. `init gpu` is the LEGACY path for the third-party Panthor
  Android 11 image (LineageOS 18.1, about 5 GB, user-supplied, Mesa 24.0.5, GPU load 27 to
  41 percent at 300 to 700 MHz), unsigned and abandoned since April 2024. `init custom
  <dir>` takes your own arm64 Waydroid-style `system.img` plus `vendor.img` pair. Images
  are **not** bundled. `hw off` forces software rendering for diagnosis. The container
  **cannot use the RK3588 NPU**: its `vendor.img` carries no RKNN libraries and no
  neuralnetworks HAL.
- **New `h96-emulators`**: 8 GPU-accelerated systems (`retroarch`, `dolphin`, `ppsspp`,
  `flycast`, `melonds`, `rmg`, `azahar` as native ARM64 Flatpaks through PanVK/Panfrost,
  plus `cemu` as the x86-64 build under `box64`). `install` wires each Flatpak sandbox to
  the Mali GPU and then verifies it, warning when an emulator would silently fall back to
  `llvmpipe` software rendering.
- **`h96-npu` gains `power [performance|balanced|powersave|sync|status]`.** The NPU devfreq
  had been pinned at 1000 MHz for 100 percent of uptime while unused; `powersave` parks it
  at 300 MHz. `power sync` matches the NPU to the system CPU and GPU profile, and `sync on`
  makes it follow `h96-perf` automatically. `h96-perf` is now listed in the `h96` command
  index.
- **Efficiency:** two units that failed every boot are fixed, so `systemctl --failed`
  reports zero. `rsyslog` is disabled (`/var/log` measured 33 MB before and 3.6 MB right after; the journal is capped at 200 MB;
  `journalctl` is unaffected), and `lxc`, `lxc-net` and `lxc-monitord` are disabled.
- **v4.2.1** added the `h96` command index: type `h96` for a categorized list of every
  command, or `h96 <command>` for its help. **v4.2** was an efficiency delta on v4.1:
  faster boot, zram zstd compression, and VM sysctl tuning baked into the image.
- The full image boots to a console and does **not** ship KDE pre-installed.
  Install the desktop when you want it through `armbian-config`; first launch of Plasma
  applies the H96 desktop settings.
- The shipped flasher is slim-capable: from the full image it can strip to a headless
  (nodesktop), no-GPU, or bare-server build before writing, so one download covers desktop,
  headless, and server use. Free space is reclaimed with `zerofree` after stripping.

These sources cover the kernel, device tree, and BSP package the image is built from; the
desktop and headless split is a userspace and packaging step and is not selected from this
repo.

---

## Hardware status

| Component | Status | Notes |
|---|:---:|---|
| CPU (8-core RK3588) | ✅ | |
| Mali-G610 GPU | ✅ | Open **Panthor** + Mesa (Panfrost GLES / PanVK Vulkan 1.4); GPU-composited desktop |
| Hardware video decode | ✅ | Rockchip MPP + mpv (VPU). v4.0 corrects DMA-heap permissions that made hardware decode root-only in every earlier release; non-root users received software decode. Fix for earlier releases is in CHANGELOG |
| Hardware video **encode** | ✅ | RKVENC/RKVENC2/JPGENC via `h96-encode`; H.264 and HEVC measured faster than 180 fps at 1080p. Note bundled ffmpeg has no `libx264`, so this is only encode path |
| Display autodetect (EDID) | ✅ | `h96-display auto` sets a mode from display's EDID (bit-banged DDC read; SoC's DDC controller does not work on this kernel). Native-mode autodetect in desktop is opt-in: `sudo h96-display autodetect on` |
| Monitor brightness (DDC/CI) | ✅ | `h96-brightness`: hardware backlight over DDC/CI via a kernel i2c-gpio bus on DDC pins. ddcutil installs at first boot. Needs a DDC/CI-write-capable monitor; most TVs gate it. KDE PowerDevil shows a slider |
| Display scale | ✅ | `h96-scale <factor>`: sets KDE global scale (`kdeglobals` + font DPI) and restarts Plasma shell to apply live. On X11 a log out/in is required to reach all apps, so autologin is enabled (`h96-autologin.service`). Wayland not used (breaks GPU/compositing/mpv) |
| Ethernet | ✅ | |
| WiFi 6 (BCM43752 / AP6275P) | ✅ | **PCIe**, runs simultaneously with Ethernet |
| Bluetooth | ✅ | BCM UART |
| HDMI + audio | ✅ | |
| Front-panel VFD | ✅ | TM1650, clock + status icons (`h96-vfd`) |
| IR remote | ✅ | `gpio-ir-receiver` overlay, learn with `ir-keytable` |
| eMMC storage | ✅ | |
| GPU upscaling | ✅ | `ravu-lite-ar-r4` as an mpv user shader via `h96-upscale`; measured ~10-13% extra GPU time. Needs a desktop session |
| NPU (3-core, ~6 TOPS) | ✅ | Driver `v0.9.8`, IOMMU mode, per-core load via `h96-npu`. `h96-npu bench` runs an INT8 matmul (~625 GOPS one core; `bench all` ~1.29 TOPS across 3 cores). v5.0 adds `h96-npu power [performance\|balanced\|powersave\|sync\|status]`: the devfreq had been pinned at 1000 MHz for 100 percent of uptime while unused, `powersave` parks it at 300 MHz, `power sync` matches the CPU and GPU profile. Inference runtime is proprietary and fetched on demand with `h96-npu-setup`, never bundled |
| System monitor | ✅ | `scrumptop`: per-core CPU (A76/A55 topology) with per-cluster temperature gauges, GPU/NPU load, network rates, Bluetooth, IR activity, eMMC I/O, peripheral batteries. `b` = NPU bench, `+`/`-` = polling rate |
| Desktop lock screen | ✅ | v4.0 corrects `/etc/shadow` group ownership from base rootfs. Lock screens rejected correct passwords in every earlier release. Fix for earlier releases is in CHANGELOG |
| Android apps (Waydroid) | ✅ | v5.0 `h96-waydroid`. Needs the v5.0 `CONFIG_PSI=y` kernel. `init gapps\|vanilla` (default) runs the official LineageOS 20 (Android 13, MAINLINE vendor) on the Mali-G610 in hardware: `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`, 50 percent GPU at 1000 MHz under UI activity. `init gpu` is the legacy third-party Android 11 Panthor image (Mesa 24.0.5, unsigned, abandoned April 2024). Window is fixed size on purpose; v5.0.1 adds `size fullscreen` (borderless, fills the screen). v5.0.1 also adds a clean teardown (closing the window stops the container and releases the GPU, with a Stop Android menu entry) and `q` to quit from a terminal. Container **cannot** use the NPU |
| GPU emulators | ✅ | v5.0 `h96-emulators`: `retroarch`, `dolphin`, `ppsspp`, `flycast`, `melonds`, `rmg`, `azahar` as native ARM64 Flatpaks on PanVK/Panfrost, `cemu` as the x86-64 build under `box64`. `install` verifies each one is not falling back to `llvmpipe` |

> **Note on Ethernet.** Onboard RTL8211F PHY may spend an extended time attempting
> Gigabit auto-negotiation before downshifting to 100Mbps, so link can take minutes
> to become usable after boot while system itself reaches multi-user in about 7
> seconds. Kernel logs `Downshift occurred from negotiated speed 1Gbps to actual
> speed 100Mbps, check cabling!`. Measured at 26 s, 128 s and 190 s across boots on one
> unit. **On measured unit, cause was far end, not board:**
> link partner advertised only 10/100, so board was correctly asking for a
> speed nothing answered. Check what router or switch supports before
> suspecting box. Try a different cable or switch port first; `ethtool -s eth0 speed 100 duplex
> full autoneg off` skips Gigabit negotiation at cost of capping port.

---

## Thermals

Read from `/sys/class/thermal` on the shipped image. Trip points are the SoC BSP
defaults; nothing here changes them.

| Zone | Passive trips | Critical |
|---|---|---|
| `soc-thermal` | 80 C, 95 C | 115 C |
| `bigcore0-thermal` | 75 C | 115 C |
| `bigcore1-thermal` | 75 C | 115 C |
| `littlecore-thermal` | 75 C | 115 C |
| `center-thermal` | 75 C | 115 C |
| `gpu-thermal` | 75 C | 115 C |
| `npu-thermal` | 75 C | 115 C |

Cooling devices: `cpufreq-cpu0`, `cpufreq-cpu1`, `cpufreq-cpu3`, `devfreq-fb000000.gpu`.

Measured on one unit: idle about 52 to 61 C. A sustained all-core `performance` load
reached 85 C, above the `soc-thermal` passive trip, so the box throttles under sustained
load. That is expected for this SoC in this chassis and is not a fault.

---

## Repository layout

```
config/
  boards/h96-max-v58.tvb          Armbian board file (TV-box class)
  kernel-h96-max-v58.config       kernel .config fragment (Panthor, VPU, IR, PCIe)
patch/
  kernel/rk3588-h96-max-v58.dts   board device tree (core hardware source)
  overlays/h96-max-v58-gpio-ir.dts  IR receiver overlay (gpio-ir-receiver)
packages/
  bsp/h96-max-v58/
    src/h96-vfd.c                 front-panel VFD daemon source (+ Makefile)
    src/npuload.c                 NPU INT8 matmul benchmark source (h96-npu bench;
                                  image build ships it precompiled)
    src/ddc-edid-read.c           GPIO bit-bang EDID reader source (h96-display auto;
                                  image build ships it precompiled)
    systemd/h96-vfd.service       unit for daemon
    systemd/h96-display-wake.service  display-wake daemon unit (+ -once.service
                                  for hotplug; see CHANGELOG v4.0 2c)
    lib/h96-display-wake-daemon.py  input watcher: re-drives HDMI when stuck off
    environment.d-h96-gpu.conf    GLES/EGL env so desktop composites on GPU
    brcm4362a2_firmware/          BCM4362A2.hcd - vendor Bluetooth firmware blob
    wireplumber/30-h96-bluetooth.conf  Bluetooth audio: A2DP codec order + HFP
                                  headset-microphone roles (install to
                                  /etc/wireplumber/wireplumber.conf.d/)
    modules-load.d/rfcomm.conf    autoloads rfcomm (needs CONFIG_BT_RFCOMM=m in
                                  the kernel config) so the Hands-Free headset mic
                                  works; install to /etc/modules-load.d/
    systemd/bt-sco-hci.service    routes SCO audio over HCI (Broadcom VSC 0xFC1C)
                                  so the headset mic carries data; enable it
    tools/                        userspace tools installed to /usr/local/bin|sbin:
                                  h96-npu, h96-encode, h96-upscale, h96-npu-setup,
                                  h96-subtitles, h96-subtitles-setup, scrumptop,
                                  h96-display, h96-display-wake.sh, h96-brightness,
                                  h96-scale, h96-widevine-setup, h96-autologin-setup,
                                  h96-waydroid (v5.0, Android in a container),
                                  h96-emulators (v5.0, GPU emulator suite)
    lib/                          shared banner library + mpv overlay client
                                  (installed under /usr/local/lib/h96/)
    udev/99-h96-dma-heap.rules    DMA-heap group/mode rule (hardware video decode
                                  for non-root users; see CHANGELOG v4.0)
    udev/97-h96-display-wake.rules  HDMI re-drive check after hotplug
    shaders/ravu-lite-ar-r4.hook  mpv prescaler used by h96-upscale
                                  (bjin/mpv-prescalers, LGPL-3.0, header intact)
docs/
  DEVICE-TREE-CHANGES.md          every DT change vs stock vendor DTB, explained
CHANGELOG.md  CREDITS.md  LICENSE
```

---

## Building an image with Armbian framework

These sources plug into standard [Armbian build system](https://github.com/armbian/build).
Device tree carries hardware enablement; rest is board config + BSP.

> **Released images are NOT built by these steps.** Shipped `.img` files are a rootless
> delta on a known-good ophub RK3588 6.1.x BSP base image (Rock 5B lineage, adapted to the
> H96 NVR-DEMO DTB). Steps below build a bare Armbian board from the framework: a booting
> console with working peripherals, but WITHOUT the `h96-*` userspace layer (GPU staging,
> VPU/NPU setup, Bluetooth stack, media tools, display/EDID handling). No `compile.sh`
> invocation reproduces a release. Build from source to change the kernel or DTB; flash a
> release to run the box.

These sources plug into the standard [Armbian build system](https://github.com/armbian/build).
Device tree carries hardware enablement; rest is board config + BSP.

**Build `BRANCH=vendor`, not `edge`.** On the rockchip-rk3588 family `edge` resolves to
rolling mainline (7.2+), which ships NO RK3588 vendor drivers: board reaches a console with
no GPU, no hardware video, no HDMI on this BSP, dead onboard WiFi/BT (issue #5). `vendor`
builds the `rk-6.1-rkr5.1` BSP kernel (LINUXFAMILY `rk35xx`) that knows this SoC. Build on
Ubuntu Jammy or Noble (or the Armbian Docker path); newer hosts break the Radxa u-boot build.

```bash
# 1. Get Armbian build framework
git clone --depth=1 https://github.com/armbian/build armbian-build
cd armbian-build

# 2. Add this board. Its .tvb sets BOOT_SOC=rk3588 + BOOTCONFIG=rock-5b-rk3588_defconfig
#    (SPL-blobs u-boot, no OP-TEE) and BOOT_FDT_FILE. Do NOT set BOOTCONFIG=rk3588_defconfig,
#    the vendor EVB config that pulls OP-TEE and halts u-boot (issue #5).
cp  /path/to/this-repo/config/boards/h96-max-v58.tvb   config/boards/

# 3. Add device tree via a userpatch that drops the .dts in
mkdir -p userpatches
cp  /path/to/this-repo/patch/kernel/rk3588-h96-max-v58.dts   userpatches/

# 4. (optional) merge kernel config fragment for Panthor/VPU/IR/PCIe
cat /path/to/this-repo/config/kernel-h96-max-v58.config >> userpatches/linux-rockchip64-vendor.config

# 5. Build (6.1 BSP kernel, desktop image)
./compile.sh  BOARD=h96-max-v58  BRANCH=vendor  RELEASE=noble \
              BUILD_DESKTOP=yes  BUILD_MINIMAL=no  KERNEL_CONFIGURE=no
```

Output image lands in `output/images/`. It boots a bare 6.1 board; the `h96-*` tooling is
the separate userspace delta the releases carry, not part of this build. Flash it (see
**Flashing** below). If HDMI stays dark on first boot, force a mode: add
`video=HDMI-A-1:1280x720@60e` to the `extraargs=` line in `/boot/armbianEnv.txt` (trailing
`e` forces the mode past this BSP's EDID-read bug).

> **Note on device tree.** `patch/kernel/rk3588-h96-max-v58.dts` is a decompile of the stock
> Android vendor DTB, edited for an open-GPU Armbian (hence
> `rockchip,rk3588-nvr-demo-v10-android` compatible and numeric phandles). It is included
> exactly as used, and is the DTB source the released images ship. `docs/DEVICE-TREE-CHANGES.md`
> documents every change so it can be re-applied onto a mainline `rk3588.dtsi` for a
> from-scratch DTS.

---

## Device-tree changes

Full detail in [`docs/DEVICE-TREE-CHANGES.md`](docs/DEVICE-TREE-CHANGES.md). In short:

- **Open GPU:** `gpu-supply` + `&cru CLK_GPU` + a 1000 MHz OPP; Panthor binding.
- **HW cursor plane:** `cursor-win-id = <0>` on `vp0`.
- **WiFi 6 on PCIe:** enable `pcie2x1l0`, disable vestigial `&sdio` template.
- **Reduced boot output:** disable unused `es8311`/`i2s0`, drop serial `dmas`
  that emitted repeated errors.

Build DTBs standalone if you want only those:

```bash
dtc -@ -I dts -O dtb -o rk3588-h96-max-v58.dtb   patch/kernel/rk3588-h96-max-v58.dts
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo patch/overlays/h96-max-v58-gpio-ir.dts
```

---

## Front-panel VFD (`h96-vfd`)

Front panel is a **TM1650** bit-banged over GPIO3. Daemon shows clock
and lights Ethernet / WiFi / USB / play icons from live state.

```bash
cd packages/bsp/h96-max-v58/src
make                              # native (on board), or:  make CROSS=aarch64-linux-gnu-
sudo install -m0755 h96-vfd /usr/local/sbin/h96-vfd
sudo install -m0644 ../systemd/h96-vfd.service /etc/systemd/system/
sudo systemctl enable --now h96-vfd
```

## IR remote

```bash
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo patch/overlays/h96-max-v58-gpio-ir.dts
sudo cp h96-max-v58-gpio-ir.dtbo /boot/overlay-user/
# add to /boot/armbianEnv.txt:   user_overlays=h96-max-v58-gpio-ir
sudo reboot
# then learn your remote:
ir-keytable            # shows gpio_ir_recv device
ir-keytable -p nec -t  # press buttons -> scancodes
```

## Open-GPU desktop

For KDE/GNOME to composite on GPU (not fall back to software `llvmpipe`),
append `packages/bsp/h96-max-v58/environment.d-h96-gpu.conf` to `/etc/environment`.
Do **not** install `libmali` blob packages: they shadow Mesa's EGL/Vulkan.

---

## Flashing

RK3588 flashes over USB with **`rkdeveloptool`** in Maskrom mode (hold the
recessed reset pinhole, rear panel, in the gap between the two WiFi antenna
posts, while connecting USB), or with Rockchip's RKDevTool GUI on
Windows. Write Armbian image (`.img`) to eMMC. This is standard RK3588
procedure and is not specific to this repo.

---

## License & credits

GPL-2.0-only. See [`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md). Built on
Armbian, Linux kernel, Rockchip's BSP, Panthor, and Mesa.
