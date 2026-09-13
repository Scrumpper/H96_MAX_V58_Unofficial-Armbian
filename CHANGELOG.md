# Changelog



## v6.0 (2026-09-07)

v6.0 over v5.0.1. Ships as a new image only. The kernel Image changes, so moving to it is a
reflash, not an `apt upgrade`. The device tree is unchanged since v4.3. Every v5.0 feature and
command is retained.

v6.0 absorbs the planned v5.2. The kernel changes across several rebuilds, cluster-aware
scheduling together with the VOP2 cursor driver fixes, are substantial enough to warrant a
major version rather than a point release. This is a versioning and scope statement, not a
performance claim: `CONFIG_SCHED_CLUSTER` is topology-correctness only and the cursor work is a
correctness fix; benchmarking found no measurable change in throughput, and none is claimed.

- **Hardware cursor during GPU compositing, fixed in the kernel driver.** v5.0.1 kept the mpv
  cursor visible during playback (`cursor-autohide=no`) as a workaround for the RK3588 VOP2
  hardware-cursor latch bug: under continuous GPU compositing the hardware cursor plane was not
  restored once it had been hidden, so after mpv hid the cursor during fullscreen playback the
  pointer stayed invisible until reboot. v6.0 fixes it in the kernel driver by re-asserting the
  cursor on the video-port latch each frame, so the hardware cursor stays visible during
  continuous GPU compositing (fullscreen video, animated browser pages, the desktop splash); it
  still auto-hides over video and returns on movement, and it survives leaving mpv back to the
  desktop. `/etc/mpv/mpv.conf` restores `cursor-autohide=1000` with `x11-bypass-compositor=never`,
  so autohide is active during playback and KWin compositing stays on in fullscreen.
- **`h96-backup` and `h96-restore`.** A flash writes the whole eMMC and removes every on-demand
  feature installed on top of the console base. `h96-backup` captures one archive: a manifest of
  which features are present (desktop, emulators, Waydroid, Widevine, gaming, NPU runtime) plus
  the passive data that cannot be re-downloaded (a config subset, emulator saves, the wine
  prefix, WiFi credentials, the Waydroid `/data`). The multi-GB Waydroid image stashes are left
  out by default (`--with-images` includes them); restore re-downloads them instead.
  `h96-restore` reads the manifest, reinstalls the recorded features, then restores the passive
  data to the correct paths and owners. A config file already present and newer than the
  archived copy is kept, not overwritten; `--force` overwrites it (stop the desktop session
  first on a fresh image, whose session has already written default configs). `--open`
  prints the installer commands for you to run yourself instead of running them; `--dry-run`
  prints the plan and changes nothing. Both tools take `--only` and `--skip` category lists
  and `--emulators`; `h96-backup-gui` presents the same choices as checkboxes and runs the
  tools in a terminal window. Boxes on v5.0.1 or earlier have no backup tool; the migration kit (`h96-migrate-kit.zip` in the release) installs the same three tools there (`sudo bash install.sh`, `--gui` for the window) so the box can be captured to a USB stick before the flash.
- **`h96-undervolt` trial flow corrected.** The trial flow now works as documented: `set <mV>`,
  then reboot, and the setting is active on that boot so you can test it under load; `test` runs
  a SIMD load; `confirm` keeps it. Reboot without confirming and the boot-time guard reverts to
  the stock device tree on its own. Previously the guard could revert the setting before there
  had been a boot on which to confirm it.
- **Kernel: `CONFIG_SCHED_CLUSTER`.** The kernel now enables `CONFIG_SCHED_CLUSTER`, which
  represents the RK3588 as its three CPU clusters instead of one flat group, so the scheduler's
  topology view matches the hardware. On this board the clusters are 4x Cortex-A55 (cpu0, cpu5,
  cpu6, cpu7), 2x Cortex-A76 (cpu1, cpu2) and 2x Cortex-A76 (cpu3, cpu4); the two A76 pairs are
  separate DVFS clusters. This is a topology-correctness change: benchmarking found no
  measurable change in throughput, and none is claimed.
- **Kernel BTF type data.** The kernel carries BPF Type Format (BTF) data
  (`CONFIG_DEBUG_INFO_BTF`, with `CONFIG_DEBUG_INFO_BTF_MODULES` for the module set):
  `/sys/kernel/btf/vmlinux` describes the kernel's types (7 MB) and every module exports its
  own, so `bpftool`, `bcc` and CO-RE BPF programs read kernel and module types on the box
  without kernel headers. `bpftrace` kprobes walk kernel structs the same way; pass
  `--traceable-functions` with a symbol list from `/proc/kallsyms`, since this kernel has no
  ftrace function list. BTF is data that BPF tools read; the machine code is the same with or
  without it, and the kernel Image grows by 7 MB. Armbian's own rk35xx kernel configuration
  ships with BTF on. The VOP2 cursor fix ships in this repo as
  `patch/kernel/h96-vop2-cursor.patch`, built with `config/linux-rk35xx-vendor.config`.
- **Known kernel-log item.** At boot the kernel prints two `WARNING` traces from
  `pinctrl-rockchip.c` (`rockchip_pmx_gpio_set_direction`, `pin 143 already requested by
  fde80000.hdmi` and `pin 144 already requested by fde80000.hdmi`). They come from the
  `h96-ddc-i2c-gpio` overlay reassigning the HDMI DDC pins to an i2c-gpio bus for DDC/CI
  brightness control. They are harmless; the kernel sets its `W` taint flag and nothing else
  changes.
- **Kernel log cleanup.** The `H96DBG` diagnostic lines that v5.0.1 printed during HDMI setup
  are gone; the HDMI PHY driver reports clock setup errors instead of hiding them, and the
  unused secure-OTP driver is left out of the build (`CONFIG_NVMEM_ROCKCHIP_SEC_OTP=n`). The
  board-support patch set is published as `patch/kernel/h96-board-support.patch`.
- **Kernel release `6.1.115-h96`, modules rebuilt with symbol versioning.** The release
  string is `6.1.115-h96` (`CONFIG_LOCALVERSION="-h96"`) and modules live in
  `/lib/modules/6.1.115-h96`. The full module set (3110 modules) is built from the same
  source and configuration as the kernel Image, with `CONFIG_MODVERSIONS=y`: every module
  carries symbol versions, and the loader rejects a module built against a different kernel
  layout instead of loading it unchecked. Earlier releases shipped a module set built against
  a pre-PSI configuration; those modules loaded on 6.1.115 kernels because the vermagic
  string matched, and only the modules in use had been checked by inspection. The bcmdhd
  WiFi module and every other module now carry matching symbol versions, and the kernel's
  `O` (out-of-tree) taint flag is gone; the only taint left is the `W` from the DDC pinctrl
  warning above. Moving to v6.0 remains a reflash. The `h96-rfcomm` service no longer
  hardcodes a kernel release; it reads `uname -r`. `config/linux-rk35xx-vendor.config` is the
  full kernel configuration the Image and modules were built with;
  `config/kernel-h96-max-v58.config` summarises the options that differ from the vendor
  default, and the README build steps install the modules with the kernel.
- **Repository.** The full kernel configuration is published as
  `config/linux-rk35xx-vendor.config` (the Armbian framework consumes a full config, not a
  fragment). The device tree source is `patch/kernel/rk3588-h96-max-v58-panthor.dts`, a
  decompile of the DTB the image boots; the earlier copy predated the PCIe WiFi enablement,
  and the board file's `BOOT_FDT_FILE` now names the booted DTB. The board file pins the
  kernel source to the commit the kernel was built from and restores the options the
  framework rewrites. `packages/bsp/h96-max-v58/systemd/h96-rfcomm.service` is added.
- **`CONFIG_RT_GROUP_SCHED` off.** It was on, inherited from the vendor Android
  configuration. Realtime scheduling is now available to processes outside the root cgroup:
  PipeWire's data-loop threads run at `SCHED_RR` priority 20 through rtkit, so audio threads
  keep their priority under CPU load, and `cyclictest` runs. Previously the journal logged
  `Failed to make ourselves RT: Operation not permitted` on every boot and the audio threads
  ran as normal tasks.
- **`xpad` built with player-LED and force-feedback support.** The `xpad` USB
  game-controller module is built with `CONFIG_JOYSTICK_XPAD_LEDS=y` and
  `CONFIG_JOYSTICK_XPAD_FF=y`. 2.4 GHz X-input dongles that wait for the Xbox 360 player-LED
  command before they start reporting now work; verified with the 8BitDo Ultimate 2C Wireless
  Controller and its dongle. Previously the dongle enumerated, the driver bound and
  `/dev/input/js0` existed, but no input arrived, while the same pad worked over Bluetooth.
  Force feedback (rumble) is available on xpad-driven controllers. The kernel Image is
  unchanged by this; only the module set changed. Both options are in
  `config/linux-rk35xx-vendor.config`, `config/kernel-h96-max-v58.config` and the board
  file's `custom_kernel_config` hook.

## v5.0.1

v5.0.1 over v5.0. Ships as a new image and as a fix-script for a running box (no reflash).
Kernel Image and device tree unchanged since v4.3.

- mpv cursor over fullscreen video fixed. `/etc/mpv/mpv.conf` sets `cursor-autohide=no` and
  `x11-bypass-compositor=never`. The RK3588 VOP2 hardware cursor plane is not restored after
  mpv hides it during playback (a kernel driver un-hide fault), so once hidden the cursor
  stayed invisible until a reboot. `cursor-autohide=no` stops mpv from hiding the hardware
  cursor. The driver fix that lets the cursor fade during playback and return on movement is
  deferred to v6.0.
- `h96-waydroid` clean teardown. Closing the Android window stops the session and the
  container, releasing the GPU the container held. A sudoers drop-in lets the desktop user run
  `h96-waydroid stop` without a password. A Stop Android menu entry was added.
- `h96-waydroid` borderless fullscreen. `h96-waydroid size fullscreen` opens the window
  borderless at 0,0 filling the screen. It opens at screen size, so there is no output
  reconfigure and no black surface.
- `h96-waydroid` q to quit. Started from a terminal, the launcher quits and tears down on `q`
  then Enter, in addition to closing the window.

## v5.0

Kernel rebuild, two new opt-in tools, and a stability pass over
v4.2.1. Shipped as one full image; the flasher still slims it to a headless, no-GPU, or
bare-server build on demand.

The released image is **console only**: no desktop and no user account. A desktop is
installed on demand (`armbian-config`, or `apt install kde-plasma-desktop`), and
`h96-autologin-setup` then wires lightdm autologin to the `plasmax11` (X11) session.
Reflashing wipes an existing desktop install.

- `.img`    sha256 `6a193bdf330b6de0156a7a26ca24e2fbe0343b57783295581f9aada7606a990c`
- `.img.xz` sha256 `f9f824d52bc381cac37f591452fe4aa8111543b2af3678146dc506ad8ad3ae95`

- **Kernel rebuilt with `CONFIG_PSI=y`** (`PSI_DEFAULT_DISABLED` off), from
  armbian/linux-rockchip, branch `rk-6.1-rkr5.1`, commit `95e85f6c`. Android 11 and later
  `init`/`lmkd` hard-require `/proc/pressure`; without it the Waydroid container boots and
  then dies in about 15 seconds. It is an **Image-only rebuild**: PSI is built in and the
  kernel release string is unchanged at 6.1.115, so `/lib/modules/6.1.115` stays valid and
  no module is rebuilt. Verified on hardware: 69 modules load with matching vermagic.
  **Existing users cannot `apt upgrade` into this kernel. It needs the new image.**

- **New `h96-waydroid`: Android in a container.** Waydroid 1.6.2 plus a nested Weston
  window inside the X11 session. Three image profiles:
  - `init gapps|vanilla`, the DEFAULT: the official Waydroid LineageOS 20 image
    (`lineage-20.0-20260403-VANILLA-waydroid_arm64`, Android 13, vendor type MAINLINE,
    about 900 MB), with the Mali-G610 wired by default (`drm_device=/dev/dri/renderD130`,
    `ro.hardware.gralloc=gbm`, `ro.hardware.egl=mesa`, `renderD130` and `card2` bound into
    the container). Measured: `dumpsys SurfaceFlinger` reports
    `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`; GPU load reads
    `0@300000000Hz` at idle, reaches 50 percent at 1000 MHz under UI activity, and sits at
    19 to 26 percent at 600 MHz. `boot_completed=1` with the session ready in about 8
    seconds. Android 13 is cgroup v2, so no cgroup v1 shims are applied.
  - `init gpu`, LEGACY: a third-party Panthor-in-image Android 11 build (LineageOS 18.1,
    about 5 GB) that you supply. Measured on this profile, `dumpsys SurfaceFlinger` reports
    `GLES: Mesa, Mali-G610 (Panfrost), OpenGL ES 3.1 Mesa 24.0.5`; GPU load runs 27 to 41
    percent at 300 to 700 MHz. Older Android, older Mesa, unsigned, needs cgroup v1 tmpfs
    shims, pins a 960x512 display that has to be overridden, Vulkan never worked, and it
    has been abandoned since April 2024 (author WillzenZou, repos frozen). Kept only for
    anyone holding that image.
  - `init custom <dir>`: your own arm64 Waydroid-style `system.img` plus `vendor.img`
    PAIR.
  - `hw off` forces software rendering, as a diagnostic and fallback; `hw on` re-applies
    the GPU wiring and verifies it.

  Correction to an earlier claim in this changelog: the official LineageOS 20 image was
  described as carrying no Panfrost and software rendering through SwiftShader. That was
  wrong. The tool's own `init` was forcing `ro.hardware.egl=swiftshader` and deleting
  `drm_device`, so the measurement described our configuration, not the image. Upstream
  enables the ARM drivers in `waydroid_arm64/BoardConfig.mk`
  (`BOARD_MESA3D_GALLIUM_DRIVERS += ... panfrost lima`, `BOARD_MESA3D_VULKAN_DRIVERS +=
  ... panfrost`), not in the root `BoardConfig.mk`, which lists only llvmpipe, virgl and
  friends. One constraint stands: HALIUM vendor images are stripped of the Mesa GPU
  drivers, so the MAINLINE vendor image is required, and MAINLINE is what these profiles
  fetch.

  Images are 2 to 5 GB, are **not** bundled, and are stashed under `/etc/waydroid-extra/`
  so switching profiles never re-downloads. The window is **fixed size on purpose**: any
  window-manager geometry change makes Weston reconfigure its X11 output, the Waydroid
  client cannot follow, and the window goes permanently black; the launcher pins
  `WM_NORMAL_HINTS` min equal to max. `spoof` reports the box as a common phone for Aurora
  Store, and does **not** defeat Play Integrity or SafetyNet. `state save|list|load|delete`
  snapshots the Android `/data`, and refuses cross-profile restores because Android 11 data
  on Android 13 crashes `system_server`.

  **Honest limit: the container cannot use the RK3588 NPU.** Its `vendor.img` has no RKNN
  libraries and no neuralnetworks HAL, so passing the node through would hand Android a
  device file with no driver.

- **New `h96-emulators`: 8 GPU-accelerated systems.** `retroarch`, `dolphin`, `ppsspp`,
  `flycast`, `melonds`, `rmg` and `azahar` as native ARM64 Flatpaks through PanVK/Panfrost,
  plus `cemu` as the x86-64 build under `box64`. `install` wires each Flatpak's sandbox to
  the Mali GPU and then verifies it, warning when an emulator would silently fall back to
  `llvmpipe` software rendering. mGBA and ScummVM are deliberately excluded: they are 2D,
  do not meaningfully use the GPU, and are already in the software store as `io.mgba.mGBA`
  and `org.scummvm.ScummVM` on Flathub, or as apt `mgba-qt` and `scummvm`.

- **`h96-npu` gains `power [performance|balanced|powersave|sync|status]`.** The NPU devfreq
  had been pinned at 1000 MHz for 100 percent of uptime while nothing used it; `powersave`
  parks it at 300 MHz. `power sync` matches the NPU to the system CPU and GPU profile, and
  `sync on` makes it follow `h96-perf` automatically. `h96-perf` is now listed in the `h96`
  command index.

- **Two units that failed every boot are fixed**, so `systemctl --failed` now reports zero.
  `h96-rfcomm` shipped a 0 byte `rfcomm.ko` and its self-heal guard tested `-f`, which
  passes for an empty file; it now tests `-s`. `systemd-modules-load` requested `brcmfmac`
  alongside `bcmdhd`, which owns the WiFi chip, and `rknpu`, which is built in.

- **`rsyslog` disabled.** It duplicated the whole journal to eMMC: 27.8 MB of
  `/var/log/syslog` in about 10 hours. `/var/log` measured 33 MB before the change and 3.6 MB immediately after. The journal itself is deliberately persistent and capped at 200 MB on eMMC plus 32 MB in tmpfs, so `/var/log` settles under that cap rather than staying at 3.6 MB. `journalctl`
  is unaffected.

- **`lxc`, `lxc-net` and `lxc-monitord` disabled.** Zero LXC containers exist and Waydroid
  uses its own bridge. Verified afterwards that Android still leases an address and pings
  8.8.8.8 with 0 percent loss.

- **Boot speed audited and deliberately NOT changed.** `graphical.target` is reached 4.860
  seconds into userspace. The 42 second figure in `systemd-analyze` is time until the last
  unit settles, which is two Bluetooth units intentionally ordered off the boot path.

- **TESTED AND REJECTED: shadowing the container's `/dev/kmsg`** to cut log noise. It
  mounts cleanly, but the Waydroid container then never starts. Recorded here so nobody
  retries it.

- **`h96-emulators` GPU verification, four bugs fixed.**
  1. `gpu_probe()` only tested that the Panfrost ICD **file** existed inside the sandbox.
     That file ships with `org.freedesktop.Platform.GL.default`, so it is present for every
     app using that extension: the check could never return "software" and verified nothing.
     It reported PPSSPP as hardware while PPSSPP's default OpenGL backend was failing with
     `EGL_BAD_ALLOC` and never opening a window. The probe reads a renderer string now
     and falls back to the file test only as a last resort, labelled "renderer NOT verified"
     rather than claiming hardware.
  2. The tool's user environment set only `WAYLAND_DISPLAY`, never `DISPLAY` or
     `XAUTHORITY`, and this box is X11 on purpose, so no GL probe could reach a display.
     After the fix the automatic probe verifies four of the seven Flatpaks directly as
     `Renderer: Mali-G610 MC4 (Panfrost)`, the Qt based ones where a renderer tool exists
     inside the runtime. The other three report "renderer NOT verified" rather than claiming
     hardware; hand testing from their own logs confirmed `retroarch` and `flycast` on
     hardware too, and PPSSPP only on its Vulkan backend.
  3. `gpu` silently skipped `cemu` (`if kind != "flatpak": continue`), hiding the entry most
     likely to have GPU trouble. It is reported explicitly now.
  4. `elevate()` re-execs the tool as root with `sudo -E`, which is deliberate so `DISPLAY`
     and `XAUTHORITY` survive for the probe. But `-E` also carried `HOME=/home/<user>` into
     the root process, and flatpak initialises a per-user repo at
     `$HOME/.local/share/flatpak` on almost any invocation. Run as root that repo landed in
     the desktop user's home owned by root with mode 700, so every later `flatpak run` as
     that user failed with `Permission denied` and the probe could only report `unknown`,
     which reads as a missing GPU when the GPU is fine. `elevate()` now pins `HOME=/root`
     while keeping `-E`, and a repair pass corrects the ownership on boxes already in that
     state.

- **`h96-waydroid` wires the GPU by default.** `init gapps|vanilla` no longer forces
  SwiftShader. cgroup v1 tmpfs shims are applied only on the legacy Android 11 path, since
  Android 13 is cgroup v2. `status` now keys the profile off which image stash is linked
  rather than off `drm_device`, which is always set now, and image identity properties are
  cleared on init so a profile switch cannot leak the previous image's model string.

- **zram self-heals.** Swap came up disabled on a fresh flash despite being configured. A
  self-heal unit re-establishes it at boot.

- **The KDE screen locker is off by default.** `/etc/skel/.config/kscreenlockerrc` ships
  `Autolock=false`, `LockOnResume=false`, `Timeout=0`, so a TV box does not lock itself.

- **Image builder no longer leaks orphan inodes.** It issued a blind `mkdir` per path
  component; `debugfs` leaks an inode when the directory already exists, which is where the
  34 empty numbered directories under `/lost+found` came from. The builder stats before
  creating now. The 35 inherited from earlier builds are still present, empty and harmless.

- **First boot no longer races Armbian's setup wizard for the dpkg lock.**
  `h96-online-extras.service` runs right after `multi-user.target`, exactly when the first-run
  wizard is creating the user account. It took the lock with no wait, so the wizard died with
  "could not get frontend lock" and finished its work in the background. The script now waits
  for the lock (`fuser` poll, the pattern `h96-gaming-setup.sh` already used) and passes
  `DPkg::Lock::Timeout=600` on both apt calls.

- **Flashing no longer needs the pinhole button.** A box that still boots is put into Loader
  mode with `reboot loader` over SSH, and the flasher converts Loader to Maskrom itself. The
  pinhole method stays documented as the fallback for a box that will not boot.

## v4.2.1

Adds the `h96` command index. Type `h96` on the box to list every command grouped by
category, or `h96 <command>` to open that command's help. Otherwise identical to v4.2.

## v4.2

Efficiency delta on v4.1. Same kernel (6.1.115), device tree, and hardware enablement.
Shipped as one full image; the flasher slims it to a headless, no-GPU, or bare-server build
on demand.

- **Faster boot.** The Bluetooth attach was moved off the boot-critical path with an
  `After=multi-user.target` drop-in on `h96-bt` and `bt-sco-hci`. `multi-user.target` is
  reached in about 3 to 4 seconds, against about 44 seconds on v4.1 where the attach blocked
  it while the BCM4362A2 firmware loaded. Bluetooth still attaches a few seconds into an
  already-booted system.
- **`h96-gaming-setup` retires after first boot.** Its completion flag was gated on a wine
  binary that v4.1 moved to fetch-on-demand, so it re-ran apt work on every boot. The flag
  now sets on the first successful boot and the service retires.
- **zram swap compression changed from lzo-rle to zstd**, and the VM sysctl tuning
  (`/etc/sysctl.d/zz-h96-tune.conf`) is baked into the image so it survives a fresh flash.
- **Flasher input validation.** Unrecognized menu input no longer advances to a flash; only
  the listed menu keys are accepted.

## v4.1

Shipped as three pre-built image variants, all booting to a text console:

- **v4.1** (full): KDE Plasma is not pre-installed. Install it on demand through
  `armbian-config`; first launch of Plasma applies the H96 desktop settings.
- **v4.1-NODESKTOP**: headless, no desktop-install capability.
- **v4.1-NODESKTOP-NOGPU**: headless, with the Mali GPU removed (driver blacklisted
  and GPU packages pruned) while the hardware video (VPU) path is kept.

Image free space is zeroed with `zerofree` before compression, so the zips are
smaller than earlier releases: about 1.22 GB (full), 1.01 GB (nodesktop), and
0.91 GB (nodesktop-nogpu).

1. Bluetooth headset MICROPHONE now works. Every earlier release could play audio
   to a Bluetooth headset but never capture its mic: stock kernel shipped no RFCOMM,
   so Hands-Free profile could not open and Bluetooth was pinned to A2DP-only.
   v4.1 ships `rfcomm.ko` built for this exact kernel (6.1.115), loads it before
   BlueZ, and re-enables Hands-Free / Headset roles. Headset mic shows up as an
   input source under a "Headset Head Unit" profile; apps that record can switch to
   it. Codec is CVSD (call quality, narrowband). Wideband mSBC negotiates with a
   headset but its audio link will not carry over this box's Broadcom UART Bluetooth
   radio, a hardware limit, so CVSD is the ceiling here. Selecting a headset-mic
   profile drops output to mono call quality until deselected; that is how classic
   Bluetooth works, not a bug.

2. Bluetooth headset profile now stays selected. WirePlumber used to revert a
   manually chosen Hands-Free (mic) profile back to A2DP whenever no application was
   recording, so a selected mic profile did not hold. v4.1 disables that autoswitch
   (`bluetooth.autoswitch-to-headset-profile = false`), so the chosen profile is a
   single coherent choice, input follows output, and it persists across reconnects.
   A2DP carries no mic (a classic Bluetooth limit), so a mic exists only under the
   Hands-Free profile.

3. AAC Bluetooth audio output. Headsets that advertise AAC now negotiate it instead
   of plain SBC. AAC plugin installs on first networked boot
   (`libspa-0.2-modules-extra`). Codec preference: LDAC, aptX-HD, aptX, AAC, SBC-XQ,
   SBC.

4. Bluetooth adapter reliability on boot. BlueZ could start before UART Bluetooth
   adapter finished attaching, then report no controller, so KDE showed no Bluetooth
   after some reboots. v4.1 orders BlueZ after adapter bring-up and waits for adapter
   node to appear.

5. Bluetooth boot fix for headless images. On the minimal (headless) base the SCO
   audio-routing service (`bt-sco-hci.service`) failed because the BlueZ `hcitool`
   CLI is only pulled in by the desktop install, so headless boxes booted
   `degraded`. The service now skips when that CLI is absent and still sends the SCO
   routing command on desktop images. An ordering race that let the routing command
   fire before the adapter finished attaching is also fixed: the service polls the
   adapter for `UP RUNNING` before sending, and retries the send.

6. USB game-controller dongles. The base kernel had no xpad driver, so X-input
   controllers and 2.4GHz pad dongles did nothing over USB; only D-input / HID pads
   worked. v4.1 ships xpad built for this kernel with an updated device table and
   vendor-wide matches for common controller makers, autoloaded, plus a udev
   catch-all that binds any X-input dongle even if its USB id is not in the table.

7. Media feature suite. All OPT-IN: the image ships the command only; each tool
   installs its packages and activates on first use, so a fresh flash carries no
   extra weight and nothing auto-starts.
   - h96-cec: control the box with the TV remote over HDMI-CEC.
   - h96-hdr: HDR10 tone-mapping to SDR in mpv (vo=gpu-next / libplacebo).
   - h96-motion: mpv built-in frame interpolation (judder reduction), on the GPU.
   - h96-npu-upscale: offline Real-ESRGAN x4 super-resolution on the NPU.
   - h96-audio-passthrough: HDMI bitstream (AC3 / DTS / E-AC3) + multichannel LPCM.
   - h96-audio-eq: system-wide parametric EQ via a native PipeWire filter-chain.
   - h96-bt-speaker: box as a Bluetooth A2DP speaker (pair a phone, audio to HDMI).
   - h96-cast: AirPlay audio + screen mirror + DLNA renderer (open Cast substitute).

8. Slimmer image. The wine + DXVK gaming stack (~206 MB) is no longer baked in;
   h96-game-mode fetches it on first use.

9. Experimental Steam installer removed. Steam under x86 emulation on RK3588 is
   unstable and too heavy for this box. Gaming path stays `h96-game-mode`
   (Windows games under wine + DXVK on open GPU).

10. Note for GameCube/Wii emulation: apt `dolphin-emu` is broken by this image's
    Qt 6.10, a Qt-internal fault that pins one CPU core at 100% and freezes its
    window. Use Flatpak Dolphin instead; it carries its own Qt and renders on GPU
    via PanVK.

## v4.0

1. Hardware video decode now works for desktop users and on fresh flashes. It was
   root-only in every earlier release, and fresh flashes could not install video
   stack at all.
2. Desktop lists connected display's native resolutions and refresh rates,
   updates list when a different display is plugged in. Off by default; enable with
   `sudo h96-display autodetect on`. `h96-display` also gains `auto`, `4k60`, and `8k`.
3. Monitor backlight control over DDC/CI: `h96-brightness`, plus desktop's own
   brightness slider.
4. `scrumptop`: a themed terminal system monitor built for this SoC.
5. Desktop lock screens authenticate. They could not in any earlier release.
6. NPU and hardware video encoder are exposed for first time
   (`h96-npu`, `h96-npu bench`, `h96-encode`), plus GPU upscaling (`h96-upscale`)
   and on-device subtitle generation (`h96-subtitles`).
7. CPU overclock and undervolt tools with measured results (`h96-undervolt`).
8. Screen wake: a blanked HDMI output that never returned on keypress is
   re-driven automatically (`h96-display-wake.service`; manual:
   `sudo h96-display wake`). See 2c.
9. Widevine L3 browser DRM, opt-in: `sudo h96-widevine-setup`
   fetches CDM on demand; DRM streams cap at SD (L3 hardware limit). See 8.
10. Display scale: `h96-scale <factor>` sets KDE global scale and applies it live
    (restarts Plasma shell); autologin enabled so a logout re-applies it. On
    X11 a log out/in is required for a scale change to reach all apps. Wayland
    not used (breaks GPU/compositing/mpv).

11. `h96-bench --gpu` renders on Mali GPU under X11. Earlier it invoked a
    Wayland-only glmark2 binary that cannot initialize an EGL canvas on this X11
    image, so `--gpu` printed "Could not initialize canvas" and reported no
    score. Now picks `glmark2-es2` on X11, `glmark2-es2-wayland` on Wayland.
    A progress-loop abort under `set -e` that ended runs early with no summary is
    also fixed, so the benchmark now shows live ticks and exits clean.
    Measured: Mali-G610 MC4 (Panfrost), GLES 3.1, 4111 FPS build scene at 1000 MHz.

### 1a. Hardware video decode was root-only

`/dev/dma_heap/*` is where MPP allocates decode frame buffers. It defaults to 0600,
root-only. Hardware decode initialization fails for non-root processes
(`Failed to init MPP context: -1`) and mpv falls back to software decode with no error
shown in UI. Root processes are unaffected. Prior validations of video stack ran
as root over SSH and did not encounter failure. Present in every release to date.

v4.0 ships a udev rule setting DMA heaps to `root:video 0660`. Desktop users are in
`video` group by default. Measured on hardware: same user and file changed from
`Failed to init MPP context: -1` to `Using hardware decoding (rkmpp-copy)`. CPU during
YouTube playback in browser-to-mpv path changed from 64% of one core to 15%.

**On any earlier release**, apply:

```
echo 'SUBSYSTEM=="dma_heap", KERNEL=="system*", GROUP="video", MODE="0660"' | \
  sudo tee /etc/udev/rules.d/99-h96-dma-heap.rules && sudo udevadm trigger
```

Note: `--vo=gpu --hwdec=rkmpp` (zero-copy display) does not engage on this X11/mpv stack
and results in software decode. Shipped `rkmpp-copy` profile remains in use.

### 1b. Hardware video was broken on every fresh flash

**This is highest-impact fix in v4.0, and it affects v3.4 as well.**

On a fresh flash, **both mpv and ffmpeg failed to start**:

```
ffmpeg: error while loading shared libraries: libXv.so.1
!!! mpv not runnable after setup (still missing: libass.so.9 libplacebo.so.360
    libXv.so.1 libXpresent.so.1) - NOT setting done flag; will retry next boot
```

**Cause.** `h96-video-setup.sh` installs mpv/ffmpeg runtime libraries from offline
repo in `/opt/h96-pkgs`, deliberately scoped to that repo alone. Repo shipped
`libfontconfig1` **without its dependency `fontconfig-config`**. apt installs atomically, so
that single unsatisfiable package caused apt to drop **all thirty** packages with no error surfaced. Script
correctly noticed and refused to mark itself done, then retried every boot and failed
same way, indefinitely.

**Fix.** `fontconfig-config` is now included in offline repo, with a correctly generated
`Packages` entry. Its own dependency (`fonts-dejavu-core`) was already in image, so that
one package completes chain. Also: offline repo is now pinned low (priority 1) so its packages, some of which exist online at same version (fontconfig-config, usb.ids), are no longer offered as phantom updates in Discover that never finish. It stays fully usable for offline first-boot install.

**Verified on a fresh flash with nothing done by hand:** mpv v0.41.0 starts, ffmpeg starts,
three hardware encoders present, and `h96-video-setup` finally sets its done-flag and skips on
following boot.

**If you are on v3.4** and hardware video does not work, this is why. Either update to v4.0 or
run once:

```bash
sudo apt update && sudo apt install -y fontconfig-config libass9 libplacebo360 libxv1 libxpresent1
```

**Why it went unnoticed for so long:** every earlier test ran on a box where other packages had
been installed by hand, which pulled `fontconfig-config` in as a side effect. It only shows on a
clean flash.

### 2a. Display autodetect (opt-in): native mode lists

Kernel cannot read a display's EDID (DDC controller defect), so desktop lists only
baked default modes. `sudo h96-display autodetect on` turns on native-mode
enumeration: a service reads attached display's EDID over `i2c-ddc` bus and places
it for desktop to read, and a udev rule re-reads it on cable hotplug. It enumerates
modes only and never switches output: it strips EDID's color-format bits (YCbCr,
deep color, HDR) so driver stays RGB 8-bit, sets preferred timing to 1080p60 so
first login is safe, and never forces a re-detect or modeset. Live output is never
re-driven, so it cannot tint or blank screen. Reboot after enabling so desktop
reads new mode list, then pick a mode; KDE remembers it per display. OFF by
default (box runs forced 1080p60); `sudo h96-display autodetect off` reverts.
Measured on a 2560x1440@144 monitor: native mode list present, output stays clean.
`h96-display` also gains `4k60` and `8k` presets (`8k` is unproven: needs HDMI 2.1 FRL
output, an 8K display, and a certified cable).

**Choosing a refresh rate.** When autodetect is on and you pick a higher resolution in
Display Settings, also set refresh rate HDMI cable can carry. High refresh rates
(120 Hz, 144 Hz) and 4K at 60 Hz need a Premium High Speed or Ultra High Speed HDMI cable;
a standard or TV-grade cable may show a black screen at those rates while working at 60 Hz.
On this box, 2560x1440 at 60 Hz was confirmed over a standard cable; 120/144 Hz and
4K at 60 Hz require a certified cable. KDE reverts an unconfirmed mode after 15
seconds, so a wrong pick returns to previous mode. Known limit: enabling autodetect
can disable HDMI audio (audio path reads capabilities from boot EDID, which
autodetect replaces). If sound disappears, run `sudo h96-display autodetect off`
and reboot; audio returns.


### 2b. `h96-display auto` reads display's EDID

SoC's HDMI DDC i2c controller never completes a transaction on this kernel, which is
why this image forces a display mode. DDC wires work: stock Android reads EDID over
them. `sudo h96-display auto` reads EDID over `i2c-ddc` kernel bus created by
brightness overlay, falling back to a direct GPIO read (character-device uAPI) when that
bus is absent. It validates EDID (header, per-block checksums), picks display's preferred mode capped at
this box's limits, and sets it through existing one-boot trial and `keep`
confirmation. On any read or parse failure current mode is left unchanged. Measured
on hardware: a 256-byte read takes 1.5 s at a 2 kHz bit-banged clock and does not disturb
running display; 5 consecutive reads were byte-identical. Reader source:
`packages/bsp/h96-max-v58/src/ddc-edid-read.c` (image ships it precompiled).

### 2c. Screen wake: HDMI re-drive on keypress

Once HDMI output is dropped (X starting while monitor is asleep, or a hotplug
while blanked), BSP kernel never re-initialises PHY/VOP path on its own:
connector sits `connected` / `enabled=disabled`, kernel logs `User-defined
mode not supported` on re-probe, and a keypress shows nothing while box stays
SSH-reachable. Box never suspends (Armbian base masks suspend targets; RK3588
BSP suspend does not resume), so a dark unresponsive screen is always this
output-drop state, not sleep. Fix: `h96-display-wake.service` watches input
devices; on a key or button press while connector is connected but disabled,
it re-drives output with an explicit X modeset at forced boot mode plus
`xset dpms force on`. A udev rule runs same check after a hotplug
(`HOTPLUG=1`). Normal blanking is untouched: healthy DPMS keeps
`enabled=enabled` and daemon acts only in broken state. Manual trigger:
`sudo h96-display wake`. Measured: broken state forced via `xrandr --off`,
one injected keypress, picture back in about 4 s (`hdptx phy lane locked`,
`vop enable intf`, journal `re-drove HDMI-1 (1920x1080@60)`).

### 3. Monitor brightness over DDC/CI

`h96-brightness` sets a connected monitor's backlight over DDC/CI (VCP 0x10), not a
software gamma dim. SoC's HDMI DDC i2c controller does not complete transactions on this
kernel, so `h96-ddc-i2c-gpio` device-tree overlay (enabled by default) exposes two
DDC pins (GPIO4_B7=SCL, GPIO4_C0=SDA) as a kernel i2c-gpio bus named `i2c-ddc` at 100 kHz,
and ddcutil drives DDC/CI over it. 100 kHz rate is required: at 2 kHz monitor's
DDC/CI controller could not clock value bytes and writes failed verification. Measured on a
Dell P2419H: brightness set to 30/75/15/60 tracked exactly with on-screen change. ddcutil installs
automatically at first boot. Display must accept DDC/CI writes (most
PC monitors; enable "DDC/CI" in monitor menu). Most TVs gate DDC/CI behind an HDMI/CEC
handshake this box cannot perform and are not controllable. With KDE plus ddcutil, PowerDevil
shows a brightness slider. Overlay source: `packages/bsp/h96-max-v58/overlays/`; CLI:
`packages/bsp/h96-max-v58/tools/h96-brightness`. Because the overlay reassigns pins the HDMI
controller already holds, the kernel prints two `WARNING` traces from `pinctrl-rockchip.c`
(`rockchip_pmx_gpio_set_direction`, `pin 143 already requested by fde80000.hdmi` and `pin 144
already requested by fde80000.hdmi`) at boot. They are harmless; the kernel sets its `W` taint
flag and the bus works.

### 4. `scrumptop` system monitor

A terminal system monitor in project color scheme (purple frames; green/amber/red
load and temperature ramps). Panels:

- CPU: per-core bars using RK3588's non-contiguous topology (A76 = CPU1-4,
  A55 = CPU0,5,6,7); each bar carries its cluster's temperature gauge
- GPU and NPU (3 cores): load, frequency, temperature gauges
- Network: Ethernet link speed and byte rates, WiFi state and signal, Bluetooth state
  and connection count, IR remote last activity
- System: disk usage, eMMC I/O rates, swap, load average, uptime, and batteries of
  wireless peripherals that report one

Keys: `b` runs/stops 3-core NPU benchmark, `+`/`-` steps polling rate, `p` pauses, `h`
toggles help. `--snapshot` prints one frame and exits. Single file, Python standard
library only.

New command `h96-npu bench` runs an INT8 matmul through NPU runtime. Measured:
~625 GOPS one core; `h96-npu bench all` pins one job per core for ~1.29 TOPS across 3 cores. Requires runtime installed by `h96-npu-setup`.

Whole terminal is framed in theme: a wordmark badge in outer border, side
rails, and block wordmark set in green into a dark textured banner. Usage bars are
segmented; temperature gauges use a narrower glyph. Rendering is line-diffed (only changed lines
are rewritten each tick). Measured at a 1 s refresh: 0.66% of one core, 20 MB resident.

### 5. Desktop lock screens could not authenticate

Armbian base rootfs ships `/etc/shadow` owned `root:root`. Required ownership is
`root:shadow`: PAM helper `unix_chkpwd` is setgid `shadow` and reads file via
group permission. Display managers run as root and read file directly, so login
worked. Lock screens (Plasma, GNOME, XFCE) run as logged-in user, authenticate
through `unix_chkpwd`, and reject correct password. `useradd` and `chpasswd` preserve
existing group on rewrite, so ownership does not correct itself. Present in every
release to date. v4.0 images ship with group set to `shadow`.

**On any earlier release**, apply: `sudo chgrp shadow /etc/shadow`. Takes effect
immediately.

### 6a. NPU was already working; nothing ever asked it to do anything

Measured on hardware, with no patch applied:

```
[drm] Initialized rknpu 0.9.8 20240828 for fdab0000.npu on minor 1
RKNPU fdab0000.npu: rknpu iommu is enabled, using iommu mode
RKNPU fdab0000.npu: bin=0  leakage=8  pvtm=878  pvtm-volt-sel=3
```

| | |
|---|---|
| kernel driver | `RKNPU driver: v0.9.8` (build 20240828) |
| cores | 3, with live per-core load in `/proc/rknpu/load` |
| frequency | 1000 MHz, 8 OPPs from 300 MHz, governor `rknpu_ondemand` |
| DRM node | `card1` (`DRIVER=RKNPU`) → `/dev/dri/renderD129` |
| permissions | default user is already in `render`, so no root needed |

New command **`h96-npu`** reports all of it, watches per-core load live, and can pin
frequency to a specific OPP (validated against kernel's own OPP list, root only, resets
on reboot).

### 6b. Inference runtime is NOT bundled, deliberately

`librknnrt.so` is proprietary. It ships under Rockchip's **"RKNN SDK License"**, whose
clause 1.2 permits reproducing copies **"on an internal basis only"**. This image is
published publicly under GPL-2.0, so it cannot carry that binary, and build now
**fails on purpose** if file is ever found inside image.

New command **`sudo h96-npu-setup`** fetches it from Rockchip instead, showing you their
licence first. Verified end to end: it installs `librknnrt version: 2.3.2` against driver
v0.9.8, validates that download is an aarch64 shared object before installing
anything, and `--uninstall` removes it cleanly.

**Known limitation, stated.** Rockchip publishes `rknn-toolkit-lite2` wheels only
up to CPython 3.12. This image is Debian forky/sid with Python 3.14, so **those wheels will
not install against system interpreter**. C API works (`dlopen` and `rknn_init`
confirmed present); Python convenience layer needs a CPython ≤ 3.12 you bring yourself.
Model conversion (`.onnx`/`.pt` → `.rknn`) has always run on a PC, not on box.

### 6c. `could not find sram resource!` is expected here; do not "fix" it

NPU logs this at boot and it is **correct behaviour on this board**. RK3588 system SRAM
is already allocated in full to two video decoders, with no gap:

| region | offset | size |
|---|---|---|
| `sram@ff001000` total | | `0xEF000` (978,944 B) |
| `rkvdec-sram@0` | `0x00` | `0x78000` (491,520 B) |
| `rkvdec-sram@78000` | `0x78000` | `0x77000` (487,424 B) |

`0x78000 + 0x77000 = 0xEF000` exactly; zero bytes free. Giving NPU an SRAM region means
taking it from hardware video decode, which is whole point of a TV box. Rockchip's own
in-tree RK3588 device trees do not wire NPU SRAM either. NPU runs from DRAM and works.

A malformed `rockchip,sram` phandle here would be worse than warning: overlapping
rkvdec allocation hands same physical SRAM to two drivers, which is data corruption
with no error reported, rather than an immediate failure.

### 6d. Hardware video encode, exposed

Encode was enabled entire time and never surfaced: `RKVENC`/`RKVENC2`/`JPGENC` in
kernel, both `rkvenc-core` nodes `status = "okay"` in device tree, `/dev/mpp_service`
present, and bundled ffmpeg already carrying `h264_rkmpp`, `hevc_rkmpp` and
`mjpeg_rkmpp`.

This matters more than it sounds: **bundled ffmpeg has no `libx264`**, so before now
box had no working encode path at all despite shipping silicon for it.

New command **`h96-encode`**. Measured on an H96 Max V58: 1080p encoded **faster than
180 fps** on both H.264 and HEVC, faster than test's one-second timing granularity
could resolve.

```
h96-encode clip.mkv out.mp4                 # H.264, 8 Mb/s
h96-encode clip.mkv out.mp4 -c hevc -b 6M   # HEVC
h96-encode clip.mkv small.mp4 -s 1280x720   # hardware scale, then encode
h96-encode --list                           # what this build can encode
```

### 6e. GPU upscaling

New `h96-upscale` enables **ravu-lite-ar-r4** (bjin/mpv-prescalers, LGPL-3.0) as an mpv user
shader on Mali-G610 through Panfrost.

Measured on this board, 720p clip, `--untimed`: **3.81 s → 4.31 s, about 10-13% more GPU
time**, compiling clean with zero GLSL errors. `on`/`off` edit a marked block in
`/etc/mpv/mpv.conf` and restore it byte-for-byte.

Two findings worth recording, because both contradict obvious guess:

- **`gather/` variant does not work here.** It needs `textureGatherOffset`, which this
  GLES context does not provide (`error: no function with name 'textureGatherOffset'`).
  *root* variant is one that compiles, even though this context also reports
  `compute shaders=0`, which would normally point other way.
- **FSRCNNX and nnedi3 are not viable on this GPU.** G610 measures around 470 GFLOPS,
  roughly 9-19× below cards those shaders are usually demonstrated on.

It needs a desktop or compositor session; image boots headless. `h96-upscale test` falls
back to `cage` when no session exists, but **cage does not engage rkmpp hardware decode**, so
that path measures shader cost only, not playback; hardware-decode coexistence with
shader is therefore still unverified under a desktop session.

### 6f. Subtitles: `h96-subtitles`

Offline speech-to-subtitles, producing a timed `.srt` from any media file.

**Measured here:** RTF **0.130** (7.7× realtime) on film audio using **one** A76 core, a
2-hour film in ~15 minutes with seven cores left free. **WER 1.09%** on LibriSpeech test-clean
against human transcripts; coherent and usable on 1936 film dialogue with music.

**It was built for NPU, and NPU lost.** Measured on same audio: NPU (3 cores)
RTF **0.271** against **0.124** for a single A76 core; CPU is **2.2× faster than whole
NPU**, and four threads (0.147) are slower than one. Limit is memory bandwidth, exactly as
with overclock and NPU LLM work. `--engine npu` remains available for comparison.

Engine and model are fetched by `sudo h96-subtitles-setup`, not bundled: both are
Apache-2.0, but they total ~340 MB. A **prebuilt** binary is used, so no compiler is required.
Downloads are SHA-256 recorded and re-verified.

`h96-subtitles live` exists but is **experimental and unfinished**. Streaming ASR measured
2.5× realtime and mpv overlay renderer is protocol-verified, but live capture needs a
desktop session (no PipeWire on headless image) and a display. It refuses with actionable
errors rather than pretending.

### 7. CPU tuning, measured

`h96-undervolt oc` adds a 2400 MHz operating point (vendor tree stops at 2208). It is
offered because it works and is safe to try, **not** because it is worth keeping.

**Measured on this board**, on a correct 12 V supply, `sysbench cpu` with 4 threads pinned to
big cores, 3 alternating reps, 3 s settle, clock verified *mid-run*:

| rep | 2208 MHz | 2400 MHz |
|---|---|---|
| 1 | 3729.50 | 3750.15 |
| 2 | 3731.47 | 3749.88 |
| 3 | 3730.63 | 3750.58 |
| **mean** | **3730.5** | **3750.2** |

**+8.7% clock produced +0.53% work**, and peak temperature rose 82 °C → 85 °C. 2400 MHz was
stable at **975 mV** and clock was sustained, confirmed by live sampling and by
`time_in_state` (13442 ticks at 2400 against 812 at 2208). It does not help: a
compute-bound workload that ought to scale with clock doesn't, because limit on this SoC
is memory bandwidth (~21 GB/s), not core frequency.

**Two measurement traps, both of which produced wrong answers first:**

1. **Pin to big cores.** An 8-thread run shows ~0% because this SoC is 4× A76 + 4× A55,
   A55s are unchanged at 1800 MHz, and they gate total. Topology is **not
   contiguous**: `policy0` is cpus **0,5,6,7** (A55s), and big cores are **1,2,3,4**:
   ```
   taskset -c 1,2,3,4 sysbench cpu --threads=4 --time=15 run
   ```
2. **Let it settle, and verify clock during run.** A first attempt gave 2829 vs 3724
   for *same* 2208 setting: 32% variance from thermal and residual load, far larger than
   effect being measured.

**Useful direction is opposite one.** 2400 MHz ran stable at 975 mV while vendor
assigns 962.5 mV at 2208 for this chip, so there functions voltage headroom at stock speed.
Undervolting buys lower heat and power at identical performance, which on a fanless box is
worth more than any clock increase.

Both `set` and `oc` edit same device tree, so only one can be active at a time, and each
arms a trial that self-reverts on next boot unless you `confirm`.

**Undervolting: also tested.**

Sweep was run on a correct 12 V supply, at stock 2208 MHz, each offset applied fresh from
stock and rebooted before testing. **Every offset was stable, up to tool's −50 mV cap**
(cluster1 is bin L4 at 962500 µV against a 912500 µV vendor floor).

Stability was not useful question. A thermally-matched comparison (both runs cooled to
55 °C first, clock pinned and verified at 2208 MHz under load) says this:

| | voltage | clock | start | end | events/s |
|---|---|---|---|---|---|
| stock | 962 / 975 mV | 2208 MHz | 56 °C | 64 °C | **3758.40** |
| −50 mV | 912 / 925 mV | 2208 MHz | 56 °C | 63 °C | **3594.62** |

**−50 mV costs 4.4% performance to save 1 °C.** Sweep's own trend corroborates it
independently (−10 mV → 3741, −50 mV → 3587), and gap is far outside ±0.03%
repeatability measured elsewhere. *Why* same verified clock does less work at lower voltage
is unexplained; it is recorded as an observation, not a theory.

**Taken together, stock is right setting.**

| change | performance | thermal |
|---|---|---|
| overclock to 2400 MHz @ 975 mV | **+0.53%** | +3 °C |
| undervolt −50 mV @ 2208 MHz | **−4.4%** | −1 °C |

Both directions are net-negative on this hardware. Tools exist so you can verify that for
yourself on your own chip (silicon varies), but on this one vendor's settings win.

**If you repeat this, four traps.**

1. **`revert` does not take effect until you reboot.** Running kernel keeps device tree
   it booted with, so a "stock" reading taken straight after `revert` is still *old* tree.
   This made stock and −50 mV look identical during testing and nearly produced opposite
   conclusion.
2. **In `regulator_summary`, field 5 is `opmode` and field 6 is voltage.** Reading field 5
   yields useless string `normal`.
3. **Read voltage under load with clock pinned.** It tracks current operating point,
   so at idle it reads low no matter what you set.
4. **Cool to a matched temperature between runs.** Consecutive runs heat-soak, and drift is
   larger than effect being measured.

### Appendix: branding

Block-letter header is now a single shared library on box
(`/usr/local/lib/h96/banner.sh` and `.py`) rather than pasted into each script, with two
distinct wordmarks: **Scrumpper's Firmware Suite** for flashers and installer, and
**Scrumpper's Unofficial Armbian** for on-device tools. It stays TTY-gated, so
scripts that also run from systemd units print nothing into journal.

### Appendix: HDMI DDC, investigated, controller still unfixed

Intended headline for this release was making board read display's EDID,
which would have removed forced mode, substitute EDID and their boot cost. **It did
not work, and record is worth more than a quiet omission.**

Every layer of DDC path was verified *correct*: VO1_GRF routing
(`VO1_CON3 = 0x00002e00`), pin mux (`hdmim0`, GPIO4_B7/C0, identical pins all three
stock Android device trees use, on a box where Android reads EDID fine), absence of any
pin conflict, SCL timing (`clk_hdmitx0_ref` 428.57 MHz → exactly 100 kHz), slave
address, and interrupt unmasking. Yet i2c read never completes and returns neither
DONE nor NACK.

One plausible fix was tested and **refuted cleanly**: raising DDC completion timeout from
`HZ/10` to `HZ` scaled wait from 102 ms to 1.013 s, proving patch was live, and
changed nothing: EDID still read 0 bytes, timeouts unchanged. Giveaway was that i2c
interrupt still arrived ~109 µs *after* timeout at **both** deadlines: a constant offset
from deadline rather than from transfer start means that interrupt is generated by
timeout handler's own controller reset, not by a late completion. Do not ship `HZ`: 54
timeouts at 1.013 s each add roughly 55 seconds to boot.

So v3.4's approach stands: a forced mode, and HDMI audio works. But measuring a **fresh
flash** of v4.0 corrected *why* it works, and earlier explanation was wrong.

### Appendix: correction, substitute EDID never loads

On a freshly flashed box kernel reports:

```
platform HDMI-A-1: Direct firmware load for edid/h96-1080p-audio.bin failed with error -2
[drm:edid_load] *ERROR* Requesting EDID firmware "edid/h96-1080p-audio.bin" failed (err=-2)
```

Blob is present in rootfs (256 bytes, CTA block intact), but DRM probe runs at
about 4.1 s, while system is still on initramfs, and that initramfs contains **zero**
`lib/firmware` entries. `request_firmware()` therefore cannot find it, on v3.4 or v4.0.

`drm_edid_load.c` explains difference from v3.3 exactly. It matches requested name
against an in-kernel table before ever touching filesystem:

```c
/* drivers/gpu/drm/drm_edid_load.c:180 */
builtin = match_string(generic_edid_name, GENERIC_EDIDS, name);
if (builtin >= 0) { fwdata = generic_edid[builtin]; ... }   /* no filesystem needed */
```

- v3.3 used `edid/1920x1080.bin`, which **is** in that table, so it loaded, as a 128-byte
  blob with no CTA block, giving `OPMODE_DVI` and no sound.
- v4.0's `h96-1080p-audio.bin` is **not** in that table, so it needs file, and file
  is unreachable that early. Result is **no EDID at all**, which takes driver's
  permissive fallback (`support_hdmi = true`, `sink_has_audio = true`).

So audio works because there is **no** EDID, not because there is a better one. Verified on a
fresh v4.0 flash: `PHY: enabled  Mode: HDMI`, HDMI PCM present, 0 failed units.

**Consequence:** `drm.edid_firmware=` argument is currently a no-op and could be dropped
with identical behaviour, minus two error lines in `dmesg`. It has deliberately **not** been
changed in v4.0: audio works today, and altering a working boot path to tidy up log noise is
not worth risk. Noted here so next person does not "fix" it by shipping a built-in
EDID name, which is precisely what broke audio in v3.3.

### 8. Widevine L3 setup, opt-in (browser DRM)

Google ships no Widevine CDM for generic ARM64 Linux, so browser DRM streams
(Discovery+, Netflix, Prime, Disney+) cannot play on this image by default.
`sudo h96-widevine-setup` fetches AsahiLinux `widevine-installer` (MIT), which
downloads a Chrome (LaCrOS) image from Google (about 150 MB), extracts ARM64
L3 CDM, applies its glibc ELF fixups, and installs to `/var/lib/widevine`; tool
then wires Chromium (system-wide bundle dir, all users) and Firefox
(`MOZ_GMP_PATH`). CDM is proprietary and never bundled in this GPL-2.0 image;
it is fetched on request, same policy as `h96-npu-setup`. LIMIT: this box is
Widevine L3 on every firmware, Android included; DRM streams cap at SD
(~480p) and no firmware changes that. `status` and `remove` subcommands
included. Verified on hardware: Chromium registers bundled CDM 4.10.2662.3 system-wide, Discovery+ plays at SD. Check other services at https://bitmovin.com/demos/drm.

## v3.4 (released as a pre-built image; EDID below IS reproducible here)

**⚠️ If you followed v3.3 instructions below, HDMI audio is disabled on your build.
Apply this instead.**

v3.3 told you to add `drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin` to stop HDMI EDID
retry storm. It does stop storm, and it also **disables HDMI audio without any log message**. Video is
unaffected, so it does not look like a display problem at all.

**Why.** Every EDID blob compiled into kernel (`drivers/gpu/drm/drm_edid_load.c`,
`generic_edid[]`) is 128 bytes with **no CTA/CEA extension block**. HDMI audio capability is
declared in that block. With no CTA block, `drm_detect_hdmi_monitor()` returns false,
driver sets `sink_is_hdmi = false`, and `dw_hdmi_qp_setup()` then programs `OPMODE_DVI`,
which drops every data island: audio sample packets and infoframes alike.

Note consequence: **having no EDID at all is better than having one that declares no
audio.** With no EDID driver takes an explicit fallback that sets `support_hdmi = true`
and `sink_has_audio = true`. V3.3 argument moved board out of that fallback.

Measured on hardware, same board and display, changing only this argument:

| | kernel built-in `1920x1080.bin` | no argument | `h96-1080p-audio.bin` |
|---|---|---|---|
| dmesg | `dw_hdmi_qp_setup DVI mode` | tmds mode | tmds mode |
| `/sys/kernel/debug/dw-hdmi0/status` | `PHY: disabled` | `PHY: enabled  Mode: HDMI` | `Mode: HDMI` |
| ELD | `SAD_Count=0` | zeros | `SAD_Count=1`, LPCM 2ch |
| HDMI audio | **none** | works | works |

**Fix.** This repo now ships a 256-byte EDID that declares 1080p60 plus an HDMI VSDB and
an LPCM audio descriptor:

```
packages/bsp/h96-max-v58/edid/h96-1080p-audio.bin
```

Install it to `/lib/firmware/edid/h96-1080p-audio.bin` (mode 0644) and use:

```
drm.edid_firmware=HDMI-A-1:edid/h96-1080p-audio.bin
```

Keep existing `video=HDMI-A-1:1920x1080@60` argument alongside it.

**Do not put this file in initramfs.** It is tempting, because loading it earlier would
also recover about 1.85 seconds of startup, and file otherwise loads only on
post-rootfs connector reprobe (you will see two `Direct firmware load ... error -2` lines
before it succeeds). An earlier version of this project tried exactly that and **box
would not boot**: this U-Boot and kernel will not boot a uImage `uInitrd` with a prepended
early cpio, and connector probe fails before root filesystem is mounted. Leave
`uInitrd` alone and accept startup cost.

**Why not drop argument.** Retry storm is not only a startup cost. DRM
connector hotplug poll keeps retrying for as long as board is powered. Measured: with no
argument, 108 timeouts by 99 seconds and still climbing at roughly one per second; with this
EDID, 19 timeouts, and it stays at 19.

## v3.3 (superseded by v3.4: boot argument below disables HDMI audio, see above)

An efficiency pass on top of v3.2. Most of it is root filesystem configuration and so is
not reproducible from this repo, with **one exception that is**: HDMI boot argument.

- **HDMI EDID retry storm removed (boot argument, applies to builds from this repo).**
  This board does not route HDMI DDC lines through to display controller, so
  kernel's attempt to read monitor's EDID can never succeed. It retried 18 times on
  every boot before giving up, then used resolution already set in boot
  configuration anyway. Measured cost: 18 timeouts, and kernel startup time of 4.26s.

  Add this to `extraargs` in `/boot/armbianEnv.txt`:

  ```
  drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin
  ```

  **⚠️ DO NOT USE THIS LINE. It disables HDMI audio.**
  Use `edid/h96-1080p-audio.bin` instead, see v3.4 above.

  `edid/1920x1080.bin` is one of EDID blobs compiled into kernel
  (`drivers/gpu/drm/drm_edid_load.c`), so no firmware file is loaded and there is no root
  filesystem or initramfs dependency. Kernel confirms this by logging
  `Got built-in EDID`, not `external`. Result: 18 timeouts drop to 1, and kernel startup
  time drops to 2.58s.

  Note there is no `ddc-i2c-bus` property on HDMI node to fix instead; driver uses
  an internal DDC controller. This is a boot argument, not a device tree change.

  Setting a resolution still works exactly as before. `video=HDMI-A-1:...` overrides
  forced EDID: verified by booting `video=HDMI-A-1:1280x720@60` alongside it, which set
  display controller clock to 74440000 and advertised 1280x720.

Remaining v3.3 changes are root filesystem only and are not reproducible from this
repo: CPU governor and frequency floor defaults, moving a package retry service off
startup path, and desktop package selection. See pre-built image's own CHANGELOG.md.

## v3.2 (released as a pre-built image; not yet reproducible from this repo)

A pass over faults that appear once a desktop environment is installed and
used day to day, on top of v3.1:

- **Software installation (Discover) works.** Three separate faults: no polkit
  agent was running, no rule authorized `sudo` group, and polkit's socket
  helper requires `SO_PEERPIDFD` (Linux 6.5+), which 6.1 vendor kernel does
  not provide, so every password prompt failed. Reported and partly diagnosed by
  **MetallixX974** in
  [issue #2](https://github.com/Scrumpper/H96_MAX_V58_Unofficial-Armbian/issues/2).
- **Bluetooth audio.** A2DP connects, and HCI UART is raised from its 115200
  baud default to 3 Mbps after attach, which stereo audio requires. LDAC, aptX HD
  and aptX are enabled alongside SBC.
- **HDMI audio** is default output; S/PDIF remains available.
- **WiFi works on a fresh install.** Radio came up rfkill soft-blocked with nothing
  in image clearing it, so `wpa_supplicant` could never associate and dhcpcd refused
  to start. `systemd-rfkill` persists unblocked state across reboots, so only
  freshly flashed boxes were affected. WiFi unit now runs
  `rfkill unblock wifi` before starting.
- **WiFi** uses a standalone `wpa_supplicant` with a tray applet, because
  NetworkManager cannot complete this chip's multi-AKM association.
- **Hardware video** completes its first-boot setup headless, with no desktop
  installed.
- **Desktop installs keep tier** (`minimal` / `mid` / `full`) chosen in
  `armbian-config`, instead of upgrading every install to `kde-full`.
- **Mesa/Panthor userspace stack is pinned**, so `apt upgrade` cannot move it
  to a version that breaks GPU acceleration.

**Scope.** All of above is userspace: systemd units, package selection and
first-boot scripts. None of it touches kernel, device tree or BSP package
published here, so building from these sources reproduces v3.1 feature set
(open GPU, WiFi 6, hardware video, front panel), not v3.2.

## v3.1
- **Working front-panel VFD.** Added `h96-vfd` daemon (`packages/bsp/.../src/h96-vfd.c`
  + `h96-vfd.service`): shows clock (HH:MM + blinking colon) and lights
  Ethernet / WiFi / USB / play status icons from live system state. Panel is a
  **TM1650** driven by bit-banging GPIO3. See comments in `h96-vfd.c`.

## v3: open GPU + WiFi + reduced boot output
- **Open Mali GPU (Panthor).** Dropped closed vendor Mali blob for open
  **Panthor** kernel driver + **Mesa (Panfrost + PanVK)**. GPU-composited KDE/GNOME
  desktop, open **Vulkan (PanVK 1.4)**, GPU at up to **1000 MHz**. Requires
  device-tree `gpu-supply` + `CLK_GPU` + OPP changes (see `docs/DEVICE-TREE-CHANGES.md`)
  and `QT_XCB_GL_INTEGRATION` / `KWIN_COMPOSE` environment settings.
- **Onboard WiFi 6.** Enabled **PCIe BCM43752 / AP6275P** (802.11ax), running
  simultaneously with Ethernet. Enable `pcie2x1l0`, disable vestigial `&sdio`
  node, pair with `bcmdhd` PCIe (or mainline `brcmfmac`) + firmware.
- **Hardware video** via mpv + Rockchip MPP (VPU decode).
- **Reduced boot output.** Disabled unused `es8311` codec + `i2s0` sound, dropped
  serial `dmas` that emitted repeated errors, and lowered kernel log level
  (`printk 3 4 1 7`, `loglevel=3`).
- **IR** as a userspace-learnable `gpio-ir-receiver` overlay (see `patch/overlays/`).

Earlier revisions (v1/v2) were vendor-blob GPU builds and are superseded by v3.
