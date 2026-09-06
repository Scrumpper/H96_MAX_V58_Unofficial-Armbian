# Media feature suite + USB controllers (v4.1, plus v5.0 additions)

All OPT-IN. The image ships the tools + configs only; each tool installs its
packages on demand and activates services on first `enable`. Nothing auto-starts.
Sources under `packages/bsp/h96-max-v58/` (tools/, lib/, systemd/, udev/, mpv/,
wireplumber/, pipewire/, etc-h96/, modules-load.d/).

## Tools

- **h96-cec** - HDMI-CEC: control the box with the TV remote. Daemon (lib/h96-cecd)
  maps CEC remote keys to uinput events. Needs /dev/cec0 from the dw-hdmi-qp CEC
  block + v4l-utils/cec-utils (installed on enable). BOX-VERIFIED NON-FUNCTIONAL: this
  6.1 BSP kernel has CEC core (CONFIG_CEC_CORE) but does NOT build the DesignWare HDMI
  CEC driver (no CONFIG_DRM_DW_HDMI_CEC, no /sys/class/cec), so /dev/cec0 never appears.
  The tool self-reports this. Fixing it needs a kernel rebuild with the dw-hdmi(-qp) CEC
  driver + DT wiring; not a userspace fix.
- **h96-hdr** - mpv HDR10 handling: tone-map HDR10 to SDR via vo=gpu-next/libplacebo
  (the reliable path; true passthrough is X11-limited on this stack).
- **h96-motion** - mpv BUILT-IN frame interpolation (judder reduction), GPU-side,
  zero deps. The SVP/MVTools "soap-opera" path is intentionally not used:
  vapoursynth + mvtools have no arm64 build in the box repos.
- **h96-npu-upscale** (+ **-setup**) - offline Real-ESRGAN x4 super-resolution on
  the RKNPU. See below.
- **h96-audio-passthrough** - HDMI bitstream (AC3/DTS/E-AC3) + multichannel LPCM to
  an AV receiver.
- **h96-audio-eq** - system-wide parametric EQ via a native PipeWire filter-chain
  (no extra deps) + AutoEQ presets in /etc/h96/eq/presets/.
- **h96-bt-speaker** - box as a Bluetooth A2DP speaker: pair a phone, audio out HDMI.
- **h96-cast** - AirPlay audio (shairport-sync) + screen mirror (uxplay) + DLNA
  renderer (gmediarender). AirPlay 2 downgrades to AirPlay 1 (nqptp has no arm64
  build). Google Cast reception is not openly possible; DLNA is the substitute.
- **h96-transcode-server** - opt-in network HARDWARE transcode node. Drop a video into
  /srv/h96-transcode/in (over SFTP, or Samba/NFS-export the folder); the VPU transcodes
  it (rkmpp hw decode + hw encode) to /srv/h96-transcode/out and moves the original to
  done/. Box-measured ~7.5x realtime at 1080p (30 s clip in ~4 s) with the CPU idle. NO
  extra packages - it reuses the image's rkmpp ffmpeg + /dev/mpp_service, so it adds no
  weight. Ships DISABLED: `sudo h96-transcode-server enable`. Settings in
  /etc/h96/transcode.conf (codec hevc/h264/mjpeg, bitrate, container, optional scale).

## USB game-controller dongles (xpad)

Base kernel had no xpad, so X-input controllers and 2.4GHz pad dongles did
nothing over USB. Enabled via CONFIG_JOYSTICK_XPAD=m (kernel config) + autoload
(modules-load.d/xpad.conf) + a udev catch-all (udev/99-h96-xpad.rules) that
force-binds any X-input-interface device to xpad. D-input/HID pads already worked.

## NPU upscaling: how it works and how to use it

`h96-npu-upscale` is an OFFLINE / BATCH upscaler, not live playback. One Real-ESRGAN
tile inference on the NPU is ~100 ms, so a full frame is seconds and a clip is
minutes. Use it for stills and short low-res clips.

Mechanism:
- Real-ESRGAN x4 model (realesrgan_x4_96.rknn, 96x96 -> 384x384). Fetched on demand
  (~58 MB, MIT) into /var/lib/h96/upscale/models/ by h96-npu-upscale-setup.
- Talks to the Rockchip runtime librknnrt.so directly via ctypes (C API) - the
  rknnlite Python wheel only builds for CPython <= 3.12, so it is not used.
- Images are cut into overlapping 96x96 tiles, each upscaled on the 3-core NPU, then
  feather-blended back together to hide seams.
- Video shells out to the box ffmpeg: split to frames, upscale each, reassemble with
  the hardware encoder (hevc_rkmpp) and copy the audio.

Use:

    h96-npu-setup                 # once: fetch the RKNN runtime (librknnrt.so)
    h96-npu-upscale-setup         # once: fetch + verify the model
    h96-npu-upscale in.png out.png            # upscale an image (x4)
    h96-npu-upscale clip.mp4 out.mp4          # short clip (slow: minutes)
    h96-npu-upscale --info                    # show NPU + model info
    # options: --overlap 16  --max-frames 900  --model PATH

## Android in a container: h96-waydroid (v5.0)

`h96-waydroid` runs a full Android system in an LXC container that shares the host
kernel (Waydroid 1.6.2). It is OPT-IN like everything else here: the image ships the
command, nothing else.

Why it needs the v5.0 kernel:
- Android 11 and later `init`/`lmkd` hard-require `/proc/pressure`. The stock BSP kernel
  built PSI out, so the container came up and then died in about 15 seconds. v5.0 rebuilds
  the kernel with `CONFIG_PSI=y` (`PSI_DEFAULT_DISABLED` off) from armbian/linux-rockchip
  `rk-6.1-rkr5.1`, commit `95e85f6c`. Binder (`CONFIG_ANDROID_BINDER_IPC`/`BINDERFS`) is
  built in as well. `h96-waydroid status` verifies both.
- The kernel release string is unchanged at 6.1.115, so `/lib/modules/6.1.115` stays valid
  and no module was rebuilt: 69 modules load with zero ABI errors. It is an Image-only
  rebuild, so an existing install cannot `apt upgrade` into it; it needs the v5.0 image.

Image profiles:
- `init gapps|vanilla` - the official Waydroid LineageOS 20 image
  (`lineage-20.0-20260403-VANILLA-waydroid_arm64`, Android 13, vendor type MAINLINE, about
  900 MB). This is the DEFAULT and the recommended profile, and it wires the Mali-G610:
  `drm_device=/dev/dri/renderD130`, `ro.hardware.gralloc=gbm`, `ro.hardware.egl=mesa`, with
  the `renderD130` and `card2` nodes bound into the container. Measured on the box:
  `dumpsys SurfaceFlinger` reports
  `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`; GPU load reads
  `0@300000000Hz` at idle, reaches 50 percent at 1000 MHz under UI activity, and sits at 19
  to 26 percent at 600 MHz. `boot_completed=1` with the session ready in about 8 seconds.
  Android 13 is cgroup v2, so no cgroup v1 shims are applied, and the window follows the
  Weston output size.
- `init gpu` - LEGACY, kept for anyone holding that stashed image: a third-party
  Panthor-in-image Android 11 build (LineageOS 18.1, about 5 GB) that you supply. Measured
  on the box: `GLES: Mesa, Mali-G610 (Panfrost), OpenGL ES 3.1 Mesa 24.0.5`, GPU load 27 to
  41 percent at 300 to 700 MHz. Against the official image it is older Android (11 against
  13), older Mesa (24.0.5 against 26.0.1), unsigned, and abandoned since April 2024 (author
  WillzenZou, repos frozen). It needs the cgroup v1 tmpfs shims (`/acct`, `/dev/stune`,
  `/dev/cpuset`, `/dev/memcg`), pins itself to a 960x512 display that has to be overridden,
  and Vulkan never worked on it.
- `init custom <dir>` - your own image. It must be an arm64 Waydroid-style `system.img`
  plus `vendor.img` PAIR; a ROM zip, OTA payload or plain GSI will not boot.
- `hw off` forces software rendering, as a diagnostic and fallback; `hw on` re-applies the
  GPU wiring and verifies it.

Images are about 900 MB for the official Android 13 build and up to 5 GB for a
user-supplied one, are NOT bundled with the release, and are stashed under
`/etc/waydroid-extra/`, so switching profiles is instant and offline instead of a fresh
multi-gigabyte download.

Note on an earlier claim in these docs: the official LineageOS 20 image was described here
as carrying no Panfrost and software rendering through SwiftShader. That was wrong, and the
cause was our own configuration: `init` forced `ro.hardware.egl=swiftshader` and deleted
`drm_device` before the measurement. Upstream enables the ARM drivers in
`waydroid_arm64/BoardConfig.mk` (`BOARD_MESA3D_GALLIUM_DRIVERS += ... panfrost lima`,
`BOARD_MESA3D_VULKAN_DRIVERS += ... panfrost`), not in the root `BoardConfig.mk`, which
lists only llvmpipe, virgl and friends, and reading the root file alone gives the false
impression there is no Panfrost. HALIUM vendor images ARE stripped of the Mesa GPU drivers,
so the MAINLINE vendor image is required; MAINLINE is what these profiles fetch.

The X11 wrinkle: this box runs KDE Plasma on X11 on purpose (Wayland breaks the GPU/mpv
path on this BSP), and Waydroid's full UI wants a Wayland compositor. `start` runs a nested
Weston window inside the X session and points Waydroid at it. Nothing about the desktop
changes.

The window is FIXED SIZE on purpose. Any window-manager geometry change (drag-resize, edge
snap, quick tile, maximise, fullscreen) makes Weston reconfigure its X11 output. The
Waydroid client renders Android at one fixed size, cannot follow that reconfigure, drops
off the compositor, and the window goes PERMANENTLY black. The launcher therefore pins
`WM_NORMAL_HINTS` min equal to max so the window is not resizable. Choose the size
with `h96-waydroid size` instead.

Other subcommands:
- `spoof [dev|off]` - report the box as a common phone so Aurora Store behaves. It does
  NOT defeat Play Integrity or SafetyNet.
- `state save|list|load|delete` - snapshot and restore the Android `/data`. It refuses
  cross-profile restores: Android 11 data loaded onto Android 13 crashes `system_server`.

HONEST LIMIT: the container CANNOT use the RK3588 NPU. Its `vendor.img` carries no RKNN
libraries and no neuralnetworks HAL, so passing the NPU node through would only give
Android a device file with no driver behind it. NPU work stays on the host side
(`h96-npu`, `h96-npu-upscale`).

TESTED AND REJECTED: shadowing the container's `/dev/kmsg` to cut kernel log noise. The
shadow mount applies cleanly, but the Waydroid container then never starts. Do not retry
it.

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

The seven Flatpaks are native ARM64 and render on the Mali-G610 through PanVK/Panfrost.
Cemu has no ARM build at all, so it runs the x86-64 build under `box64` (no wine involved).

Mechanism: a Flatpak sandbox does not see the GPU unless it is wired in, and when it is not
wired the emulator does not fail loudly, it silently falls back to `llvmpipe` software
rendering and runs badly. `install` therefore does two things: it wires each Flatpak's
sandbox to the Mali GPU, then VERIFIES the result and warns per emulator when the backend
in use is software rather than PanVK/Panfrost. `h96-emulators gpu` reports that wiring at
any time, and `h96-emulators list` shows the recommended backend to select inside each
emulator.

Fresh flashes have no `flatpak` at all. An install auto-bootstraps it (apt `flatpak` plus
the Flathub remote) after a warning, or run `h96-emulators bootstrap` first.

mGBA and ScummVM are deliberately excluded. Both are 2D and do not meaningfully use the
Mali GPU, so this tool's GPU wiring has nothing to do for them. They are not missing from
the box: both are one click away in the software store as Flathub `io.mgba.mGBA` and
`org.scummvm.ScummVM`, or as apt `mgba-qt` and `scummvm`. They run fine on the CPU.
