# Media feature suite + USB controllers (v4.1, plus v5.0, v5.0.1 and v6.0 additions)

All OPT-IN. Image ships tools + configs only; each tool installs its
packages on demand and activates services on first `enable`. Nothing auto-starts.
Sources under `packages/bsp/h96-max-v58/` (tools/, lib/, systemd/, udev/, mpv/,
wireplumber/, pipewire/, etc-h96/, modules-load.d/).

## Tools

- **h96-cec** - HDMI-CEC: control box with TV remote. Daemon (lib/h96-cecd)
  maps CEC remote keys to uinput events. Needs /dev/cec0 from dw-hdmi-qp CEC
  block + v4l-utils/cec-utils (installed on enable). BOX-VERIFIED NON-FUNCTIONAL: this
  6.1 BSP kernel has CEC core (CONFIG_CEC_CORE) but does NOT build DesignWare HDMI
  CEC driver (no CONFIG_DRM_DW_HDMI_CEC, no /sys/class/cec), so /dev/cec0 never appears.
  Tool self-reports this. Fixing it needs kernel rebuild with dw-hdmi(-qp) CEC
  driver + DT wiring; not userspace fix.
- **h96-hdr** - mpv HDR10 handling: tone-map HDR10 to SDR via vo=gpu-next/libplacebo
  (reliable path; true passthrough is X11-limited on this stack).
- **h96-motion** - mpv BUILT-IN frame interpolation (judder reduction), GPU-side,
  zero deps. SVP/MVTools "soap-opera" path is intentionally not used:
  vapoursynth + mvtools have no arm64 build in box repos.
- **h96-npu-upscale** (+ **-setup**) - offline Real-ESRGAN x4 super-resolution on
  RKNPU. See below.
- **h96-audio-passthrough** - HDMI bitstream (AC3/DTS/E-AC3) + multichannel LPCM to
  AV receiver.
- **h96-audio-eq** - system-wide parametric EQ via native PipeWire filter-chain
  (no extra deps) + AutoEQ presets in /etc/h96/eq/presets/.
- **h96-bt-speaker** - box as Bluetooth A2DP speaker: pair phone, audio out HDMI.
- **h96-cast** - AirPlay audio (shairport-sync) + screen mirror (uxplay) + DLNA
  renderer (gmediarender). AirPlay 2 downgrades to AirPlay 1 (nqptp has no arm64
  build). Google Cast reception is not openly possible; DLNA is substitute.
- **h96-transcode-server** - opt-in network HARDWARE transcode node. Drop video into
  /srv/h96-transcode/in (over SFTP, or Samba/NFS-export folder); VPU transcodes
  it (rkmpp hw decode + hw encode) to /srv/h96-transcode/out and moves original to
  done/. Box-measured ~7.5x realtime at 1080p (30 s clip in ~4 s) with CPU idle. NO
  extra packages - it reuses image's rkmpp ffmpeg + /dev/mpp_service, so it adds no
  weight. Ships DISABLED: `sudo h96-transcode-server enable`. Settings in
  /etc/h96/transcode.conf (codec hevc/h264/mjpeg, bitrate, container, optional scale).

## Hardware cursor during GPU compositing (v6.0)

Hardware cursor under continuous GPU compositing is handled at kernel driver level in
v6.0. VOP2 cursor driver fix re-asserts cursor on video-port latch each frame, so
hardware cursor stays visible during continuous GPU compositing (fullscreen video, animated
browser pages, desktop splash); it still auto-hides over video and returns on movement, and
it stays correct after leaving mpv for desktop. `/etc/mpv/mpv.conf` uses
`cursor-autohide=1000` with `x11-bypass-compositor=never`: autohide is active during playback
and KWin compositing stays on in fullscreen. Earlier releases kept cursor visible during
playback (`cursor-autohide=no`) because VOP2 cursor plane was not restored after it was
hidden, leaving pointer invisible until reboot.

## USB game-controller dongles (xpad)

Base kernel had no xpad, so X-input controllers and 2.4GHz pad dongles did
nothing over USB. Enabled via CONFIG_JOYSTICK_XPAD=m (kernel config) + autoload
(modules-load.d/xpad.conf and systemd/h96-rfcomm.service, which runs depmod for
running kernel and loads rfcomm and xpad) + udev catch-all (udev/99-h96-xpad.rules) that
force-binds any X-input-interface device to xpad. D-input/HID pads already worked.

Since v6.0 module is built with CONFIG_JOYSTICK_XPAD_LEDS=y and CONFIG_JOYSTICK_XPAD_FF=y.
2.4 GHz X-input dongles that wait for Xbox 360 player-LED command before they start
reporting need LED support: without it dongle enumerates, driver binds and
/dev/input/js0 exists, but no input arrives (same pad works over Bluetooth). Verified
with 8BitDo Ultimate 2C Wireless Controller and its dongle. Force feedback (rumble) is
available on xpad-driven controllers. Kernel Image is unchanged by this; only
module set changed.

## NPU upscaling: how it works and how to use it

`h96-npu-upscale` is OFFLINE / BATCH upscaler, not live playback. One Real-ESRGAN
tile inference on NPU is ~100 ms, so full frame is seconds and clip is
minutes. Use it for stills and short low-res clips.

Mechanism:
- Real-ESRGAN x4 model (realesrgan_x4_96.rknn, 96x96 -> 384x384). Fetched on demand
  (~58 MB, MIT) into /var/lib/h96/upscale/models/ by h96-npu-upscale-setup.
- Talks to Rockchip runtime librknnrt.so directly via ctypes (C API) -
  rknnlite Python wheel only builds for CPython <= 3.12, so it is not used.
- Images are cut into overlapping 96x96 tiles, each upscaled on 3-core NPU, then
  feather-blended back together to hide seams.
- Video shells out to box ffmpeg: split to frames, upscale each, reassemble with
  hardware encoder (hevc_rkmpp) and copy audio.

Use:

    h96-npu-setup                 # once: fetch RKNN runtime (librknnrt.so)
    h96-npu-upscale-setup         # once: fetch + verify model
    h96-npu-upscale in.png out.png            # upscale image (x4)
    h96-npu-upscale clip.mp4 out.mp4          # short clip (slow: minutes)
    h96-npu-upscale --info                    # show NPU + model info
    # options: --overlap 16  --max-frames 900  --model PATH

## Android in container: h96-waydroid (v5.0)

`h96-waydroid` runs full Android system in LXC container that shares host
kernel (Waydroid 1.6.2). It is OPT-IN like everything else here: image ships
command, nothing else.

Why it needs v5.0 kernel:
- Android 11 and later `init`/`lmkd` hard-require `/proc/pressure`. Stock BSP kernel
  built PSI out, so container came up and then died in about 15 seconds. v5.0 rebuilds
  kernel with `CONFIG_PSI=y` (`PSI_DEFAULT_DISABLED` off) from armbian/linux-rockchip
  `rk-6.1-rkr5.1`, commit `95e85f6c`. Binder (`CONFIG_ANDROID_BINDER_IPC`/`BINDERFS`) is
  built in as well. `h96-waydroid status` verifies both.
- V5.0 build was Image-only, with kernel release string unchanged at 6.1.115 and
  vendor modules kept. As of v6.0 release string is `6.1.115-h96` and full
  module set is rebuilt from same source and configuration as Image with
  `CONFIG_MODVERSIONS=y`; modules live in `/lib/modules/6.1.115-h96`. Existing install
  cannot `apt upgrade` into either kernel; it needs new image.

Image profiles:
- `init gapps|vanilla` - official Waydroid LineageOS 20 image
  (`lineage-20.0-20260403-VANILLA-waydroid_arm64`, Android 13, vendor type MAINLINE, about
  900 MB). This is DEFAULT and recommended profile, and it wires Mali-G610:
  `drm_device=/dev/dri/renderD130`, `ro.hardware.gralloc=gbm`, `ro.hardware.egl=mesa`, with
  `renderD130` and `card2` nodes bound into container. Measured on box:
  `dumpsys SurfaceFlinger` reports
  `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`; GPU load reads
  `0@300000000Hz` at idle, reaches 50 percent at 1000 MHz under UI activity, and sits at 19
  to 26 percent at 600 MHz. `boot_completed=1` with session ready in about 8 seconds.
  Android 13 is cgroup v2, so no cgroup v1 shims are applied, and window follows
  Weston output size.
- `init gpu` - LEGACY, kept for anyone holding that stashed image: third-party
  Panthor-in-image Android 11 build (LineageOS 18.1, about 5 GB) that you supply. Measured
  on box: `GLES: Mesa, Mali-G610 (Panfrost), OpenGL ES 3.1 Mesa 24.0.5`, GPU load 27 to
  41 percent at 300 to 700 MHz. Against official image it is older Android (11 against
  13), older Mesa (24.0.5 against 26.0.1), unsigned, and abandoned since April 2024 (author
  WillzenZou, repos frozen). It needs cgroup v1 tmpfs shims (`/acct`, `/dev/stune`,
  `/dev/cpuset`, `/dev/memcg`), pins itself to 960x512 display that has to be overridden,
  and Vulkan never worked on it.
- `init custom <dir>` - your own image. It must be arm64 Waydroid-style `system.img`
  plus `vendor.img` PAIR; ROM zip, OTA payload or plain GSI will not boot.
- `hw off` forces software rendering, as diagnostic and fallback; `hw on` re-applies
  GPU wiring and verifies it.

Images are about 900 MB for official Android 13 build and up to 5 GB for
user-supplied one, are NOT bundled with release, and are stashed under
`/etc/waydroid-extra/`, so switching profiles is instant and offline instead of fresh
multi-gigabyte download.

Note on earlier claim in these docs: official LineageOS 20 image was described here
as carrying no Panfrost and software rendering through SwiftShader. That was wrong, and
cause was our own configuration: `init` forced `ro.hardware.egl=swiftshader` and deleted
`drm_device` before measurement. Upstream enables ARM drivers in
`waydroid_arm64/BoardConfig.mk` (`BOARD_MESA3D_GALLIUM_DRIVERS += ... panfrost lima`,
`BOARD_MESA3D_VULKAN_DRIVERS += ... panfrost`), not in root `BoardConfig.mk`, which
lists only llvmpipe, virgl and friends, and reading root file alone gives false
impression there is no Panfrost. HALIUM vendor images ARE stripped of Mesa GPU drivers,
so MAINLINE vendor image is required; MAINLINE is what these profiles fetch.

X11 wrinkle: this box runs KDE Plasma on X11 on purpose (Wayland breaks GPU/mpv
path on this BSP), and Waydroid's full UI wants Wayland compositor. `start` runs nested
Weston window inside X session and points Waydroid at it. Nothing about desktop
changes.

Window is FIXED SIZE on purpose. Any window-manager geometry change (drag-resize, edge
snap, quick tile, maximise, fullscreen) makes Weston reconfigure its X11 output.
Waydroid client renders Android at one fixed size, cannot follow that reconfigure, drops
off compositor, and window goes PERMANENTLY black. Launcher therefore pins
`WM_NORMAL_HINTS` min equal to max so window is not resizable. Choose size
with `h96-waydroid size` instead.

Other subcommands:
- `spoof [dev|off]` - report box as common phone so Aurora Store behaves. It does
  NOT defeat Play Integrity or SafetyNet.
- `state save|list|load|delete` - snapshot and restore Android `/data`. It refuses
  cross-profile restores: Android 11 data loaded onto Android 13 crashes `system_server`.

HONEST LIMIT: container CANNOT use RK3588 NPU. Its `vendor.img` carries no RKNN
libraries and no neuralnetworks HAL, so passing NPU node through would only give
Android device file with no driver behind it. NPU work stays on host side
(`h96-npu`, `h96-npu-upscale`).

TESTED AND REJECTED: shadowing container's `/dev/kmsg` to cut kernel log noise.
Shadow mount applies cleanly, but Waydroid container then never starts. Do not retry
it.

### v5.0.1 additions

- Borderless fullscreen: `h96-waydroid size fullscreen` opens window borderless at 0,0
  filling screen. It opens at screen size, so there is no output reconfigure and
  surface does not black out.
- Clean teardown: closing Android window stops session AND container, so
  container does not keep holding GPU. Sudoers drop-in lets desktop user run
  `h96-waydroid stop` without password, and Stop Android menu entry was added.
- `q` to quit: started from terminal (`h96-waydroid start`), launcher quits and tears
  down on `q` then Enter, in addition to closing window.

## GPU emulator suite: h96-emulators (v5.0)

`h96-emulators` installs nothing by default and bundles no emulator and no game code.
Everything is pulled from upstream on demand, so non-gamers carry no weight. Bring your own
dumps and BIOS.

Eight GPU-accelerated systems:

    retroarch  multi-system, Vulkan/glcore cores      Flatpak, PanVK/Panfrost
    dolphin    GameCube / Wii                         Flatpak, Vulkan (PanVK)
    ppsspp     Sony PSP                               Flatpak, Vulkan (PanVK)
    flycast    Sega Dreamcast / NAOMI                 Flatpak, Vulkan / GL
    melonds    Nintendo DS                            Flatpak, OpenGL 3D renderer
    rmg        Nintendo 64 (Parallel-RDP)             Flatpak, Vulkan (PanVK)
    azahar     Nintendo 3DS                           Flatpak, Vulkan (PanVK)
    cemu       Nintendo Wii U                         box64 (x86-64 build), Vulkan

Seven Flatpaks are native ARM64 and render on Mali-G610 through PanVK/Panfrost.
Cemu has no ARM build at all, so it runs x86-64 build under `box64` (no wine involved).

Mechanism: Flatpak sandbox does not see GPU unless it is wired in, and when it is not
wired emulator does not fail loudly, it silently falls back to `llvmpipe` software
rendering and runs badly. `install` therefore does two things: it wires each Flatpak's
sandbox to Mali GPU, then VERIFIES result and warns per emulator when backend
in use is software rather than PanVK/Panfrost. `h96-emulators gpu` reports that wiring at
any time, and `h96-emulators list` shows recommended backend to select inside each
emulator.

Fresh flashes have no `flatpak` at all. Install auto-bootstraps it (apt `flatpak` plus
Flathub remote) after warning, or run `h96-emulators bootstrap` first.

mGBA and ScummVM are deliberately excluded. Both are 2D and do not meaningfully use
Mali GPU, so this tool's GPU wiring has nothing to do for them. They are not missing from
box: both are one click away in software store as Flathub `io.mgba.mGBA` and
`org.scummvm.ScummVM`, or as apt `mgba-qt` and `scummvm`. They run fine on CPU.
