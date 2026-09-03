# Media feature suite + USB controllers (v4.1)

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
