# H96 Max V58 · Armbian board support (RK3588)

**Hardware bring-up sources** · kernel · device tree · Panthor GPU · front-panel VFD · onboard WiFi 6

---

Board bring-up **sources** for running Armbian on **H96 Max V58** TV box
(Rockchip **RK3588**, Mali-G610) with **open GPU** stack: Panthor kernel
driver + Mesa (Panfrost/PanVK), hardware video, onboard WiFi 6, and working
front-panel display.

This repository exists so anyone can **inspect source and build matching
image themselves** with official Armbian build framework, rather than
downloading pre-built image. Everything here (device tree, overlays,
front-panel driver, board config, BSP scripts) is provided as source under
GPL-2.0. See [`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md).

> **Unofficial.** Not affiliated with, endorsed by, or supported by Armbian,
> Rockchip, or H96 manufacturer. It has been tested only on our own unit and
> comes with **no warranty**. Always keep recovery plan before overwriting your device.

> **Scope: this repo covers hardware bring-up (kernel, device tree, front-panel
> daemon) up through v3.1.** It does not include desktop-completeness and
> reliability fixes from v3.2 and later (except HDMI EDID work, v4.1
> Bluetooth audio + headset-mic sources, and v4.1 `xpad` kernel driver +
> media-tool sources, which are documented in CHANGELOG.md /
> docs/BLUETOOTH-AUDIO.md / docs/MEDIA-FEATURES.md and do apply here): WiFi connection tooling,
> Discover/software-install authentication, gaming stack, and related first-boot
> automation. Compiling from these sources reproduces open GPU, onboard WiFi 6,
> hardware video, front-panel display, and (v4.1) Bluetooth headset mic + AAC. For
> full current feature set, use pre-built release images until rest of that
> userspace layer is published here as well.

---

## Release images (v6.2)

Current release is **v6.2**, shipped as one pre-built full image. It boots to
text console and does not pre-install desktop. v6.2 updates native Steam route over
v6.1 and reworks audio: flat EQ file restores device setup on PipeWire 1.6, and Bluetooth
headset microphone, codecs and reconnect behaviour change.

v6.2 kernel moves to release string `6.1.115-h96v58v2` and adds:

- VOP2 window power-domain tracking, extended from v6.1: cursor no longer vanishes
  after mode change and cursor hide in one frame.
- HDMI-CEC on HDMI0 (`/dev/cec0`): TV remote controls box; box puts TV in standby and
  wakes it. Verified on Sony TV.
- HDMI0 DDC on GPIO I2C bus, since on-chip DDC controller never completes transfers:
  native EDID reads and HDMI 2.0 SCDC scrambling. Verified: 2560x1440 at 120 and
  144 Hz, 3840x2160 at 60 Hz.
- Plane colour conversion re-applied on colour-format switch without modeset: no green
  cast when switching between RGB and YCbCr.
- HDMI audio channel allocation derived with ELD bypass: groundwork for multichannel.
  Multichannel is not verified; no AV receiver tested.
- EDID override NULL-dereference guard; audio infoframe error check.
- RGA 2D accelerator binds after deferred probes (`/dev/rga` works).
- stmmac Wake-on-LAN IRQ balance: no kernel warning when toggling WoL.
- SARADC volume key: pinhole recovery button driver.
- Neutral kernel build banner.
- HDMI output stays muted 1 s when colour format changes between RGB and YCbCr: no green flash at boot handover from loader. `dw_hdmi_qp.fmt_switch_mute_ms` sets hold (0 = off).

Box on v6.1 gets userland changes above without reflash through
`h96-v6.1.1-HOTfix.zip`; kernel changes above ship only with v6.2 image, so full
benefit needs reflash. Over v6.0, kernel release string changes from
`6.1.115-h96` to `6.1.115-h96v58v1`, so moving to it is reflash rather than
`apt upgrade`. This build adds three kernel checks (`CONFIG_LOCKUP_DETECTOR`,
`CONFIG_SOFTLOCKUP_DETECTOR`, `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC`) that panic kernel on
stuck CPU, paired with watchdog reset. One device tree node changes, watchdog is
enabled, and every v6.0 feature and command is retained.

| Image             | Boots to | GPU                        | Desktop                                  | Zip size   |
|-------------------|----------|----------------------------|------------------------------------------|------------|
| **v6.2** (full) | console  | Mali-G610 (Panthor) + Mesa | installed on demand via `armbian-config` | 1.23 GB    |
| **v6.1** (full)   | console  | Mali-G610 (Panthor) + Mesa | installed on demand via `armbian-config` | 1.23 GB    |
| **v6.0** (full)   | console  | Mali-G610 (Panthor) + Mesa | installed on demand via `armbian-config` | 1.23 GB    |

- **New in v6.2, Steam ARM 1.2 on native route.** Launch handler sets Steam overlay, MangoHud, Godot 4 and Unity renderer per title, with no launch options, and reads title profiles from `/etc/h96/titles.conf`. Graphics forwarding is applied as soon as client downloads its emulation tool, so titles no longer start on CPU renderer after fresh install. New components `desktop-mode`, `icon-bigpicture`, `icon-desktop` and `tray`. Install, re-run and component changes keep installed games. 32-bit titles lose `-vulkan`, start scripts are followed to binary they start, `gl32=off` profile key runs title on emulated x86 Mesa, and Steam overlay buffers left after game sessions are freed. Full list in [CHANGELOG.md](CHANGELOG.md).
- **New in v6.2, display.** `h96-display detect` builds mode list from connected display, up to 8K; modes wider than 4096 px and FRL tier are listed but untested. HDMI 2.0 tier (340 to 600 MHz, SCDC) is on by default. Modes are picked in KDE System Settings → Display and persist per display. Colour format and range are set per display on command line (`sudo h96-display color rgb|ycbcr|auto`, `range full|limited|auto`), each applied live with 15 s confirm-or-revert. One HDMI output (HDMI0).
- **New in v6.2, tools.** `h96-leds` steady by default, blinking opt-in. Installed and off by default: `h96-wol`, `h96-cec`, `h96-vm`, `h96-hotspot`. `h96-backup` / `h96-restore` v2.1 restore backups from v5.0.1 and newer. mpv decodes through `rkmpp-copy` and prefers 8-bit VP9 on YouTube; AV1 is excluded.
- **New in v6.2, audio.** Image ships flat EQ file `/etc/h96/eq/active.txt`; PipeWire 1.6 stops h96 EQ filter chain without it and WirePlumber then stalls. Bluetooth headset microphone is listed at all times (autoswitch), runs mSBC where headset supports it, Bluetooth sinks run 2048-sample cycle and never suspend, BlueZ reconnect policy is set, and `h96-bt-a2dp-heal.service` restores dropped A2DP link. See [docs/BLUETOOTH-AUDIO.md](docs/BLUETOOTH-AUDIO.md).
- **New in v6.1, Steam installed on demand.** `h96-steam` installs either of two clients and
  downloads nothing until it runs. Native route installs ARM64 client, which runs on
  Mali GPU as ARM program; titles built for x86 run through emulation tool
  client downloads, and Windows titles through client's ARM64 Proton build. Emulated
  route installs x86-64 client under FEX-Emu on KDE desktop. Both install into
  desktop user's account and keep separate libraries; run one at time. Titles protected by
  anti-cheat do not run on either route. Installers are also published on their own as
  `h96-steam-installers.zip` for boxes on earlier image. `steam-arm --desktop` starts
  client in its desktop interface; `h96-steam-tray` places Steam icon in panel's system
  tray (open, open in desktop mode, stop, quit), installed with `tray` component and
  started at login. `h96-steam-remoteplay` pins hardware decoding off and HEVC off in
  client's Remote Play settings, because streaming client has no hardware decode path on
  this box and session otherwise sits on launch screen; launcher runs it before
  each start, and `--check` reports without changing anything. Keep game window in
  foreground on host: game in background renders nothing new, so stream shows
  one frame and takes no input.
- **ARM64 client.** ARM64 client is build of Steam that Valve made for its ARM based
  VR headset, Steam Frame: native ARM program that runs title's x86 code through
  emulation tool client downloads. On this box that means client interface, overlay,
  input stack and download and shader systems run on CPU and GPU directly, only
  title itself is emulated, and title's OpenGL and Vulkan calls reach Mali driver
  through forwarding libraries. Windows titles go through Valve's ARM64 Proton build, whose
  Direct3D layer reaches Mali Vulkan driver same way. Valve maintains this build for
  hardware of same architecture, so emulation tool updates, ARM64 Proton builds and
  per-title fixes arrive with client updates. VR itself is not part of this box: there is no VR
  runtime or headset support, and launcher removes client's VR argument from
  streaming client. Emulated route runs x86-64 client under FEX-Emu, with every part of
  client emulated and its interface software rendered.
- **New in v6.1, cursor window's power domain.** v6.0 fixed cursor latch in VOP2
  driver. v6.1 fixes second path in same driver, where power domain feeding
  cursor window could be switched off while window still held reference to it, leaving
  pointer moving and clicking with nothing drawn until next reboot. Driver now
  records reference per window, powers domain on whenever window needs it, and refuses
  release with no matching reference, reporting it once in kernel log.
- **New in v6.1, two input fixes.** Udev rule unbinds `xpad` from headset interface that
  some third-party Xbox 360 style pads expose, which had made one pad appear as two identical
  joysticks. Second rules file hands pad's `/dev/hidraw` node and `/dev/uinput` to
  logged-in user, covering every pad kernel's `xpad` driver recognises, matched on vendor
  and product so maker's keyboards and mice are not included; without it game client
  cannot read pad directly.
- **New in v6.1, hang recovery.** Watchdog and set of kernel checks reset box when
  kernel or PID 1 stops responding. Device tree enables RK3588 watchdog, and systemd
  opens it with 30 second timeout, which driver rounds up to 44 second hardware period,
  and pets it at half that period.
  CPU that makes no scheduling progress for 20 seconds, task blocked for 120 seconds, or oops panics
  kernel, which then reboots after holding panic on console for 10 seconds.
  Panic record survives reset in `/var/lib/systemd/pstore/`: `dmesg-ramoops-*` files hold
  panic kernel log, and `console-ramoops-0` holds previous boot's console and is replaced at
  every boot, so copy it before next reboot.
- **v6.1 kernel: release `6.1.115-h96v58v1`.** Suffix names board and kernel revision
  number that moves independently of image version, so kernel is identifiable from
  `uname -r` alone. Module set is rebuilt against it with `CONFIG_MODVERSIONS=y`, so
  module built for v6.0 release is refused rather than loaded. This build adds
  `CONFIG_LOCKUP_DETECTOR=y`, `CONFIG_SOFTLOCKUP_DETECTOR=y` and
  `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y`: CPU that makes no scheduling progress for 20 seconds is reported
  and kernel panics.

- **New in v6.0, hardware cursor during GPU compositing fixed in kernel driver.** VOP2
  cursor driver fix keeps hardware cursor visible during continuous GPU compositing
  (fullscreen video, animated browser pages, desktop splash); it still auto-hides over
  video and returns on movement, and stays correct after leaving mpv for desktop.
  `/etc/mpv/mpv.conf` uses `cursor-autohide=1000` and `x11-bypass-compositor=never`. Kernel
  Image changes, so moving to v6.0 is reflash.
- **New in v6.0, `h96-backup` and `h96-restore`.** `h96-backup` captures configured box into
  one archive (manifest of installed on-demand features plus passive data that cannot be
  re-downloaded, such as saves, configs and WiFi credentials); `h96-restore` replays it after
  reflash, reinstalling recorded features and restoring data. `--open` prints
  installer commands instead of running them; `--dry-run` prints plan and changes nothing;
  `--force` overwrites configs that are newer on disk (stop desktop session first on
  fresh image, whose session has already written default configs). Both tools take `--only`
  and `--skip` category lists and `--emulators`; `h96-backup-gui` presents same choices
  as checkboxes. Steam is not covered: neither tool has Steam category, so Steam clients,
  sign-in, settings and installed games are not in archive. Boxes on v5.0.1 or earlier have no backup tool; migration kit (`h96-migrate-kit.zip` in release) installs same three tools there (`sudo bash install.sh`, `--gui` for window) so box can be captured to USB stick before flash.
- **v6.0, clearer `h96-undervolt` trial flow.** `set <mV>`, then reboot, and setting is
  active on that boot so you can test it under load; `confirm` keeps it, and reboot without
  confirming reverts to stock on its own.
- **v6.0 kernel: `CONFIG_SCHED_CLUSTER`.** Kernel represents RK3588 as its three CPU
  clusters (4x Cortex-A55 on cpu0 and cpu5 to cpu7, 2x Cortex-A76 on cpu1 and cpu2, 2x
  Cortex-A76 on cpu3 and cpu4; A76 pairs are separate DVFS clusters) rather than one flat
  group, so scheduler's topology view matches hardware. This is topology-correctness
  change: benchmarking found no measurable change in throughput, and none is claimed. Kernel
  carries BPF Type Format (BTF) data (`CONFIG_DEBUG_INFO_BTF`, with
  `CONFIG_DEBUG_INFO_BTF_MODULES` for module set): `/sys/kernel/btf/vmlinux` describes
  kernel's types (7 MB) and every module exports its own, so `bpftool`, `bcc` and CO-RE BPF
  programs read kernel and module types on box without kernel headers. `bpftrace` kprobes
  walk kernel structs same way; pass `--traceable-functions` with symbol list from
  `/proc/kallsyms`, since this kernel has no ftrace function list. BTF is data that BPF tools
  read; machine code is same with or without it, and kernel Image grows by 7 MB.
  Armbian's own rk35xx kernel configuration ships with BTF on. VOP2 cursor fixes are
  published as `patch/kernel/h96-vop2-cursor.patch` (v6.0) and
  `patch/kernel/h96-vop2-cursor-pd.patch` (v6.1); see [Building
  image](#building-image-with-armbian-framework).
- **v6.0 kernel: release `6.1.115-h96`, modules rebuilt with symbol versioning.**
  Release string is `6.1.115-h96` (`CONFIG_LOCALVERSION="-h96"`) and modules live in
  `/lib/modules/6.1.115-h96`. Full module set (3110 modules) is built from same
  source and configuration as kernel Image, with `CONFIG_MODVERSIONS=y`: every module
  carries symbol versions, and loader rejects module built against different kernel
  layout instead of loading it unchecked. Earlier releases shipped module set built against
  pre-PSI configuration; those modules loaded on 6.1.115 kernels because vermagic
  string matched, and only modules in use had been checked by inspection. Bcmdhd
  WiFi module and every other module now carry matching symbol versions, and kernel's
  `O` (out-of-tree) taint flag is gone. `H96-rfcomm` service no longer hardcodes
  kernel release; it reads `uname -r`.
- **v6.0 kernel: `CONFIG_RT_GROUP_SCHED` off.** It was on, inherited from vendor Android
  configuration. Realtime scheduling is now available to processes outside root cgroup:
  PipeWire's data-loop threads run at `SCHED_RR` priority 20 through rtkit, so audio threads
  keep their priority under CPU load, and `cyclictest` runs. Previously journal logged
  `Failed to make ourselves RT: Operation not permitted` on every boot and audio threads
  ran as normal tasks.
- **v6.0 kernel: `xpad` with player-LED and force-feedback support.** `Xpad` USB
  game-controller module is built with `CONFIG_JOYSTICK_XPAD_LEDS=y` and
  `CONFIG_JOYSTICK_XPAD_FF=y`. 2.4 GHz X-input dongles that wait for Xbox 360 player-LED
  command before they start reporting now work (verified with 8BitDo Ultimate 2C Wireless
  Controller and its dongle; previously dongle enumerated and bound but sent no input,
  while same pad worked over Bluetooth), and rumble is available on xpad-driven
  controllers. Kernel Image is unchanged by this; only module set changed.

- **Kernel rebuilt with `CONFIG_PSI=y`** (`PSI_DEFAULT_DISABLED` off), from
  armbian/linux-rockchip, branch `rk-6.1-rkr5.1`, commit `95e85f6c`. Android 11 and later
  `init`/`lmkd` hard-require `/proc/pressure`; without it Waydroid container boots and
  then dies in about 15 seconds. V5.0 build was Image-only, with kernel release
  string unchanged at 6.1.115 and vendor modules kept; as of v6.0 release string is
  `6.1.115-h96` and modules are rebuilt with Image (see above).
  **Existing users cannot `apt upgrade` into this kernel. It needs new image.**
- **New `h96-waydroid`**: Android in container (Waydroid 1.6.2 plus nested Weston
  window on X11). `init gapps|vanilla`, default, fetches official Waydroid
  LineageOS 20 (Android 13, vendor type MAINLINE, about 900 MB) and wires Mali-G610:
  `dumpsys SurfaceFlinger` reports `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1
  Mesa 26.0.1`, GPU load `0@300000000Hz` at idle, 50 percent at 1000 MHz under UI activity
  and 19 to 26 percent at 600 MHz, with `boot_completed=1` about 8 seconds in and no
  cgroup v1 shims needed. `init gpu` is LEGACY path for third-party Panthor
  Android 11 image (LineageOS 18.1, about 5 GB, user-supplied, Mesa 24.0.5, GPU load 27 to
  41 percent at 300 to 700 MHz), unsigned and abandoned since April 2024. `init custom
  <dir>` takes your own arm64 Waydroid-style `system.img` plus `vendor.img` pair. Images
  are **not** bundled. `hw off` forces software rendering for diagnosis. Container
  **cannot use RK3588 NPU**: its `vendor.img` carries no RKNN libraries and no
  neuralnetworks HAL.
- **New `h96-emulators`**: 8 GPU-accelerated systems (`retroarch`, `dolphin`, `ppsspp`,
  `flycast`, `melonds`, `rmg`, `azahar` as native ARM64 Flatpaks through PanVK/Panfrost,
  plus `cemu` as x86-64 build under `box64`). `install` wires each Flatpak sandbox to
  Mali GPU and then verifies it, warning when emulator would silently fall back to
  `llvmpipe` software rendering.
- **`h96-npu` gains `power [performance|balanced|powersave|sync|status]`.** NPU devfreq
  had been pinned at 1000 MHz for 100 percent of uptime while unused; `powersave` parks it
  at 300 MHz. `power sync` matches NPU to system CPU and GPU profile, and `sync on`
  makes it follow `h96-perf` automatically. `h96-perf` is now listed in `h96` command
  index.
- **Efficiency:** two units that failed every boot are fixed, so `systemctl --failed`
  reports zero. `rsyslog` is disabled (`/var/log` measured 33 MB before and 3.6 MB right after; journal is capped at 200 MB;
  `journalctl` is unaffected), and `lxc`, `lxc-net` and `lxc-monitord` are disabled.
- **v4.2.1** added `h96` command index: type `h96` for categorized list of every
  command, or `h96 <command>` for its help. **v4.2** was efficiency delta on v4.1:
  faster boot, zram zstd compression, and VM sysctl tuning baked into image.
- Full image boots to console and does **not** ship KDE pre-installed.
  Install desktop when you want it through `armbian-config`; first launch of Plasma
  applies H96 desktop settings.
- Shipped flasher is slim-capable: from full image it can strip to headless
  (nodesktop), no-GPU, or bare-server build before writing, so one download covers desktop,
  headless, and server use. Free space is reclaimed with `zerofree` after stripping.

These sources cover kernel, device tree, and BSP package image is built from;
desktop and headless split is userspace and packaging step and is not selected from this
repo.

---

## Hardware status

| Component                   | Status | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
|-----------------------------|--------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| CPU (8-core RK3588)         | ✅     |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Mali-G610 GPU               | ✅     | Open **Panthor** + Mesa (Panfrost GLES / PanVK Vulkan 1.4); GPU-composited desktop                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Hardware video decode       | ✅     | Rockchip MPP + mpv (VPU). v4.0 corrects DMA-heap permissions that made hardware decode root-only in every earlier release; non-root users received software decode. Fix for earlier releases is in CHANGELOG                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Hardware video **encode**   | ✅     | RKVENC/RKVENC2/JPGENC via `h96-encode`; H.264 and HEVC measured faster than 180 fps at 1080p. Note bundled ffmpeg has no `libx264`, so this is only encode path                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Display autodetect (EDID)   | ✅     | `h96-display auto` sets mode from display's EDID (bit-banged DDC read; SoC's DDC controller does not work on this kernel). Native-mode autodetect in desktop is opt-in: `sudo h96-display autodetect on`                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Monitor brightness (DDC/CI) | ✅     | `h96-brightness`: hardware backlight over DDC/CI via kernel i2c-gpio bus on DDC pins. ddcutil installs at first boot. Needs DDC/CI-write-capable monitor; most TVs gate it. KDE PowerDevil shows slider                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Display scale               | ✅     | `h96-scale <factor>`: sets KDE global scale (`kdeglobals` + font DPI) and restarts Plasma shell to apply live. On X11 log out/in is required to reach all apps, so autologin is enabled (`h96-autologin.service`). Wayland not used (breaks GPU/compositing/mpv)                                                                                                                                                                                                                                                                                                                                                                                                           |
| Ethernet                    | ✅     |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| WiFi 6 (BCM43752 / AP6275P) | ✅     | **PCIe**, runs simultaneously with Ethernet                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Bluetooth                   | ✅     | BCM UART                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| HDMI + audio                | ✅     |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Front-panel VFD             | ✅     | TM1650, clock + status icons (`h96-vfd`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| IR remote                   | ✅     | `gpio-ir-receiver` overlay, learn with `ir-keytable`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| eMMC storage                | ✅     |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| GPU upscaling               | ✅     | `ravu-lite-ar-r4` as mpv user shader via `h96-upscale`; measured ~10-13% extra GPU time. Needs desktop session                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| NPU (3-core, ~6 TOPS)       | ✅     | Driver `v0.9.8`, IOMMU mode, per-core load via `h96-npu`. `h96-npu bench` runs INT8 matmul (~625 GOPS one core; `bench all` ~1.29 TOPS across 3 cores). v5.0 adds `h96-npu power [performance\|balanced\|powersave\|sync\|status]`: devfreq had been pinned at 1000 MHz for 100 percent of uptime while unused, `powersave` parks it at 300 MHz, `power sync` matches CPU and GPU profile. Inference runtime is proprietary and fetched on demand with `h96-npu-setup`, never bundled                                                                                                                                                                                      |
| System monitor              | ✅     | `scrumptop`: per-core CPU (A76/A55 topology) with per-cluster temperature gauges, GPU/NPU load, network rates, Bluetooth, IR activity, eMMC I/O, peripheral batteries. `b` = NPU bench, `+`/`-` = polling rate                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Desktop lock screen         | ✅     | v4.0 corrects `/etc/shadow` group ownership from base rootfs. Lock screens rejected correct passwords in every earlier release. Fix for earlier releases is in CHANGELOG                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Android apps (Waydroid)     | ✅     | v5.0 `h96-waydroid`. Needs v5.0 `CONFIG_PSI=y` kernel. `init gapps\|vanilla` (default) runs official LineageOS 20 (Android 13, MAINLINE vendor) on Mali-G610 in hardware: `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`, 50 percent GPU at 1000 MHz under UI activity. `init gpu` is legacy third-party Android 11 Panthor image (Mesa 24.0.5, unsigned, abandoned April 2024). Window is fixed size on purpose; v5.0.1 adds `size fullscreen` (borderless, fills screen). v5.0.1 also adds clean teardown (closing window stops container and releases GPU, with Stop Android menu entry) and `q` to quit from terminal. Container **cannot** use NPU |
| GPU emulators               | ✅     | v5.0 `h96-emulators`: `retroarch`, `dolphin`, `ppsspp`, `flycast`, `melonds`, `rmg`, `azahar` as native ARM64 Flatpaks on PanVK/Panfrost, `cemu` as x86-64 build under `box64`. `install` verifies each one is not falling back to `llvmpipe`                                                                                                                                                                                                                                                                                                                                                                                                                              |

> **Note on Ethernet.** Onboard RTL8211F PHY may spend extended time attempting
> Gigabit auto-negotiation before downshifting to 100Mbps, so link can take minutes
> to become usable after boot while system itself reaches multi-user in about 7
> seconds. Kernel logs `Downshift occurred from negotiated speed 1Gbps to actual
> speed 100Mbps, check cabling!`. Measured at 26 s, 128 s and 190 s across boots on one
> unit. **On measured unit, cause was far end, not board:**
> link partner advertised only 10/100, so board was correctly asking for
> speed nothing answered. Check what router or switch supports before
> suspecting box. Try different cable or switch port first; `ethtool -s eth0 speed 100 duplex
> full autoneg off` skips Gigabit negotiation at cost of capping port.

> **Note on kernel log.** At boot kernel prints two `WARNING` traces from
> `pinctrl-rockchip.c` (`rockchip_pmx_gpio_set_direction`, `pin 143 already requested by
> fde80000.hdmi` and `pin 144 already requested by fde80000.hdmi`). The `h96-ddc-i2c-gpio`
> overlay reassigns HDMI DDC pins to i2c-gpio bus for DDC/CI brightness control, and
> pinctrl driver logs reassignment. They are harmless; kernel sets its `W` taint
> flag and bus works.

---

## Thermals

Read from `/sys/class/thermal` on shipped image. Trip points are SoC BSP
defaults; nothing here changes them.

| Zone                 | Passive trips | Critical |
|----------------------|---------------|----------|
| `soc-thermal`        | 80 C, 95 C    | 115 C    |
| `bigcore0-thermal`   | 75 C          | 115 C    |
| `bigcore1-thermal`   | 75 C          | 115 C    |
| `littlecore-thermal` | 75 C          | 115 C    |
| `center-thermal`     | 75 C          | 115 C    |
| `gpu-thermal`        | 75 C          | 115 C    |
| `npu-thermal`        | 75 C          | 115 C    |

Cooling devices: `cpufreq-cpu0`, `cpufreq-cpu1`, `cpufreq-cpu3`, `devfreq-fb000000.gpu`.

Measured on one unit: idle about 52 to 61 C. Sustained all-core `performance` load
reached 85 C, above `soc-thermal` passive trip, so box throttles under sustained
load. That is expected for this SoC in this chassis and is not fault.

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
  kernel/h96-vop2-cursor-pd.patch v6.1 VOP2 cursor power-domain fix, applied after the
                                  v6.0 one (same file)
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
    src/ddc-vcp.c                 DDC/CI VCP read/write over bit-banged DDC bus
                                  (h96-brightness)
    overlays/h96-ddc-i2c-gpio.dts HDMI DDC pins as i2c-gpio bus (DDC/CI brightness)
    edid/h96-1080p-audio.bin      forced 1080p EDID with audio block (+ README.md)
    environment.d-h96-gpu.conf    GLES/EGL env so desktop composites on GPU
    brcm4362a2_firmware/          BCM4362A2.hcd - vendor Bluetooth firmware blob
    wireplumber/30-h96-bluetooth.conf  Bluetooth audio: A2DP and HFP settings, autoswitch,
                                  sink quantum and no-suspend (install to
                                  /etc/wireplumber/wireplumber.conf.d/)
    wireplumber/51-h96-iec958.conf  IEC958 codec list on HDMI node (h96-audio-passthrough
                                  codecs on|off)
    pipewire/90-h96-eq.conf       h96 EQ filter chain (install to
                                  /etc/pipewire/pipewire.conf.d/)
    pipewire/95-h96-silence-source.conf  v6.2 "Silence (no microphone)" input
    bluetooth/h96-bt-policy.py    v6.2 BlueZ reconnect policy for main.conf
                                  (install to /usr/local/lib/h96/)
    bluetooth/h96-bt-a2dp-heal.py v6.2 headset A2DP reconnect daemon
                                  (install to /usr/local/lib/h96/)
    etc-h96/eq/active.txt         v6.2 flat EQ file (0 dB); also installed as
                                  /usr/local/lib/h96/eq-active-flat.txt for tmpfiles
    etc-h96/eq/presets/           AutoEQ presets for h96-audio-eq
    etc-h96/bt-speaker.conf       h96-bt-speaker settings
    etc-h96/cec-keymap.conf       h96-cecd key map
    etc-h96/transcode.conf        h96-transcode-server settings
    tmpfiles.d/h96-eq.conf        v6.2 restores flat EQ file at boot if missing
                                  (install to /etc/tmpfiles.d/)
    mpv/                          hdr.conf, motion.conf, passthrough.conf fragments
                                  (h96-hdr, h96-motion, h96-audio-passthrough)
    modules-load.d/rfcomm.conf    autoloads rfcomm (needs CONFIG_BT_RFCOMM=m in
                                  the kernel config) so the Hands-Free headset mic
                                  works; install to /etc/modules-load.d/
    modules-load.d/xpad.conf      autoloads xpad (CONFIG_JOYSTICK_XPAD=m, with
                                  JOYSTICK_XPAD_LEDS and JOYSTICK_XPAD_FF since v6.0)
    systemd/h96-vfd.service       unit for daemon
    systemd/h96-display-wake.service  display-wake daemon unit (+ -once.service
                                  for hotplug; see CHANGELOG v4.0 2c)
    systemd/h96-edid-adapt.service  injects attached display's EDID into DRM
    systemd/h96-rfcomm.service    depmod for the running kernel (uname -r), then
                                  loads rfcomm and xpad before BlueZ; enable it
    systemd/bt-sco-hci.service    routes SCO audio over HCI (Broadcom VSC 0xFC1C)
                                  so the headset mic carries data; enable it
    systemd/h96-bt-a2dp-heal.service  v6.2 runs h96-bt-a2dp-heal.py; enable it
    systemd/bluetooth.service.d/20-h96-policy.conf  v6.2 runs h96-bt-policy.py
                                  before bluetoothd
    systemd/h96-undervolt-trial.service  boot-time guard for the h96-undervolt trial
    systemd/h96-autologin.service, h96-cec.service, h96-gmediarender.service,
      h96-shairport.service, h96-uxplay.service, h96-transcode-server.service
                                  units behind h96-autologin-setup, h96-cec, h96-cast
                                  and h96-transcode-server
    systemd/system.conf.d/zz-h96-watchdog.conf  v6.1 RuntimeWatchdogSec=30s
                                  (install to /etc/systemd/system.conf.d/)
    tools/                        userspace tools installed to /usr/local/bin|sbin:
                                  h96 (command index), h96-perf, h96-npu, h96-encode,
                                  h96-upscale, h96-npu-setup, h96-npu-upscale(-setup),
                                  h96-subtitles(-setup), scrumptop, h96-display,
                                  h96-display-wake.sh, h96-edid-adapt.sh,
                                  h96-brightness, h96-scale, h96-widevine-setup,
                                  h96-autologin-setup, h96-undervolt, h96-waydroid,
                                  h96-emulators, h96-game-mode, h96-dxvk-install,
                                  h96-backup, h96-restore, h96-backup-gui, h96-cec,
                                  h96-hdr, h96-motion, h96-audio-eq,
                                  h96-audio-passthrough, h96-bt-speaker, h96-cast,
                                  h96-transcode-server, h96-xpad-dedup (/usr/local/sbin/)
    tools/h96-steam               v6.1 Steam installer front end (native installer 1.2
                                  since v6.2); installers in
                                  lib/steam/ (installed to /usr/local/lib/h96/steam/)
    lib/                          shared banner library, EDID mode picker, subtitle
                                  renderer, h96-bt-agent, h96-bt-loopback, h96-cecd,
                                  display-wake daemon (installed under /usr/local/lib/h96/)
    udev/99-h96-dma-heap.rules    DMA-heap group/mode rule (hardware video decode
                                  for non-root users; see CHANGELOG v4.0)
    udev/97-h96-display-wake.rules  HDMI re-drive check after hotplug
    udev/99-h96-hdmi-audio.rules  v6.2 HDMI detect (modes, audio, CEC address) on hotplug
    udev/99-h96-ddc-i2c.rules     video group access to i2c-ddc bus
    udev/99-h96-cec.rules         video group access to CEC device
    udev/99-h96-xpad.rules        binds X-input dongles missing from xpad table
    udev/60-h96-gamepad-hidraw.rules  v6.1 hidraw + uinput access for every xpad pad
    udev/71-h96-xpad-dedup.rules  v6.1 drops headset interface of third-party 360 pads
    shaders/ravu-lite-ar-r4.hook  mpv prescaler used by h96-upscale
                                  (bjin/mpv-prescalers, LGPL-3.0, header intact)
    sysctl.d/zz-h96-hang.conf     v6.1 hang recovery sysctls (install to /etc/sysctl.d/)
    sysctl.d/zz-h96-steam.conf    v6.1 vm.max_map_count for Proton
    apt/                          v6.1 offline repo source (Signed-By), its low pin and
                                  public keyring; install to /etc/apt/sources.list.d/,
                                  /etc/apt/preferences.d/ and /usr/share/keyrings/
    v6.2 additions (install path in brackets):
    systemd/h96-display-console.service  console colour: one blank cycle at boot when loader
                                  left HDMI in YCbCr [/etc/systemd/system/, enabled]
    systemd/h96-hdmi-audio-detect.service, h96-scdc.service, h96-leds.service,
      h96-hotspot-repair.service, h96-pkgs-setup.service/.timer
    tools/h96-scdc, h96-leds, h96-wol, h96-vm, h96-hotspot, h96-boot-profile,
      h96-wifi-connect, h96-video-setup.sh, h96-pkgs-setup.sh, h96-bt-attach.py
    lib/edid_audio.py, edid_merge.py, h96-hdmi-sink-migrate.sh, h96-cec-wake
                                  [/usr/local/lib/h96/]
    lib/eq-active-flat.txt        flat EQ restored at boot [/usr/local/lib/h96/]
    autostart/h96-cec-wake.desktop, h96-display-session.desktop  [/etc/xdg/autostart/]
    wireplumber/10-h96-audio-names.conf, 20-h96-hdmi-audio.conf, 51-h96-iec958.conf
                                  [/etc/wireplumber/wireplumber.conf.d/]
    alsa/60-h96-hdmi.conf         [/etc/alsa/conf.d/]
    alsa-card-profile/h96-hdmi.conf  HDMI layouts as card profiles
                                  [/etc/alsa-card-profile/mixer/profile-sets/]
    edid/h96-sink-audio.seed.bin  first-boot kernel EDID [/usr/lib/firmware/edid/h96-sink-audio.bin]
    skel/wireplumber-default-nodes  [/etc/skel/.local/state/wireplumber/default-nodes]
    mpv/mpv.conf                  base mpv config [/etc/mpv/mpv.conf]
    udev/70-h96-pinhole.rules     desktop ignores pinhole button
docs/
  DEVICE-TREE-CHANGES.md          every DT change vs stock vendor DTB, explained
  BLUETOOTH-AUDIO.md              Bluetooth audio, headset microphone, codecs, manual install
  MEDIA-FEATURES.md               media suite and USB controllers
CHANGELOG.md  CREDITS.md  LICENSE
```

---

## Building image with Armbian framework

These sources plug into standard [Armbian build system](https://github.com/armbian/build).
Device tree carries hardware enablement; rest is board config + BSP.

> **Released images are NOT built by these steps.** Shipped `.img` files are rootless
> delta on known-good ophub RK3588 6.1.x BSP base image (Rock 5B lineage, adapted to
> H96 NVR-DEMO DTB), and v6.0 kernel was built outside framework from source,
> config and patches published here. Steps below build bare Armbian board from
> framework: booting console with working peripherals, but WITHOUT `h96-*` userspace
> layer (GPU staging, VPU/NPU setup, Bluetooth stack, media tools, display/EDID handling).
> No `compile.sh` invocation reproduces release image. Build from source to change
> kernel or DTB; flash release to run box. These steps were written against
> framework source at time of writing and have not been run end to end by us.

**What v6.1 kernel is.** Source `armbian/linux-rockchip`, branch `rk-6.1-rkr5.1`, commit
`95e85f6cb496c75807c5b16f158853578e7e7d1b`, plus three plain `-p1` diffs against that commit:
`patch/kernel/h96-board-support.patch` (independent of other two),
`patch/kernel/h96-vop2-cursor.patch` and then `patch/kernel/h96-vop2-cursor-pd.patch` (both
touch `rockchip_drm_vop2.c`; second is diff against result of first, so apply
them in that order), built with `config/linux-rk35xx-vendor.config`.
`config/kernel-h96-max-v58.config` is human-readable summary of that config, not build
input. Release string is `6.1.115-h96v58v2` (v6.1: `6.1.115-h96v58v1`); v6.0 kernel was same source with
first two patches, release string `6.1.115-h96`, and two debug options on that v6.1
turns off (`SLUB_DEBUG`, `SCHEDSTATS`). This build also turns on `CONFIG_LOCKUP_DETECTOR=y`,
`CONFIG_SOFTLOCKUP_DETECTOR=y` and `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y`, so CPU that stops
scheduling for 20 seconds is reported and kernel panics.

**Build `BRANCH=vendor`, not `edge`.** On rockchip-rk3588 family `edge` resolves to
rolling mainline (7.2+), which ships NO RK3588 vendor drivers: board reaches console
with no GPU, no hardware video, no HDMI on this BSP, dead onboard WiFi/BT (issue #5).
`vendor` selects rk-6.1 BSP kernel (LINUXFAMILY `rk35xx`) that knows this SoC.
Family file tracks newer rk-6.1 branch (`rk-6.1-rkr7.2` at time of writing); board
file's `post_family_config` hook pins `KERNELBRANCH` to commit above so patches and
config match. Build on Ubuntu Jammy or Noble (or Armbian Docker path); newer hosts break
Radxa u-boot build.

**Names framework derives.** For `BRANCH=vendor` on this family kernel config is
`linux-rk35xx-vendor.config` (`LINUXCONFIG`) and kernel patch directory is
`KERNELPATCHDIR`, `rk35xx-vendor-6.1` at time of writing (earlier framework versions used
`rk35xx-vendor`). Read both from `config/sources/families/rockchip-rk3588.conf` in
framework checkout before step 3 and use value it gives.

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
cp  /path/to/this-repo/patch/kernel/h96-vop2-cursor-pd.patch userpatches/kernel/$KPD/
#    The framework applies userpatches in name order, so h96-vop2-cursor.patch precedes
#    h96-vop2-cursor-pd.patch, which is the order they need.

# 4. Device tree. A .dts in the dt/ subdirectory of the kernel patch directory is copied
#    to arch/arm64/boot/dts/rockchip/ and added to that Makefile by the framework
#    (dts-directories and auto-patch-dt-makefile in
#    patch/kernel/<KERNELPATCHDIR>/0000.patching_config.yaml); no Makefile patch is needed.
#    The file name sets the DTB name, which must equal BOOT_FDT_FILE in the board file.
cp  /path/to/this-repo/patch/kernel/rk3588-h96-max-v58-panthor.dts  userpatches/kernel/$KPD/dt/

# 5. Full kernel config. With KERNEL_CONFIGURE=no the framework copies this file to .config
#    and runs olddefconfig; it is the exact .config the v6.1 kernel was built with.
mkdir -p userpatches/config/kernel
cp  /path/to/this-repo/config/linux-rk35xx-vendor.config  userpatches/config/kernel/

# 6. Build (6.1 BSP kernel, desktop image)
./compile.sh  BOARD=h96-max-v58  BRANCH=vendor  RELEASE=resolute \
              BUILD_DESKTOP=yes  BUILD_MINIMAL=no  KERNEL_CONFIGURE=no
```

Output image lands in `output/images/`. It boots bare 6.1 board; `h96-*` tooling is
separate userspace delta releases carry, not part of this build.

**What framework changes on top of config.** Framework's own
`armbian_kernel_config__*` hooks (`lib/functions/compilation/armbian-kernel.sh`) rewrite
parts of any user-supplied `.config` before build: they set `CONFIG_LOCALVERSION` to
empty string, force `CONFIG_RT_GROUP_SCHED=y` for Docker, and turn BTF debug information on (`CONFIG_DEBUG_INFO`, `CONFIG_DEBUG_INFO_BTF`), which shipped configuration also carries, along with
zram, nftables, filesystem and container options that vendor config already carries.
Board file's `custom_kernel_config` hook runs after them and restores v6.2 values
(`CONFIG_LOCALVERSION="-h96v58v2"`, `CONFIG_RT_GROUP_SCHED=n`, `CONFIG_MODVERSIONS=y`,
`CONFIG_PSI=y`, `CONFIG_SCHED_CLUSTER=y`, `CONFIG_NVMEM_ROCKCHIP_SEC_OTP=n`, `CONFIG_DRM_PANTHOR=m`, `CONFIG_DEBUG_INFO_BTF=y`, `CONFIG_DEBUG_INFO_BTF_MODULES=y`, `CONFIG_JOYSTICK_XPAD_LEDS=y`, `CONFIG_JOYSTICK_XPAD_FF=y`, `CONFIG_LOCKUP_DETECTOR=y`, `CONFIG_SOFTLOCKUP_DETECTOR=y`, `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y`); do not pass `KERNEL_BTF=no`, which would turn BTF off. Framework also
adds `LOCALVERSION=-vendor-rk35xx` on make command line, so framework-built kernel
reports `6.1.115-h96v58v2-vendor-rk35xx` and installs its modules under that name;
released image reports `6.1.115-h96v58v2`. That is naming difference, not configuration difference.
Framework's own patches in `patch/kernel/<KERNELPATCHDIR>/` (two small files at time of
writing: HID Sony patch and Bluetooth HCI quirk) are applied as well and are not in
released kernel; delete them from checkout before step 6 for closer match.

**Modules travel with Image.** Config sets `CONFIG_LOCALVERSION="-h96v58v2"` and
`CONFIG_MODVERSIONS=y`, so built kernel's modules carry symbol versions. Install
modules with kernel they were built with (`make modules_install` from same tree into
`/lib/modules/$(make kernelrelease)`); loader rejects module built against different
kernel layout, so module set from another build does not load on it. Armbian framework
build above packages kernel and modules together on its own; manual kernel build must do it
explicitly.

**Kernel patches.** `patch/kernel/h96-vop2-cursor.patch` is v6.0 change to
`drivers/gpu/drm/rockchip/rockchip_drm_vop2.c`: it re-asserts hardware cursor window on
each video-port latch so cursor stays visible under continuous GPU compositing.
`patch/kernel/h96-vop2-cursor-pd.patch` is v6.1 change to same file: window
records whether it holds reference to its power domain, domain is powered on whenever
window needs it, and unbalanced release is refused and reported once in kernel log.
`patch/kernel/h96-board-support.patch` carries board support every release has had:
BCM43752 ids for `brcmfmac`, two `bcmdhd` log-prefix lines, SDIO rescan hook in `dw_mmc`
and `rfkill-wlan`, HDMI PHY clock name, and 8BitDo entries in `xpad`. Both are
verified against pinned commit with `patch -p1 --dry-run`. If HDMI stays dark on first
boot, force mode: add `video=HDMI-A-1:1280x720@60e` to `extraargs=` line in
`/boot/armbianEnv.txt` (trailing `e` forces mode past this BSP's EDID-read bug).

> **Note on device tree.** `patch/kernel/rk3588-h96-max-v58-panthor.dts` is decompile of
> stock Android vendor DTB, edited for open-GPU Armbian (hence
> `rockchip,rk3588-nvr-demo-v10-android` compatible and numeric phandles). File is
> decompile of `rk3588-h96-max-v58-panthor.dtb`, DTB v6.2 image boots (`fdtfile=` in
> `/boot/armbianEnv.txt`), and recompiles to same tree. `docs/DEVICE-TREE-CHANGES.md`
> documents every change so it can be re-applied onto mainline `rk3588.dtsi` for
> from-scratch DTS. BSP tools that edit device tree (`h96-undervolt`,
> `h96-undervolt-trial.service`) use `-panthor` path, so keep that DTB name.

---

## Device-tree changes

Full detail in [`docs/DEVICE-TREE-CHANGES.md`](docs/DEVICE-TREE-CHANGES.md). In short:

- **Open GPU:** `gpu-supply` + `&cru CLK_GPU` + 1000 MHz OPP; Panthor binding.
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

Front panel is **TM1650** bit-banged over GPIO3. Daemon shows clock
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
sudo apt install ir-keytable   # needs network; not in offline repo
ir-keytable            # shows gpio_ir_recv device
ir-keytable -p nec -t  # press buttons -> scancodes
```

## Open-GPU desktop

For KDE/GNOME to composite on GPU (not fall back to software `llvmpipe`),
append `packages/bsp/h96-max-v58/environment.d-h96-gpu.conf` to `/etc/environment`.
Do **not** install `libmali` blob packages: they shadow Mesa's EGL/Vulkan.

---

## Flashing

RK3588 flashes over USB with **`rkdeveloptool`** in Maskrom mode (hold
recessed reset pinhole, rear panel, in gap between two WiFi antenna
posts, while connecting USB), or with Rockchip's RKDevTool GUI on
Windows. Write Armbian image (`.img`) to eMMC. This is standard RK3588
procedure and is not specific to this repo.

---

## License & credits

GPL-2.0-only. See [`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md). Built on
Armbian, Linux kernel, Rockchip's BSP, Panthor, and Mesa.

---

This project is not affiliated with, endorsed by or sponsored by Valve Corporation. Steam, Proton, Steam Deck and Steam Frame are trademarks of Valve Corporation. No Valve artwork ships in image.
