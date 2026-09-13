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

## Release images (v6.0)

The current release is **v6.0**, shipped as one pre-built full image. It boots to a
text console and does not pre-install a desktop. v6.0 absorbs the planned v5.2: the kernel
changes across several rebuilds, cluster-aware scheduling together with the VOP2 cursor driver
fixes, are substantial enough to warrant a major version rather than a point release. Both are
correctness changes, not performance changes.

| Image | Boots to | GPU | Desktop | Zip size |
|---|---|---|---|---|
| **v6.0** (full) | console | Mali-G610 (Panthor) + Mesa | installed on demand via `armbian-config` | 1.22 GB |

- **New in v6.0, hardware cursor during GPU compositing fixed in the kernel driver.** The VOP2
  cursor driver fix keeps the hardware cursor visible during continuous GPU compositing
  (fullscreen video, animated browser pages, the desktop splash); it still auto-hides over
  video and returns on movement, and stays correct after leaving mpv for the desktop.
  `/etc/mpv/mpv.conf` uses `cursor-autohide=1000` and `x11-bypass-compositor=never`. The kernel
  Image changes, so moving to v6.0 is a reflash.
- **New in v6.0, `h96-backup` and `h96-restore`.** `h96-backup` captures a configured box into
  one archive (a manifest of installed on-demand features plus the passive data that cannot be
  re-downloaded, such as saves, configs and WiFi credentials); `h96-restore` replays it after a
  reflash, reinstalling the recorded features and restoring the data. `--open` prints the
  installer commands instead of running them; `--dry-run` prints the plan and changes nothing;
  `--force` overwrites configs that are newer on disk (stop the desktop session first on a
  fresh image, whose session has already written default configs). Both tools take `--only`
  and `--skip` category lists and `--emulators`; `h96-backup-gui` presents the same choices
  as checkboxes. Boxes on v5.0.1 or earlier have no backup tool; the migration kit (`h96-migrate-kit.zip` in the release) installs the same three tools there (`sudo bash install.sh`, `--gui` for the window) so the box can be captured to a USB stick before the flash.
- **v6.0, clearer `h96-undervolt` trial flow.** `set <mV>`, then reboot, and the setting is
  active on that boot so you can test it under load; `confirm` keeps it, and a reboot without
  confirming reverts to stock on its own.
- **v6.0 kernel: `CONFIG_SCHED_CLUSTER`.** The kernel represents the RK3588 as its three CPU
  clusters (4x Cortex-A55 on cpu0 and cpu5 to cpu7, 2x Cortex-A76 on cpu1 and cpu2, 2x
  Cortex-A76 on cpu3 and cpu4; the A76 pairs are separate DVFS clusters) rather than one flat
  group, so the scheduler's topology view matches the hardware. This is a topology-correctness
  change: benchmarking found no measurable change in throughput, and none is claimed. The kernel
  carries BPF Type Format (BTF) data (`CONFIG_DEBUG_INFO_BTF`, with
  `CONFIG_DEBUG_INFO_BTF_MODULES` for the module set): `/sys/kernel/btf/vmlinux` describes the
  kernel's types (7 MB) and every module exports its own, so `bpftool`, `bcc` and CO-RE BPF
  programs read kernel and module types on the box without kernel headers. `bpftrace` kprobes
  walk kernel structs the same way; pass `--traceable-functions` with a symbol list from
  `/proc/kallsyms`, since this kernel has no ftrace function list. BTF is data that BPF tools
  read; the machine code is the same with or without it, and the kernel Image grows by 7 MB.
  Armbian's own rk35xx kernel configuration ships with BTF on. The VOP2 cursor fix is published
  as `patch/kernel/h96-vop2-cursor.patch`; see [Building an
  image](#building-an-image-with-armbian-framework).
- **v6.0 kernel: release `6.1.115-h96`, modules rebuilt with symbol versioning.** The
  release string is `6.1.115-h96` (`CONFIG_LOCALVERSION="-h96"`) and modules live in
  `/lib/modules/6.1.115-h96`. The full module set (3110 modules) is built from the same
  source and configuration as the kernel Image, with `CONFIG_MODVERSIONS=y`: every module
  carries symbol versions, and the loader rejects a module built against a different kernel
  layout instead of loading it unchecked. Earlier releases shipped a module set built against
  a pre-PSI configuration; those modules loaded on 6.1.115 kernels because the vermagic
  string matched, and only the modules in use had been checked by inspection. The bcmdhd
  WiFi module and every other module now carry matching symbol versions, and the kernel's
  `O` (out-of-tree) taint flag is gone. The `h96-rfcomm` service no longer hardcodes a
  kernel release; it reads `uname -r`.
- **v6.0 kernel: `CONFIG_RT_GROUP_SCHED` off.** It was on, inherited from the vendor Android
  configuration. Realtime scheduling is now available to processes outside the root cgroup:
  PipeWire's data-loop threads run at `SCHED_RR` priority 20 through rtkit, so audio threads
  keep their priority under CPU load, and `cyclictest` runs. Previously the journal logged
  `Failed to make ourselves RT: Operation not permitted` on every boot and the audio threads
  ran as normal tasks.
- **v6.0 kernel: `xpad` with player-LED and force-feedback support.** The `xpad` USB
  game-controller module is built with `CONFIG_JOYSTICK_XPAD_LEDS=y` and
  `CONFIG_JOYSTICK_XPAD_FF=y`. 2.4 GHz X-input dongles that wait for the Xbox 360 player-LED
  command before they start reporting now work (verified with the 8BitDo Ultimate 2C Wireless
  Controller and its dongle; previously the dongle enumerated and bound but sent no input,
  while the same pad worked over Bluetooth), and rumble is available on xpad-driven
  controllers. The kernel Image is unchanged by this; only the module set changed.

- **Kernel rebuilt with `CONFIG_PSI=y`** (`PSI_DEFAULT_DISABLED` off), from
  armbian/linux-rockchip, branch `rk-6.1-rkr5.1`, commit `95e85f6c`. Android 11 and later
  `init`/`lmkd` hard-require `/proc/pressure`; without it the Waydroid container boots and
  then dies in about 15 seconds. The v5.0 build was Image-only, with the kernel release
  string unchanged at 6.1.115 and the vendor modules kept; as of v6.0 the release string is
  `6.1.115-h96` and the modules are rebuilt with the Image (see above).
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

> **Note on kernel log.** At boot the kernel prints two `WARNING` traces from
> `pinctrl-rockchip.c` (`rockchip_pmx_gpio_set_direction`, `pin 143 already requested by
> fde80000.hdmi` and `pin 144 already requested by fde80000.hdmi`). The `h96-ddc-i2c-gpio`
> overlay reassigns the HDMI DDC pins to an i2c-gpio bus for DDC/CI brightness control, and
> the pinctrl driver logs the reassignment. They are harmless; the kernel sets its `W` taint
> flag and the bus works.

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
  boards/h96-max-v58.tvb          Armbian board file (TV-box class): BOOT_FDT_FILE, u-boot
                                  config, kernel source pin, kernel config hook
  linux-rk35xx-vendor.config      FULL kernel .config the v6.0 kernel (6.1.115-h96) was
                                  built with; the file the framework consumes
  kernel-h96-max-v58.config       diff summary of that config against the vendor default
                                  (Panthor, PSI, SCHED_CLUSTER, LOCALVERSION -h96,
                                  MODVERSIONS, RT_GROUP_SCHED off, VPU, PCIe, RFCOMM,
                                  xpad with player LEDs and force feedback)
patch/
  kernel/rk3588-h96-max-v58-panthor.dts  board device tree, decompiled from the DTB
                                  the image boots (core hardware source)
  kernel/h96-vop2-cursor.patch    v6.0 VOP2 hardware-cursor fix
  kernel/h96-board-support.patch  board support carried by every release: BCM43752
                                  WiFi (bcmdhd, brcmfmac ids), SDIO rescan hook,
                                  HDMI PHY clock name, xpad 8BitDo
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
    modules-load.d/xpad.conf      autoloads xpad (CONFIG_JOYSTICK_XPAD=m, with
                                  JOYSTICK_XPAD_LEDS and JOYSTICK_XPAD_FF since v6.0)
    systemd/h96-rfcomm.service    depmod for the running kernel (uname -r), then
                                  loads rfcomm and xpad before BlueZ; enable it
    systemd/bt-sco-hci.service    routes SCO audio over HCI (Broadcom VSC 0xFC1C)
                                  so the headset mic carries data; enable it
    systemd/h96-undervolt-trial.service  boot-time guard for the h96-undervolt trial
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

These sources plug into the standard [Armbian build system](https://github.com/armbian/build).
The device tree carries the hardware enablement; the rest is board config + BSP.

> **Released images are NOT built by these steps.** Shipped `.img` files are a rootless
> delta on a known-good ophub RK3588 6.1.x BSP base image (Rock 5B lineage, adapted to the
> H96 NVR-DEMO DTB), and the v6.0 kernel was built outside the framework from the source,
> config and patches published here. The steps below build a bare Armbian board from the
> framework: a booting console with working peripherals, but WITHOUT the `h96-*` userspace
> layer (GPU staging, VPU/NPU setup, Bluetooth stack, media tools, display/EDID handling).
> No `compile.sh` invocation reproduces a release image. Build from source to change the
> kernel or DTB; flash a release to run the box. These steps were written against the
> framework source at the time of writing and have not been run end to end by us.

**What the v6.0 kernel is.** Source `armbian/linux-rockchip`, branch `rk-6.1-rkr5.1`, commit
`95e85f6cb496c75807c5b16f158853578e7e7d1b`, plus `patch/kernel/h96-board-support.patch` and
`patch/kernel/h96-vop2-cursor.patch` (plain `-p1` diffs against that commit; apply order does
not matter, they touch disjoint files), built with `config/linux-rk35xx-vendor.config`.
`config/kernel-h96-max-v58.config` is the human-readable summary of that config, not a build
input. The release string is `6.1.115-h96`.

**Build `BRANCH=vendor`, not `edge`.** On the rockchip-rk3588 family `edge` resolves to
rolling mainline (7.2+), which ships NO RK3588 vendor drivers: the board reaches a console
with no GPU, no hardware video, no HDMI on this BSP, dead onboard WiFi/BT (issue #5).
`vendor` selects the rk-6.1 BSP kernel (LINUXFAMILY `rk35xx`) that knows this SoC. The
family file tracks a newer rk-6.1 branch (`rk-6.1-rkr7.2` at the time of writing); the board
file's `post_family_config` hook pins `KERNELBRANCH` to the commit above so the patches and
config match. Build on Ubuntu Jammy or Noble (or the Armbian Docker path); newer hosts break
the Radxa u-boot build.

**Names the framework derives.** For `BRANCH=vendor` on this family the kernel config is
`linux-rk35xx-vendor.config` (`LINUXCONFIG`) and the kernel patch directory is
`KERNELPATCHDIR`, `rk35xx-vendor-6.1` at the time of writing (earlier framework versions used
`rk35xx-vendor`). Read both from `config/sources/families/rockchip-rk3588.conf` in the
framework checkout before step 3 and use the value it gives.

```bash
# 1. Get the Armbian build framework
git clone --depth=1 https://github.com/armbian/build armbian-build
cd armbian-build
grep -n 'KERNELPATCHDIR\|LINUXFAMILY' config/sources/families/rockchip-rk3588.conf
KPD=rk35xx-vendor-6.1          # set to the KERNELPATCHDIR value printed for the vendor branch

# 2. Add this board. Its .tvb sets BOOT_SOC=rk3588 + BOOTCONFIG=rock-5b-rk3588_defconfig
#    (SPL-blobs u-boot, no OP-TEE), BOOT_FDT_FILE=rockchip/rk3588-h96-max-v58-panthor.dtb,
#    the kernel source pin, and a custom_kernel_config hook (see below). Do NOT set
#    BOOTCONFIG=rk3588_defconfig, the vendor EVB config that pulls OP-TEE and halts u-boot
#    (issue #5).
cp  /path/to/this-repo/config/boards/h96-max-v58.tvb   config/boards/

# 3. Kernel patches. Armbian applies userpatches/kernel/<KERNELPATCHDIR>/*.patch with
#    patch -p1 after its own patch/kernel/<KERNELPATCHDIR>/*.patch.
mkdir -p userpatches/kernel/$KPD/dt
cp  /path/to/this-repo/patch/kernel/h96-board-support.patch userpatches/kernel/$KPD/
cp  /path/to/this-repo/patch/kernel/h96-vop2-cursor.patch   userpatches/kernel/$KPD/

# 4. Device tree. A .dts in the dt/ subdirectory of the kernel patch directory is copied
#    to arch/arm64/boot/dts/rockchip/ and added to that Makefile by the framework
#    (dts-directories and auto-patch-dt-makefile in
#    patch/kernel/<KERNELPATCHDIR>/0000.patching_config.yaml); no Makefile patch is needed.
#    The file name sets the DTB name, which must equal BOOT_FDT_FILE in the board file.
cp  /path/to/this-repo/patch/kernel/rk3588-h96-max-v58-panthor.dts  userpatches/kernel/$KPD/dt/

# 5. Full kernel config. With KERNEL_CONFIGURE=no the framework copies this file to .config
#    and runs olddefconfig; it is the exact .config the v6.0 kernel was built with.
mkdir -p userpatches/config/kernel
cp  /path/to/this-repo/config/linux-rk35xx-vendor.config  userpatches/config/kernel/

# 6. Build (6.1 BSP kernel, desktop image)
./compile.sh  BOARD=h96-max-v58  BRANCH=vendor  RELEASE=resolute \
              BUILD_DESKTOP=yes  BUILD_MINIMAL=no  KERNEL_CONFIGURE=no
```

The output image lands in `output/images/`. It boots a bare 6.1 board; the `h96-*` tooling is
the separate userspace delta the releases carry, not part of this build.

**What the framework changes on top of the config.** The framework's own
`armbian_kernel_config__*` hooks (`lib/functions/compilation/armbian-kernel.sh`) rewrite
parts of any user-supplied `.config` before the build: they set `CONFIG_LOCALVERSION` to an
empty string, force `CONFIG_RT_GROUP_SCHED=y` for Docker, and turn BTF debug information on (`CONFIG_DEBUG_INFO`, `CONFIG_DEBUG_INFO_BTF`), which the shipped configuration also carries, along with
zram, nftables, filesystem and container options that the vendor config already carries. The
board file's `custom_kernel_config` hook runs after them and restores the v6.0 values
(`CONFIG_LOCALVERSION="-h96"`, `CONFIG_RT_GROUP_SCHED=n`, `CONFIG_MODVERSIONS=y`,
`CONFIG_PSI=y`, `CONFIG_SCHED_CLUSTER=y`, `CONFIG_NVMEM_ROCKCHIP_SEC_OTP=n`, `CONFIG_DRM_PANTHOR=m`, `CONFIG_DEBUG_INFO_BTF=y`, `CONFIG_DEBUG_INFO_BTF_MODULES=y`, `CONFIG_JOYSTICK_XPAD_LEDS=y`, `CONFIG_JOYSTICK_XPAD_FF=y`); do not pass `KERNEL_BTF=no`, which would turn BTF off. The framework also
adds `LOCALVERSION=-vendor-rk35xx` on the make command line, so a framework-built kernel
reports `6.1.115-h96-vendor-rk35xx` and installs its modules under that name; the released
image reports `6.1.115-h96`. That is a naming difference, not a configuration difference. The
framework's own patches in `patch/kernel/<KERNELPATCHDIR>/` (two small files at the time of
writing: an HID Sony patch and a Bluetooth HCI quirk) are applied as well and are not in the
released kernel; delete them from the checkout before step 6 for a closer match.

**Modules travel with the Image.** The config sets `CONFIG_LOCALVERSION="-h96"` and
`CONFIG_MODVERSIONS=y`, so the built kernel's modules carry symbol versions. Install the
modules with the kernel they were built with (`make modules_install` from the same tree into
`/lib/modules/$(make kernelrelease)`); the loader rejects a module built against a different
kernel layout, so a module set from another build does not load on it. The Armbian framework
build above packages kernel and modules together on its own; a manual kernel build must do it
explicitly.

**Kernel patches.** `patch/kernel/h96-vop2-cursor.patch` is the v6.0 change to
`drivers/gpu/drm/rockchip/rockchip_drm_vop2.c`: it re-asserts the hardware cursor window on
each video-port latch so the cursor stays visible under continuous GPU compositing.
`patch/kernel/h96-board-support.patch` carries the board support every release has had:
BCM43752 ids for `brcmfmac`, two `bcmdhd` log-prefix lines, an SDIO rescan hook in `dw_mmc`
and `rfkill-wlan`, the HDMI PHY clock name, and the 8BitDo entries in `xpad`. Both are
verified against the pinned commit with `patch -p1 --dry-run`. If HDMI stays dark on first
boot, force a mode: add `video=HDMI-A-1:1280x720@60e` to the `extraargs=` line in
`/boot/armbianEnv.txt` (the trailing `e` forces the mode past this BSP's EDID-read bug).

> **Note on device tree.** `patch/kernel/rk3588-h96-max-v58-panthor.dts` is a decompile of
> the stock Android vendor DTB, edited for an open-GPU Armbian (hence the
> `rockchip,rk3588-nvr-demo-v10-android` compatible and numeric phandles). The file is a
> decompile of `rk3588-h96-max-v58-panthor.dtb`, the DTB the v6.0 image boots (`fdtfile=` in
> `/boot/armbianEnv.txt`), and recompiles to the same tree. `docs/DEVICE-TREE-CHANGES.md`
> documents every change so it can be re-applied onto a mainline `rk3588.dtsi` for a
> from-scratch DTS. The BSP tools that edit the device tree (`h96-undervolt`,
> `h96-undervolt-trial.service`) use the `-panthor` path, so keep that DTB name.

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
dtc -@ -I dts -O dtb -o rk3588-h96-max-v58-panthor.dtb patch/kernel/rk3588-h96-max-v58-panthor.dts
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo       patch/overlays/h96-max-v58-gpio-ir.dts
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
