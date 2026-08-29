# H96 Max V58 (RK3588) Unofficial Armbian v4.0

```
██╗  ██╗     ██████╗
██║  ██║    ██╔═══██╗
███████║    ██║   ██║
╚════██║    ██║   ██║
     ██║ ██╗╚██████╔╝
     ╚═╝ ╚═╝ ╚═════╝
```

## v4.0

1. Hardware video decode works for desktop users. It was
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
10. Display scale: `h96-scale <factor>` sets KDE global scale and applies it
    live; autologin enabled so a logout re-applies it. On X11 a log out/in is
    required for a scale change to reach all apps. See 9.

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
shown. Root processes are unaffected, which is why validations run as root did not
encounter it. Present in every release to date. This build ships a udev rule setting
DMA heaps to `root:video 0660`. Measured on hardware: CPU during YouTube playback in
browser-to-mpv path changed from 64% of one core to 15%.

On any earlier release, apply:

```
echo 'SUBSYSTEM=="dma_heap", KERNEL=="system*", GROUP="video", MODE="0660"' | \
  sudo tee /etc/udev/rules.d/99-h96-dma-heap.rules && sudo udevadm trigger
```

### 1b. Hardware video was broken on every fresh flash

**This is highest-impact fix in v4.0, and it affects v3.4 as well.**

On a fresh flash, **both mpv and ffmpeg failed to start**:

```
ffmpeg: error while loading shared libraries: libXv.so.1
!!! mpv not runnable after setup (still missing: libass.so.9 libplacebo.so.360
    libXv.so.1 libXpresent.so.1) — NOT setting done flag; will retry next boot
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

Every release until now forced a display mode because SoC's HDMI DDC i2c controller
never completes a transaction on this kernel, so box could not read connected
display's EDID. DDC wires themselves work (stock Android reads EDID over them).
`sudo h96-display auto` reads display's EDID over `i2c-ddc` kernel bus (falling
back to a direct GPIO read when that bus is absent), validates it, picks its preferred mode capped at this box's limits, and sets it
through existing one-boot trial and `keep` confirmation. On any failure (cable
unplugged, display off, corrupt data) current mode is left unchanged. Measured:
a full 256-byte read takes 1.5 s and does not disturb running display.

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
`xset dpms force on`. A udev rule runs same check after a real hotplug
(`HOTPLUG=1`). Normal blanking is untouched: healthy DPMS keeps
`enabled=enabled` and daemon acts only in broken state. Manual trigger:
`sudo h96-display wake`. Measured: broken state forced via `xrandr --off`,
one injected keypress, picture back in about 4 s (`hdptx phy lane locked`,
`vop enable intf`, journal `re-drove HDMI-1 (1920x1080@60)`).

### 3. Monitor brightness over DDC/CI

`h96-brightness` sets a connected monitor's backlight over DDC/CI (VCP 0x10), not a
software gamma dim. SoC's HDMI DDC i2c controller does not complete transactions on
this kernel, so a device-tree overlay (`h96-ddc-i2c-gpio`, enabled by default) exposes
two DDC pins as a kernel i2c bus named `i2c-ddc` at 100 kHz. ddcutil drives DDC/CI over it.

```
h96-brightness            show current brightness
h96-brightness 40         set brightness to 40
h96-brightness up 10      raise by 10
h96-brightness down 10    lower by 10
```

Requirements and limits:
- ddcutil is installed automatically at first boot from offline repo, so no manual
  step is needed. (If it is ever absent, `sudo apt install ddcutil` also resolves offline.)
- Display must honour DDC/CI writes. Most PC monitors do; enable "DDC/CI" in
  monitor's on-screen menu if brightness does not change. Measured on a Dell P2419H:
  brightness set to 30/75/15/60 tracked exactly with visible change.
- Most TVs gate DDC/CI behind an HDMI/CEC handshake this box cannot perform, so brightness
  control is unavailable on them. Tool reports this instead of failing with no error.
- With KDE installed plus ddcutil, PowerDevil detects display on `i2c-ddc` bus and
  shows a brightness slider in its settings.

### 4. `scrumptop` system monitor

Terminal system monitor in project color scheme. CPU per-core bars using
RK3588's non-contiguous topology (A76 = CPU1-4, A55 = CPU0,5,6,7) with per-cluster
temperature gauges on each bar; GPU and NPU load, frequency, and temperature; network
rates, Bluetooth, IR remote activity; disk usage, eMMC I/O rates, swap, load, uptime,
peripheral batteries; each temperature carries session min/max. Keys: `b` run/stop
3-core NPU benchmark, `+`/`-` polling rate, `p` pause, `h` help. `scrumptop --snapshot`
prints one frame and exits.

`b` runs `h96-npu bench all`: one INT8 matmul pinned per core (0/1/2), concurrent, with
per-core and aggregate result on NPU temp line. Measured: ~1.29 TOPS across 3 cores.
Second press cancels a running bench. Requires runtime installed by `sudo h96-npu-setup`.

Whole terminal is framed in theme: a wordmark badge in outer border, side rails, and
block wordmark set in green into a dark textured banner; bottom deadspace carries same
texture. Usage bars are segmented; temperature gauges use a narrower glyph. Rendering is
line-diffed (only changed lines rewritten each tick) and event-driven (`select()` wait,
not a poll loop). Measured at a 1 s refresh: 0.66% of one core, 20 MB resident.

### 5. Desktop lock screens could not authenticate

Base rootfs ships `/etc/shadow` owned `root:root`; required ownership is
`root:shadow` because PAM helper `unix_chkpwd` is setgid `shadow`. Display managers
run as root and read file directly, so login worked while unlock did not:
Plasma/GNOME/XFCE lock screen rejects correct password. Present in every release to
date. This build ships group corrected. On any earlier release, apply:
`sudo chgrp shadow /etc/shadow`.

### 6. NPU, hardware encode, GPU upscaling

**NPU (3-core, ~6 TOPS).** It was already working: driver `v0.9.8`, IOMMU mode, 1000 MHz,
per-core load reporting, exposed as `/dev/dri/renderD129`, and default user is already
in `render` group. Nothing in userspace had ever asked it to do anything.

- `h96-npu`: status, live per-core load, and frequency pinning validated against
  kernel's own OPP list. `h96-npu bench` measures one core (~625 GOPS); `h96-npu bench
  all` pins one job per core (0/1/2) for ~1.29 TOPS aggregate. Aggregate is ~2x one core,
  not 3x: large matmuls are DRAM-bandwidth-bound (no NPU SRAM), and `auto` core mode packs
  onto core 0, so multi-core needs explicit per-core pinning or a multi-core `.rknn`.
- `sudo h96-npu-setup`: installs inference runtime **on demand**. It is not bundled:
  `librknnrt.so` is proprietary Rockchip software under "RKNN SDK License", whose
  clause 1.2 allows copies "on an internal basis only", and this image is published
  publicly under GPL-2.0. Build now fails on purpose if that binary is ever found
  inside image. Verified: runtime `2.3.2` against driver `v0.9.8`. Post-install check now
  confirms load path correctly (earlier build printed a false failure after a good install).
- Python caveat: Rockchip's `rknn-toolkit-lite2` wheels stop at CPython 3.12 and this image
  runs Python 3.14, so Python layer needs an interpreter you supply. C API works.
- `could not find sram resource!` at boot is **expected, not a fault**: system SRAM is
  allocated in full to two video decoders (`0x78000 + 0x77000 = 0xEF000`, zero free).

**Hardware video encode.** `RKVENC`/`RKVENC2`/`JPGENC` were enabled all along and
bundled ffmpeg already had `h264_rkmpp`, `hevc_rkmpp` and `mjpeg_rkmpp`. New `h96-encode`
exposes them. This is box's **only** encode path; bundled ffmpeg has no `libx264`.
Measured: 1080p faster than 180 fps on both H.264 and HEVC.

**GPU upscaling.** New `h96-upscale` enables ravu-lite-ar-r4 as an mpv user shader on
Mali-G610. Measured here at ~10–13% extra GPU time, compiling clean on Panfrost. FSRCNNX and
nnedi3 were rejected as far outside this GPU's budget, and shader's `gather/` variant does
not work here (no `textureGatherOffset` in this GLES context).

### 6b. Subtitles: `h96-subtitles`

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

**Overclocking: tested, and numbers say do not bother.**

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
`time_in_state` (13442 ticks at 2400 against 812 at 2208). It simply does not help: a
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

**Undervolting: also tested, and also not worth it.**

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

**Branding.** Block-letter header is now one shared, TTY-gated library on box, with
separate wordmarks for Firmware Suite and for Unofficial Armbian.

**HDMI DDC** was intended headline and did not work. Every layer of path verified
correct, and a timeout fix was tested and cleanly refuted. v3.4's forced mode plus substitute
EDID stands. Full reasoning is in repository changelog.

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

### 9. Display scale, applied live (`h96-scale`) + autologin

On X11, Plasma's Global Scale slider writes correct config but scales only
newly-started apps, so a running desktop shows no change until next login.
`h96-scale <factor>` writes same config (`kdeglobals` ScaleFactor +
ScreenScaleFactors, `kcmfonts` forceFontDPI), sets live X font DPI, and restarts
Plasma shell, so panel and desktop rescale immediately. **A LOG OUT AND BACK IN
IS STILL REQUIRED** for open apps and a consistent scale across session.
Autologin (`h96-autologin.service`) points lightdm at desktop user, so a logout
returns to scaled desktop without a password prompt. Wayland scales live but is
not used: it breaks GPU acceleration, compositing, and mpv output on this box.
Validated on hardware: on a fresh flash, autologin logged in without a password,
and `h96-scale 1.5` set config, live font DPI 144, and shell restart.

## v3.4

**v3.4 restores HDMI audio, which v3.3 broke.** If you are on v3.3 and get no sound from
TV, this is fix. It also makes two sound outputs tell themselves apart, and includes
GPU monitor in image rather than downloading it.

---

## HDMI audio works again

v3.3 added a boot setting that stopped system endlessly retrying a display information
read that cannot succeed on this board. It saved about a third of startup time.

Substitute display description it supplied was a minimal one, and a minimal description
does not include section that says display accepts sound. Reading that, driver
switches HDMI output into a mode that carries picture only, and sound is dropped before
it reaches TV.

v3.4 supplies a fuller description that includes sound section. Sound works, and
repeated read attempts still stop.

That last part matters more than it first appears. Those retries are not only a startup
cost: without setting system keeps retrying for as long as box is on, roughly
once a second, forever. Measured on this board:

| | retries |
|---|---|
| no setting at all | 108 after 99 seconds, still climbing |
| v3.4 | 19, and it stays at 19 |

Startup returns to about 7.1 seconds, from about 5.4 in v3.3. Recovering that would need
description loaded earlier in startup than is currently safe on this board, so it is left
for a later release. Sound is worth more than seconds.

Everything else v3.3 improved is unchanged: processor still idles at its lowest speed
rather than running flat out, still reaches full speed on demand, and package retry
service still runs off startup path.

## Sound outputs now have names

Both outputs previously appeared as "Built-in Audio" and "Built-in Audio Stereo", which is
no help when choosing between them. They are now:

- **HDMI Out**
- **S/PDIF Optical**

HDMI is default. Both remain selectable in desktop audio settings, and an explicit
choice is remembered.

If you are coming from v3.3 and had selected S/PDIF while HDMI was silent, switch back to
HDMI after updating. If an output ever seems stuck, deleting
`~/.local/state/wireplumber/default-nodes` and logging out and in clears remembered
choice.

## nvtop is now in image

GPU monitor was previously downloaded on first boot, so a box set up without a working
internet connection never received it. It is now included in image and installs with
everything else. Run `nvtop` in any terminal for live GPU speed and load.

## Documentation corrections

Several instructions were wrong and have been fixed:

- Display fallback command was documented as `h96-display 720p`, which is not a valid
  mode and fails. Correct command is `sudo h96-display safe`. This is command for
  someone whose display shows nothing, so it mattered that it was wrong. Follow-up step
  `sudo h96-display keep`, which makes change permanent, was also missing.
- Two options documented for WiFi command do not exist. Running `h96-wifi-connect` with
  no arguments lists visible networks; `wpa_cli -i wlan0 status` shows current
  connection.
- Flashing guide named wrong default display mode in its no-signal section.
- Description of processor behaviour at startup still described older pinned
  behaviour rather than what v3.3 changed it to.

## Upgrading

Flash image as usual. Flashing replaces everything on box, so back up anything you
want to keep first.
