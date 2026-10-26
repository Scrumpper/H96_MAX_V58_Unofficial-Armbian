# H96 Max V58 Unofficial Armbian: command reference

> Type **`h96`** on box for categorized index of main commands, or `h96 <command>` for its help.


Every command and service added by this build. Nothing here exists on stock Armbian.

## Highlights

> **Released image is console only.** It includes no desktop and no user account. Install
> desktop on demand with `armbian-config` (System, Desktop) or `apt install
> kde-plasma-desktop`. `h96-autologin.service` then sets lightdm autologin on
> `plasmax11` (X11) session at next boot, one time; `sudo h96-autologin-setup` applies it at
> once, `--off` turns it off.
> Reflashing writes whole eMMC, so desktop installed this way does not survive one.

- **Android on GPU by default (v5.0).** `h96-waydroid init gapps|vanilla` wires
  Mali-G610 instead of forcing SwiftShader. Measured on official
  `lineage-20.0-20260403-VANILLA-waydroid_arm64` image, vendor type MAINLINE:
  `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`, GPU load
  `0@300000000Hz` at idle and 50 percent at 1000 MHz under UI activity, `boot_completed` in
  about 8 seconds. cgroup v1 tmpfs shims are applied only on legacy Android 11 path.
- **GPU emulator suite (v5.0).** `h96-emulators` installs eight systems as GPU-accelerated
  emulators: seven native arm64 Flatpaks through PanVK and Panfrost, plus `cemu` under box64.
  `install` wires each Flatpak sandbox to Mali-G610 and reads renderer string back out;
  automatic probe verifies four of seven as `Mali-G610 MC4 (Panfrost)`.
- **zram self-heal (v5.0).** Fresh flash was measured booting with no swap at all.
  `h96-zram-heal.service` re-enables `armbian-zram-config.service` at boot when its want is
  missing. Working zram measured at 3.8 GB, algorithm zstd.
- **Flashing without pinhole (v5.0).** `reboot loader` over SSH puts running box into
  flashing mode; flasher converts Loader to Maskrom itself. Pinhole stays as fallback
  for box that will not boot.
- **Android in container (v5.0).** `h96-waydroid` runs Waydroid in nested Weston window
  on X11. This is why kernel is rebuilt with `CONFIG_PSI=y`. Android images are not
  bundled and window is fixed-size on purpose.
- **Emulator suite (v5.0).** `h96-emulators` installs eight GPU-accelerated emulators
  (retroarch, dolphin, ppsspp, flycast, melonds, rmg, azahar, cemu), wires each one to
  Mali GPU, and verifies that none silently fell back to llvmpipe software rendering.
- **Hardware video decode.** Fixed in v4.0: it was root-only in every earlier release, so
  desktop users decoded in software. Now it decodes on VPU for everyone. Browser
  YouTube in mpv path dropped from 64% of one CPU core to 15%. `h96-encode` adds
  hardware H.264/HEVC/MJPEG encoding (1080p faster than 180 fps).
- **`scrumptop`.** Terminal system monitor for this SoC: per-core CPU with per-cluster
  temperatures (session min/max on every temp), GPU, NPU, network rates, disk I/O,
  peripheral batteries, and 3-core NPU benchmark on keypress. 0.66% of one core at
  1 s refresh. Run: `scrumptop`.
- **NPU.** `h96-npu` reports and tunes 3-core NPU (image default `powersave`, 300 MHz); `sudo h96-npu-setup` installs
  runtime on demand; `h96-npu bench` measures one core (about 625 GOPS), `h96-npu bench all`
  measures all 3 (about 1.29 TOPS aggregate). Note: on this board NPU is memory-bandwidth-bound
  and single CPU core outruns it for most work, so it is exposed for NPU-shaped INT8
  models, not as general accelerator.
- **Display detection (v6.2).** On by default: `h96-display detect` reads connected
  display's EDID at boot and on hotplug and lists its modes in KDE System Settings →
  Display, up to 8K; KDE remembers choice per display. HDMI 2.0 tier (1440p120/144,
  4K60) is on by default; modes wider than 4096 px and FRL tier are listed but untested.
  Colour format and range are set per display with `sudo h96-display color` and `range`,
  each with confirm-or-revert. Pick refresh rate HDMI cable can carry: 120/144 Hz and
  4K60 need Premium or Ultra High Speed cable.
- **Screen wake.** Blanked screen that never returned on keypress is fixed:
  daemon re-drives HDMI output when connector is stuck `connected` but
  `enabled=disabled` (BSP kernel does not re-init PHY/VOP path on its own).
  Box never suspends (Armbian base masks suspend; BSP suspend does not resume),
  so dark screen was always this stuck output. Manual: `sudo h96-display wake`.

Commands in `/usr/bin` are on your `PATH` and run as normal user unless noted.
Commands in `/usr/sbin` are administrative: call them with `sudo`. Helper scripts in
`/usr/lib/h96` run from systemd units; sections below give full path where one is run by hand.
Most administrative commands also run from systemd, so manual calls are rare.

---

## Display

### `h96-brightness`
Set connected monitor's backlight over DDC/CI (VCP 0x10), not software gamma dim.
GPIO I2C bus behind this takes two HDMI DDC pins at boot.

```bash
h96-brightness            show current brightness
h96-brightness 40         set to 40 (0-100)
h96-brightness up 10      raise by 10
h96-brightness down 10    lower by 10
```

SoC's HDMI DDC i2c controller does not complete transactions on this kernel, so
v6.2 device tree exposes two DDC pins as kernel i2c bus named `i2c-ddc` at 100 kHz
(earlier releases used `h96-ddc-i2c-gpio` overlay). Kernel reads EDID and drives SCDC
over it, and ddcutil drives DDC/CI over it. ddcutil is installed automatically at first boot from
offline repo (no manual step); `sudo apt install ddcutil` also resolves offline if needed. Display must accept DDC/CI writes: most PC monitors do (enable
"DDC/CI" in monitor menu if brightness does not change). Measured on Dell P2419H:
setting 30/75/15/60 tracked exactly with visible change. Most TVs gate DDC/CI behind
HDMI/CEC handshake this box cannot perform and are not controllable; tool reports this.
With KDE installed plus ddcutil, PowerDevil shows brightness slider for display.

### `h96-scale`
Set KDE Plasma global display scale and apply it live.

```bash
h96-scale            show current scale
h96-scale 1.5        set 150% scale, applied immediately
h96-scale 1.25       125%, and so on (0.5 to 3.0)
```

**LOG OUT AND BACK IN IS REQUIRED for scale change to reach all apps.** On
X11, scale applies only to newly-started apps, so running session ignores both
Plasma's Global Scale slider and h96-scale until re-login. h96-scale restarts
Plasma shell so panel and desktop update right away, but open apps and
consistent scale across session still need log out/in.

Plasma's own Global Scale slider (System Settings, Display) writes correct config
but gives no hint that re-login is needed, which is why it appears to do nothing.
h96-scale writes same config (`kdeglobals` ScaleFactor + ScreenScaleFactors,
`kcmfonts` forceFontDPI) and sets live X font DPI. Acts on caller's own Plasma session;
with sudo or as root, on active seat0 session (logind), so second desktop user is never
changed by mistake. Unknown argument exits 2. Once autologin is set (`h96-autologin.service` at boot, or
`sudo h96-autologin-setup`), lightdm autologins desktop
user into `plasmax11` session, so logout returns to scaled desktop with no password
step. In Plasma Wayland session (experimental, `h96-autologin-setup --session plasma`) h96-scale sets output scale through `kscreen-doctor`
(live for all apps, no log out), reads it back and exits 1 when scale did not change;
font DPI and `kdeglobals` stay untouched there. X11 stays default session.

### `h96-display`  (`/usr/sbin`, needs root)
HDMI display detection, colour format and range, and forced boot mode. On-chip HDMI
DDC controller never completes transfers (RK3588 BSP driver limitation). Kernel (since
v6.2) reads EDID over GPIO I2C bus on same pins (`i2c-ddc`), and `detect` turns connected
display's EDID into KDE's mode list. Console and first mode before KDE applies its own
still use forced default of `1920x1080@60`. Display tools (`h96-display`, `h96-scdc`,
`h96-audio-passthrough`, `h96-hdr`, `h96-cast`, `h96-vm`, `h96-waydroid`) find X display and
auth of active seat0 session through `/usr/lib/h96/h96-xdisplay`: X11 on any display
number (`:1` after Wayland session in same boot), Xwayland in Wayland session.

```bash
sudo h96-display detect               # read EDID, list display's modes in KDE (runs at boot; hotplug: h96-hdmi-hotplug)
sudo h96-display revert               # connected display to 1920x1080@60 through KDE (KDE remembers it; X11 and Wayland)
sudo h96-display native               # connected display to its preferred mode through KDE
h96-display status                    # detected display, KDE config, switches, colour, SCDC
sudo h96-display hdmi20 on|off|status # HDMI 2.0 tier, 340-600 MHz with SCDC scrambling (default on)
sudo h96-display frl on|off|status    # FRL tier, above 600 MHz (default on, experimental)
sudo h96-display color rgb|ycbcr|auto # HDMI colour format for connected display
sudo h96-display range full|limited|auto  # quantization range, RGB only
sudo h96-display edid merged|real|status  # kernel EDID: built by detect (default) or display's own
h96-display color status              # setting, plus signal on wire (wire needs root)
sudo h96-vrr on|off|status            # variable refresh: Plasma X11 session, off by default; not in Wayland session
h96-display range status
```

Read-only verbs (`status`, `color status`, `range status`, `show`) run as normal user
through full path, `/usr/sbin/h96-display status`; `wire` and `scdc` clock readings
in `status` need root; as normal user they read `unknown (needs root)`. `detect --help` lists detect options.

**Modes.** `detect` lists modes up to 600 MHz TMDS plus FRL tier, progressive only, up
to 8K. KDE System Settings → Display lists them; KDE asks to keep new mode and
remembers choice per display across replug and reboot. `detect` sets no mode itself.
HDMI 2.0 tier (340 to 600 MHz: 2560x1440 at 120 and 144 Hz, 3840x2160 at 60 Hz) uses
SCDC scrambling, which kernel drives over `i2c-ddc`; `h96-scdc.service` verifies sink
lock and switches back to last working mode when lock fails. `hdmi20 off` caps modes
at 340 MHz and stops service. Modes wider than 4096 px and FRL tier (above 600 MHz:
4K120, 8K60) are listed but untested on hardware and experimental; they need HDMI 2.1
display and cable, and failed link training reverts. `frl off` removes them. `hdmi20`
and `frl` apply to every display.

**DVI displays.** Display whose EDID has no CTA-861 block (DVI monitor, often through
HDMI-to-DVI adapter) keeps its own EDID: driver sends DVI signal, no HDMI audio. Detection
runs about 15 s into boot and re-sets text console mode for DVI signal. Detect also
removes image-default `drm.edid_firmware` and `video=` tokens from `/boot/armbianEnv.txt`, so
from next boot kernel reads display EDID and console starts in display's own mode from
kernel start. Removed tokens are listed in `/etc/h96/display-dvi-profile`; HDMI display or
`h96-display autodetect off` puts them back. Mode kept with `h96-display keep` stays. Gate
file `/etc/h96/display-bootargs-sync.on` (in image); delete it to turn sync off. Display
swap while box is off: first boot runs with previous display's boot arguments, detect
corrects them for next boot. HDMI sound card then lists no output, and default
output moves to next sink (Bluetooth, S/PDIF). `hdmi20` and `frl` do not apply;
`autodetect off` keeps DVI signal with forced 1920x1080 mode.

**Colour and range, command line only.** `color rgb` (default), `ycbcr` (YCbCr 4:4:4
where display lists it, else RGB) or `auto` (driver picks 4:4:4, then 4:2:2, then RGB).
`range full` (default, 0-255), `limited` (16-235) or `auto` (driver default). YCbCr
always uses limited range, display engine limit; range setting applies to RGB only.
New value applies live, then asks `Keep this ...? Reverting in 15 s [y/N]`. Only `y`
keeps it; timeout, other keys, Ctrl-C or closed terminal revert. `--yes` keeps without
asking (needed without terminal); `--dry-run` changes nothing. Kept values are stored per
display in `/etc/h96/display/<manufacturer-product-serial>.conf` and re-applied at boot
and at login (`/etc/xdg/autostart/h96-display-session.desktop`). Display with no stored
value starts at RGB full range. Screen may blank for about 2 s during switch. Exit code:
0 kept or unchanged, 1 usage or no terminal, 3 reverted.

**Forced boot mode.**

```bash
sudo h96-display auto          # read TV's EDID and set its preferred mode (see below)
sudo h96-display show          # print mode currently set (read-only)
sudo h96-display safe          # 1280x720@60, mode every HDMI display must accept
sudo reboot                    # new mode applies on next boot
sudo h96-display keep          # REQUIRED once you can SEE it, or it reverts next boot
```

Modes: `safe` (1280x720@60), `1080p` (1920x1080@60), `1440p` (2560x1440@60), `4k`
(3840x2160@30), `4k60` (3840x2160@60; PHY locks at this rate on hardware, and
Premium High Speed cable is required), `8k` (7680x4320@30; unproven: needs HDMI 2.1 FRL
output, 8K display, and certified cable; trial mechanism reverts it on
power-cycle if nothing shows), or any `<WxH>` / `<WxH@Hz>` such as `sudo h96-display 1440x900`. Size
given without refresh rate defaults to `@60`.

`keep` (also accepted as `ok` or `confirm`) is second half of procedure, not
optional extra. Setting mode arms one-boot trial; if you do not confirm it,
`h96-display-guard.service` puts previous mode back on following boot and reboots.
That is what protects you from setting mode your display cannot show.

Mode is written to `video=HDMI-A-1:` part of `extraargs=` in
`/boot/armbianEnv.txt`. If you have no picture at all and cannot reach shell, edit that
line directly from another machine with boot partition mounted. See
`/boot/h96-display-README.txt`.

**`auto`**: SoC's HDMI DDC i2c controller never completes transaction on this
kernel, which is why forced mode exists at all. Wires themselves work (stock
Android firmware reads EDID over them), so `auto` reads display's EDID over
`i2c-ddc` kernel bus (same bus brightness feature uses), falling back to direct
GPIO read when that bus is absent. It validates EDID (header, checksums), picks display's
preferred mode capped at this box's limits, and sets it through same trial/`keep`
mechanism as manual mode. On any read or parse failure (cable unplugged, display off,
corrupt EDID) it prints reason and leaves current mode unchanged. Measured on
hardware: 256-byte EDID read takes 1.5 s and does not disturb running display.

**`autodetect`.**

```bash
sudo h96-display autodetect off     # forced 1920x1080 EDID for video, display's EDID for audio only
sudo h96-display autodetect on      # default: display's own mode list
sudo h96-display autodetect status  # show current state
```

On by default since v6.2. `off` returns to forced 1920x1080 mode list, keeping display's
audio capabilities.

**Kernel EDID source.**

```bash
sudo h96-display edid real      # kernel uses display's own EDID (installed off)
sudo h96-display edid merged    # default: kernel EDID built by detect
h96-display edid status
```

`merged` (default): detect builds kernel EDID from display EDID: RGB unless `color` says
otherwise, modes up to tier ceiling, sink audio blocks, display's VRR range blocks (AMD FreeSync
VSDB, HDMI 2.1 VRR bytes) kept, so `vrr_capable` reads 1 on VRR display
(`/etc/h96/display-vrr-blocks.off` drops them). `real`: no firmware file
and no override; kernel reads display EDID over `i2c-ddc` and uses it unchanged, so mode list,
colour formats, VRR range and audio come from display itself. Needs kernel DDC read (6.12
kernel); `hdmi20`, `frl`, `color` EDID filtering and `autodetect off` do not apply while it is on
(`autodetect off` wins). HDMI audio layouts, CEC address and hotplug follow display as in
`merged`. Switching EDID at runtime: kernel output stays on and X keeps its mode (set again only
when current mode is no longer offered); TV may blank for about one second while it resyncs.

**`wake`.** Re-drives HDMI output if it is stuck off (connector `connected` but
`enabled=disabled`). Needed because BSP kernel does not re-initialise HDMI
PHY/VOP path once output is dropped (X starting while monitor is asleep,
hotplug while blanked). `h96-display-wake.service` runs same re-drive
automatically on any key or button press, and udev rule runs it after
hotplug, so this is rarely needed by hand. Normal screen blanking still works:
daemon acts only in stuck state. Measured: one keypress, picture back in
about 4 s. Hotplug and keypress runs first wait up to 8 s for output to return by itself
(TV wake, desktop DPMS-on) and re-drive only when it stays `connected` but disabled; journal
tag `h96-display-wake` names each decision. Re-drive drops RandR output for about 1 s, and
some X clients exit on that.

### `h96-hdmi-hotplug`  (`/usr/sbin`, needs root)
Follows display change without reboot. On HDMI hotplug, `h96-hdmi-hotplug.service` waits until
connector state holds for 2 s, reads display EDID over `i2c-ddc` and compares it with display of
last detect and with EDID kernel uses. Same display with its EDID loaded: nothing done (TV
standby, DPMS off, resume, cable wiggle). Disconnected or EDID unreadable: nothing done. New
display, or kernel EDID lost: `h96-display detect` (kernel EDID with display's modes, HDMI audio
layouts and passthrough, CEC physical address), desktop re-probe (Wayland: change event on DRM
card; X11: detect re-probes X, so KDE display settings list new modes; current mode set again
only when no longer offered), `h96-display session-apply` (stored colour and range),
`h96-scdc apply` and `h96-cec phys-addr auto` while their services run. Same display after
failed load is not retried until EDID or kernel state changes. Record:
`/var/lib/h96/hdmi-hotplug.json`. Detect at boot (`h96-hdmi-audio-detect.service`) is unchanged.

```bash
h96-hdmi-hotplug status          # switch, connector, detected display, kernel EDID, last event
sudo h96-hdmi-hotplug off        # hotplug does nothing; detect at boot and by hand only
sudo h96-hdmi-hotplug on         # default
journalctl -u h96-hdmi-hotplug   # decision of each hotplug
```

### `h96-vrr`  (`/usr/sbin`, needs root)
HDMI variable refresh switch, off by default; works in Plasma X11 session (tested: FreeSync active,
no blanking). Not in Wayland session: KWin Adaptive Sync blanks display (8.1 item). Kernel EDID keeps display's FreeSync range block (AMD VSDB) and HDMI 2.1 VRR range
in every mode (see `h96-display edid`). `on` installs Xorg `VariableRefresh` option
(`/etc/X11/xorg.conf.d/30-h96-vrr.conf`, flag `/etc/h96/display-vrr.on`); `off` removes both.
Change applies at next X start. Kernel side (6.12): FreeSync infoframe for fullscreen
page-flipping windows with `_VARIABLE_REFRESH=1`.

```bash
h96-vrr status                   # switch, Xorg option, EDID VRR blocks, kernel FreeSync parameter, vrr_capable
sudo h96-vrr on                  # Plasma X11 session
sudo h96-vrr off                 # default
```

### `h96-scdc`  (`/usr/sbin`, needs root)
HDMI 2.0 scrambling check and HDMI 2.1 FRL link check behind `h96-scdc.service`. After
every modeset above 340 MHz it writes sink SCDC scrambling register over `i2c-ddc` and
verifies scrambler, clock and lane lock; without lock it switches back to last working
mode through KDE, at most once per 15 s. `h96-display hdmi20 off` stops service.

```bash
sudo h96-scdc status              # current clock, link mode, sink SCDC registers
sudo h96-scdc apply               # one evaluation now, no revert
sudo h96-scdc set-mode 1920x1080@60   # switch mode through KDE (xrandr without session)
sudo h96-scdc --selftest          # host tests with mocked registers, changes nothing
```

---

## Networking

### `h96-wifi-connect`
Join WiFi network. WiFi on this box does not use NetworkManager: chip needs
association handshake NetworkManager cannot produce, so `wlan0` is driven by
standalone `wpa_supplicant` instead. This command drives that path.

```bash
sudo h96-wifi-connect "Your SSID" "your-password"
sudo h96-wifi-connect "Your SSID"     # prompts for password
sudo h96-wifi-connect                 # no arguments: scan and list visible networks
wpa_cli -i wlan0 status               # current association and IP
```

Tray applet (`wpa_gui`) is also started automatically on KDE for same purpose.

### `h96-wifi-diag`
Collect WiFi diagnostics in one shot: interface state, driver and firmware, association
status, DHCP, and relevant service logs. Run this first if WiFi is not working, and
include its output in any bug report.

```bash
sudo h96-wifi-diag
```

### `h96-wol` (v6.2, off by default)
Wake-on-LAN (magic packet) on Ethernet. `on` sets `ethtool` at once and enables
`h96-wol.service`, which sets it again at each boot. NetworkManager profile changes only when
saved on disk (keyfile or netplan file), since NetworkManager applies its `wake-on-lan` value at
each connection. Automatic in-memory profile (`Wired connection 1`) is never modified, so
`h96-wol` writes no netplan or NetworkManager file for it. `off` reverses each step.
`h96-wol.service` starts when `eth0` appears, so boot never waits for absent `eth0`. `status`
prints `wol: on` or `wol: off` first: `ethtool` Wake-on value as root, boot unit state otherwise.
Magic packet must name address in use. `status` prints `eth0 address` (address in use; locally
administered address = random, cloned or set by boot loader), `eth0 permanent address`
(`ethtool -P`) and `cloned-mac-address` of each wired NetworkManager profile. When address in
use differs from permanent address, `on` sets `cloned-mac-address permanent` on saved wired
profile (address changes at next connection; DHCP may hand out new IP) and only warns for
in-memory profile. `off` leaves `cloned-mac-address` as is.
Toggling logs no kernel warning on v6.2 kernel. Wake from powered-off box is untested.

```bash
sudo h96-wol on            # enable
sudo h96-wol off           # disable
h96-wol status             # wol: on|off, then ethtool (root), boot unit, addresses, wired profile, cloned MAC
```

### `h96-hotspot` (v6.2, off by default)
Turns `wlan0` into Wi-Fi access point through NetworkManager. Client Wi-Fi
(`h96-wifi-connect`) pauses while hotspot is on and resumes on `off`; `eth0` and SSH are
never touched. Needs `dnsmasq-base`, which image installs from offline repo after first boot.

```bash
sudo h96-hotspot on [--ssid NAME] [--password PW] [--band a|bg] [--channel N]
sudo h96-hotspot off       # stop, return wlan0 to client path
h96-hotspot status         # SSID, band, channel, connected clients
h96-hotspot qr             # Wi-Fi QR code for saved SSID and password
sudo h96-hotspot forget    # stop, delete saved connection and config
```

Defaults: SSID `H96-<last 4 of MAC>`, random 12-character password, band bg, channel 6.
`h96-hotspot-repair.service` (enabled) restores Wi-Fi client mode at boot when box
rebooted with hotspot on.

---

## Video

mpv decodes on VPU without frame copy-back: `/etc/mpv/mpv.conf` sets
`hwdec=rkmpp,rkmpp-copy` with `vo=gpu` and `gpu-api=opengl`, so decoded frames go to
Mali GPU as DMA buffers (rkmpp zero-copy), then `rkmpp-copy`, then software decode as
fallbacks. 10-bit streams (HEVC Main10, VP9 profile 2, AV1 10-bit) fall back to software
decode (AV1 through libdav1d). AV1 8-bit decodes on VPU up to 3840x2160 60 Hz; decoder frame
queue (`vd-queue-enable=yes`, `vd-queue-max-samples=8`) holds 4K60. YouTube in mpv prefers
8-bit VP9, then AV1 SDR, then other codecs. Fullscreen
video bypasses KWin compositing (`x11-bypass-compositor=fs-only`). Measured on 1920x1080
TV: YouTube 4K60 VP9 8-bit, 1 dropped frame in 30 s; 4K60 H.264 file, 2 dropped frames in
30 s. RGA filters `scale_rkrga` (ffmpeg, mpv) and `vpp_rkrga` (ffmpeg) run from v7.1
kernel on; `overlay_rkrga` not yet tested.

mpv started while X11 display sleeps (DPMS off) wakes display when file with video track
loads: `/etc/mpv/scripts/h96-dpms-wake.lua` (`xset dpms force on`; skipped for audio-only
playback and outside X11).

### `h96-watch-mpv`
Play file or URL fullscreen with hardware video decode on RK3588 VPU, on X11 desktop.
Output and decode settings come from `/etc/mpv/mpv.conf`; URLs are capped at 1080p with
8-bit VP9 first, then AV1 SDR.

```bash
h96-watch-mpv /path/to/video.mkv
h96-watch-mpv "https://www.youtube.com/watch?v=..."
h96-watch-mpv --help
```

Without argument it prints usage and exits 2.

### `h96-encode`

Hardware video **encoding** on VPU. Silicon (RKVENC/RKVENC2/JPGENC) and ffmpeg
encoders were present from start; nothing exposed them until v4.0.

This is **only** encode path on box: bundled ffmpeg has no `libx264`.

```
h96-encode INPUT OUTPUT [options]

  -c, --codec   h264 | hevc | mjpeg     (default: h264)
  -b, --bitrate RATE                    (default: 8M)
  -s, --scale   WxH                     hardware-scale before encoding
  -q, --quiet                           no banner, no progress
  -l, --list                            show the available hardware encoders
```

Measured on H96 Max V58: 1080p at better than 180 fps for both H.264 and HEVC.

```
h96-encode clip.mkv out.mp4                 # H.264 at 8 Mb/s
h96-encode clip.mkv out.mp4 -c hevc -b 6M   # HEVC
h96-encode clip.mkv small.mp4 -s 1280x720   # scale on RGA, then encode
```

If audio stream cannot be copied into target container it is re-encoded to AAC
automatically. Requires `/dev/mpp_service`, which is present in this image.

### `h96-upscale`

GPU upscaling for mpv, using **ravu-lite-ar-r4** (from bjin/mpv-prescalers, LGPL-3.0) as
user shader on Mali-G610 through Panfrost.

```
h96-upscale               show state
sudo h96-upscale on       enable it in /etc/mpv/mpv.conf
sudo h96-upscale off      remove it again
h96-upscale test [file]   time playback with the shader on vs off (needs connected display)
```

`test` exits 1 with mpv's error when mpv does not start or does not play clip. `test` refuses
with exit 1 when no display is connected: mpv then renders about one frame per second, so
timings are not valid. Shader engages only when output is above 1.41x of video size in both
directions; below that, `test` prints note, and on and off times match.

`on` appends marked block to `/etc/mpv/mpv.conf` and keeps backup at
`mpv.conf.pre-h96-upscale`; `off` removes exactly that block, restoring file
byte-for-byte. Both are idempotent.

**Measured on this board** (720p clip, `--untimed`): no shader 3.81 s → ravu 4.31 s, about
**10-13% more GPU time**. Shader compiles clean on Panfrost with zero GLSL errors.

**Why this shader and not well-known ones.** G610 measures around 470 GFLOPS, roughly
9-19× below desktop cards FSRCNNX and nnedi3 are usually demonstrated on; neither fits
budget here. ravu-lite does, and is still visibly better than built-in scalers.

**Two things worth knowing:**
- **`gather/` variant of this shader does not work** on this box. It needs
  `textureGatherOffset`, which this GLES context does not provide (`error: no function with
  name 'textureGatherOffset'`). Image includes root variant.
- It needs **desktop or compositor session**; image boots to console until desktop is
  installed. `h96-upscale test` falls back to `cage` when no session is present, but note
  cage does **not** engage rkmpp hardware decode, so that path measures shader cost only, not
  playback.

### `h96-mpv-kiosk`
Same hardware-decoded playback, fullscreen inside nested Wayland compositor
(`cage`). This is lowest-CPU playback path on this box.

```bash
h96-mpv-kiosk /path/to/video.mkv
```

Run from text console with file or URL; application menu has no entry for it.

### `ff2mpv` and `play-with-mpv`
Browser integration. Install **ff2mpv** extension in Firefox or Chromium and its
button hands current video to mpv for hardware decoding, instead of browser
decoding it in software. Browser video decode itself stays on CPU (Ubuntu's Chromium
is built without V4L2 decoder this hardware needs), which is why this button exists.
ff2mpv also adds right-click → Play in MPV. When mpv does not start, ff2mpv shows desktop
notification with reason (missing libraries listed) and returns error to browser; mpv
output: `$XDG_RUNTIME_DIR/ff2mpv-<uid>.log`.

Chromium's h264ify extension keeps YouTube in browser at H.264, up to 1080p. For higher
resolution use ff2mpv, or untick "Block VP9" in h264ify options (software decode in
Chromium).

### `yt-dlp`
Bundled copy at `/var/lib/h96/bin/yt-dlp`, updated automatically 15 minutes after each boot and
every week by `h96-ytdlp-update.timer`, because YouTube changes often enough that pinned
version stops working. mpv and ff2mpv call this copy; `yt-dlp` on `PATH` is distribution package.

---

## Performance and monitoring

### `scrumptop`
Full-screen terminal system monitor.

```bash
scrumptop                  # live view, 1s refresh
scrumptop --interval 0.5   # custom refresh
scrumptop --snapshot       # print one frame and exit (for scripts/SSH captures)
```

Panels: CPU per-core (A76 = CPU1-4, A55 = CPU0,5,6,7; each bar carries its cluster's
temperature gauge), memory, GPU, NPU (3 cores), network (Ethernet link speed and rates,
WiFi, Bluetooth, IR remote activity), system (disk, eMMC I/O rates, swap, load, uptime,
peripheral batteries).

Keys: `q` quit, `p` pause, `h` help, `b` run/stop 3-core NPU benchmark in-app,
`+`/`-` step polling rate (0.25 s to 10 s presets).

### `h96-bench`
Benchmark and thermal monitor.

```bash
h96-bench --monitor        # live readout, 1s interval
h96-bench --scan           # list all voltage rails
h96-bench --freqs          # CPU/GPU frequency tables and governors
h96-bench --cpu            # CPU stress, 30s (--quick: 10s)
h96-bench --gpu            # GPU glmark2, 30s (--quick: 10s)
h96-bench --combined       # CPU+GPU, 60s (--soak: 180s thermal soak)
h96-bench --idle           # idle baseline, 30s
h96-bench --help           # all modes
```

Root-only modes: `--fix-perf` (big cores to their OPP maximum plus performance
governor), `--apply-tune` (apply saved profile from `/etc/h96-tune.conf`, which is
what `h96-tune.service` runs at boot), and `--set-maxfreq <MHz>` (big-core cap saved to
`/etc/h96-tune.conf`, applied in balanced and power-saver; performance keeps top OPP; `0`
clears cap).

Logs land in `/var/log/h96-bench/`.

> **`--tune` and `--set-volt` do not work on this board.** They try to set CPU voltage
> through `/sys/class/regulator/.../microvolts`, which kernel makes read-only. Voltage
> is owned by device tree's OPP table, not by userspace. To change it, use
> `h96-undervolt` below, which edits device tree. See **Known Limitations** in
> `README.md`.

### Thermal trip points and throttling

What `h96-bench` and `scrumptop` are reading. From `/sys/class/thermal/` on this box:

| Zone                 | Passive trip | Second passive trip | Critical |
|----------------------|--------------|---------------------|----------|
| `soc-thermal`        | 80 °C        | 95 °C               | 115 °C   |
| `bigcore0-thermal`   | 75 °C        |                     | 115 °C   |
| `bigcore1-thermal`   | 75 °C        |                     | 115 °C   |
| `littlecore-thermal` | 75 °C        |                     | 115 °C   |
| `center-thermal`     | 75 °C        |                     | 115 °C   |
| `gpu-thermal`        | 75 °C        |                     | 115 °C   |
| `npu-thermal`        | 75 °C        |                     | 115 °C   |

Registered cooling devices: `cpufreq-cpu0`, `cpufreq-cpu1`, `cpufreq-cpu3`,
`devfreq-fb000000.gpu`. Passive trip scales frequency down, CPU clusters through cpufreq
and GPU through devfreq. 115 °C critical trip triggers emergency shutdown.

**Measured on this board:** idle about 52 to 61 °C. Sustained all-core load under
`performance` governor reached 85 °C, above 80 °C `soc-thermal` passive trip, so
box throttles under sustained all-core load. Expected for this SoC in this chassis, not
fault. `h96-bench --combined --soak` (180 s) is mode that reproduces it.

Related: `scrumptop` for live per-cluster temperatures with session min/max, `h96-perf`
and power profiles for CPU and GPU governors that set how much heat load makes,
`h96-npu power powersave` to park NPU at 300 MHz, and `h96-undervolt` for per-chip
voltage trials.

### `h96-perf`
Terminal front end for system power profile, same setting as panel applet (power
profiles below). It does not print temperature; use `h96-bench --monitor` or `nvtop`.

```bash
h96-perf                   # same as: h96-perf status
h96-perf status            # power profile, per-core CPU governor, GPU governor, range and clock
h96-perf on                # also: performance
h96-perf off               # also: balanced, schedutil
h96-perf saver             # also: power-saver, powersave
```

| Mode                                | Profile            | Big cores     | Little cores | GPU                     |
|-------------------------------------|--------------------|---------------|--------------|-------------------------|
| `on`, `performance`                 | `performance`      | `performance` | `schedutil`  | 600-1000 MHz            |
| `off`, `balanced`, `schedutil`      | `balanced`         | `schedutil`   | `schedutil`  | 300-800 MHz             |
| `saver`, `power-saver`, `powersave` | `power-saver`      | `schedutil`   | `schedutil`  | 300-600 MHz             |
| `status` (default)                  | prints, changes nothing |          |              |                         |

`h96-perf` calls `powerprofilesctl set`. Profile service accepts change from root or
from active local desktop session (desktop terminal, panel applet); SSH and console
logins need `sudo`. Change is not persistent: boot returns to `balanced`.
`h96-perf --help` prints usage; unknown argument exits 2.

### `h96-boot-profile`
Capture `systemd-analyze` boot report (summary, `blame` top 30, and `critical-chain`)
to `/var/log/h96-boot-profile.txt`. Useful when boot takes longer than usual 7 seconds
and you want to know which unit is responsible.

```bash
sudo h96-boot-profile      # without root it prints report but cannot write log file
```

### `nvtop`
Live GPU monitor, aware of Mali GPU through open Panthor driver: frequency,
utilisation, memory and temperature. Works over SSH.

```bash
nvtop
```

Since v3.4 image includes `nvtop` as package in baked offline repo at
`/opt/h96-pkgs`, and is installed by `/usr/lib/h96/h96-desktop-fixup.sh`. It is no longer fetched from
internet, so box set up without working connection still gets it. On headless
box that has never had desktop configured, run `sudo /usr/lib/h96/h96-desktop-fixup.sh`, or
`sudo apt install nvtop`.

### Power profiles
Performance, Balanced and Power-Saver scale CPU governors and GPU frequency
ceiling together. Set them from KDE battery applet or GNOME power menu; they are
served over D-Bus by `h96-power-profiles.service`. Profile changes and holds are
accepted from root or from active local desktop session; other callers (SSH, console,
system accounts) get `AccessDenied`. Program can hold `performance` or `power-saver`
for its run time, released when it exits; as Steam launch option:
`powerprofilesctl launch -p performance -r game -- %command%`. Explicit profile change
drops all holds. Hold is released only by program that made it, or by root.

| Profile       | Big cores     | Little cores | CPU floor | CPU cap (big / little) | CPU deep idle (`cpu-sleep`) | GPU          | DDR (6.12 kernel)    |
|---------------|---------------|--------------|-----------|------------------------|-----------------------------|--------------|----------------------|
| `performance` | `performance` | `schedutil`  | 1200 MHz  | top OPP                | off                         | 600-1000 MHz | pinned at top rate   |
| `balanced`    | `schedutil`   | `schedutil`  | 1200 MHz  | top OPP                | off                         | 300-800 MHz  | scales from lowest   |
| `power-saver` | `schedutil`   | `schedutil`  | 408 MHz   | 1800 / 1416 MHz        | on                          | 300-600 MHz  | scales from lowest   |

Boot profile is always `balanced`: profile service applies it before display manager
starts (`/usr/lib/h96/h96-power-profiles.py --apply balanced`), after `h96-tune.service` has set
voltage and big-core maximum from `/etc/h96-tune.conf`. Board device tree carries
`cpu-sleep` idle state and 408, 600, 816 and 1008 MHz CPU steps; only `power-saver` uses
them. Every profile switch and every hold start or end re-applies governors, CPU floor,
idle state, GPU range and DDR floor, and sets CPU maximum (big-core cap from
`/etc/h96-tune.conf` in balanced and power-saver; power-saver caps big cores at 1800 MHz and
little cores at 1416 MHz, lower cap wins). DDR row applies where kernel has DDR frequency
scaling (`/sys/class/devfreq/dmc`, 6.12 kernel); 6.1 kernel has none and skips it. `/etc/default/cpufrequtils` stays disabled (`ENABLE="false"`)
and names `GOVERNOR=schedutil` for `armbian-hardware-optimize`, which stays disabled after
first boot (board support package that enables it is removed); profile service owns CPU
clocks. eMMC uses kernel default I/O scheduler `mq-deadline`.

---

## GPU driver

Boot 1 and every later boot run kernel on Panthor device tree with Panthor GPU driver and Mesa
(Panfrost GL, PanVK Vulkan).

### `panthor-revert.sh`  (`/usr/lib/h96/panthor`, needs root)

```
sudo /usr/lib/h96/panthor/panthor-revert.sh && sudo reboot          GPU driver off: software GL (llvmpipe), KWin uncomposited
sudo /usr/lib/h96/panthor/panthor-revert.sh --undo && sudo reboot   GPU driver on again
```

Off writes `/etc/modprobe.d/h96-gpu-off.conf` (`install panthor /bin/false`), removes
`/etc/modules-load.d/panthor.conf`, adds `modprobe.blacklist=panthor` to `extraargs` in
`/boot/armbianEnv.txt` (initramfs carries driver too) and drops `KWIN_COMPOSE=O2ES` from
`/etc/environment` (forced GLES compositing makes KWin exit on software GL). Kernel, device
tree and Mesa stay; desktop runs on software GL, KWin runs as window manager without
compositing. `/usr/lib/h96/h96-kde-configure.sh` run while driver is off leaves `KWIN_COMPOSE` out.
Waydroid `gpu` profile, Steam ARM GPU routes and GPU emulators need Panthor. `--undo` reverses
only these four changes (`KWIN_COMPOSE=O2ES` returns when off step or `/usr/lib/h96/h96-kde-configure.sh`
held it back). No stock kernel is in image from v7.1 on; boxes on v7.0 keep their rescue
kernel and v7.0 revert script.

### `h96-vulkan-wsi`  (`/usr/sbin`, needs root for `on` and `off`; package `h96-vulkan-wsi`, off by default)
Patched PanVK Vulkan driver for Plasma Wayland session (experimental). Stock Mesa Wayland
presentation treats KWin main device (rockchip-drm render node) as other GPU and copies every
frame into linear buffer; patched driver asks driver presentation check instead and hands
swapchain images to KWin without copy. Driver sits beside stock Mesa in
`/usr/lib/h96/vulkan-wsi` with own ICD file; stock driver stays in place. Package depends on
`mesa-vulkan-drivers` 26.1.4~kisak1~r exactly (`/usr/lib/h96/vulkan-wsi/mesa-pin`) and blocks
other versions.

```bash
h96-vulkan-wsi status            # switch, Mesa pin and installed version, session, driver in running session
sudo h96-vulkan-wsi on           # experimental; Plasma Wayland session only
sudo h96-vulkan-wsi off          # default
```

`on` refuses (exit 1) unless Plasma Wayland session is active and installed
`mesa-vulkan-drivers` equals pin; it writes flag `/etc/h96/vulkan-wsi.on`. Change applies at
next Plasma Wayland login: `/etc/xdg/plasma-workspace/env/h96-vulkan-wsi.sh` exports
`VK_DRIVER_FILES` (and `VK_ICD_FILENAMES`) for session, so desktop apps and Steam ARM games
started from it use patched driver. X11 logins, other Mesa versions and switch off keep stock
driver. `h96-game-mode` keeps patched driver for its Wine games while switch is on in Plasma Wayland
session (same Mesa pin check), stock driver otherwise. Purge removes flag.

---

## NPU (3-core, 6 TOPS nominal)

NPU has been fully working at kernel level since vendor BSP. Until v4.0 nothing
in userspace reported or used it.

### `h96-npu`

```
h96-npu               status: driver version, per-core load, frequency, runtime
h96-npu watch         live per-core load
h96-npu max           pin to the highest OPP        (root; resets on reboot)
h96-npu <MHz>         pin to a specific OPP         (root; resets on reboot)
h96-npu auto          restore the full range        (root)
h96-npu bench [iters] one-core INT8 matmul; prints GOPS      (needs h96-npu-setup)
h96-npu bench all [n] one job per core 0/1/2; aggregate TOPS (whole NPU)
h96-npu power         power profile: governor, frequency, what boot restores
h96-npu power <prof>  performance | balanced | powersave     (root; persists)
h96-npu power sync    match the NPU to the active system power profile  (root)
h96-npu power sync on|off   follow the power profile from now on   (root; persists)
```

`bench` runs 256×4096×4096 INT8 matmul through `librknnrt`. Measured on this board:
about 625 GOPS on one core. `bench all` pins one job per core (0/1/2): about 1.29 TOPS aggregate.
Aggregate is about 2x one core, not 3x, because large matmuls are DRAM-bandwidth-bound here
(NPU has no SRAM, see below); compiled multi-core `.rknn` models with weight reuse scale
better. To use all 3 cores from your own code: convert model multi-core with
rknn-toolkit2, or run 3 inference contexts each pinned to core (0/1/2), since auto mode
packs onto core 0. bench is inference submission, so NPU power domain resumes and idles
back down on its own; `/proc/rknpu/power` reading `off` at idle is normal.

Frequency argument is validated against kernel's own OPP list, so typo cannot set
something hardware does not support. On this board: driver `v0.9.8`, IOMMU mode, 8 OPPs
from 300 to 1000 MHz, kernel default governor `rknpu_ondemand` (image default `powersave`),
exposed as `/dev/dri/renderD129`.
default user is already in `render` group, so inference does not need root.

**`power` (v5.0).** Sets NPU devfreq governor, validated against kernel's own
`available_governors` list, and drops `/etc/udev/rules.d/99-h96-npu-power.rules` so
choice is re-applied on every boot.

```
sudo h96-npu power performance   pin the top OPP; use this for RKNN work
sudo h96-npu power balanced      rknpu_ondemand, kernel default governor
sudo h96-npu power powersave     park at the bottom OPP (300 MHz)
h96-npu power status             current governor, frequency, what boot restores
```

On 7.x kernels `rknpu_ondemand` idles at 300 MHz while no NPU job runs (measured); earlier
kernels held 1000 MHz for whole uptime, which is why profile exists. Image default is
`powersave` (rule written at build), parked at 300 MHz; `balanced` hands NPU back to kernel
default. Switch to `performance` before running inference.

**`power sync`.** System power profile (`h96-perf`, panel applet) covers CPU and GPU
only. `power sync` reads active profile (`powerprofilesctl get`, governors as fallback)
and matches NPU to it: `performance` for performance, `powersave` for power-saver,
`balanced` otherwise.

```
sudo h96-npu power sync       one-shot: match the NPU to the current power profile
sudo h96-npu power sync on    keep it in step from now on
sudo h96-npu power sync off   stop following the power profile
```

`sync on` writes `/etc/h96/npu-follow`. While that file exists, `h96-perf` run as root
(`sudo h96-perf ...`) runs sync itself after every profile change; `h96-perf` without
root and panel applet leave NPU alone. `sync off` deletes file.

**`could not find sram resource!` in `dmesg` is expected and is not fault.** RK3588 system
SRAM is allocated in full to two video decoders (`0x78000 + 0x77000 = 0xEF000`, whole
region, zero free). NPU runs from DRAM. Giving it SRAM would mean taking it from hardware
video decode.

### `h96-npu-setup`  (`/usr/sbin`, needs root)

Installs Rockchip RKNN inference runtime **on demand**.

```
sudo h96-npu-setup                     interactive; shows the licence first
sudo h96-npu-setup --accept-license    non-interactive
sudo h96-npu-setup --uninstall         remove it again
```

Runtime is **not** bundled with this image and that is deliberate. `librknnrt.so` is
proprietary Rockchip software under "RKNN SDK License", whose clause 1.2 permits
reproducing copies "on internal basis only". This image is published publicly under
GPL-2.0, so it cannot carry that binary; build fails on purpose if it is ever found
inside image. `h96-npu-setup` fetches it from Rockchip, shows you their licence, and
checks download against pinned SHA-256 (runtime 2.3.2, rknn-toolkit2 commit `59a913d1`)
and checks it is aarch64 shared object before installing anything.

Verified: runtime `2.3.2` installs and loads against driver `v0.9.8`.

**Python limitation.** Rockchip publishes `rknn-toolkit-lite2` wheels only up to CPython
3.12. This image is Armbian on Ubuntu 26.04 with Python 3.14, so those wheels will not install
against system interpreter. Use C API (link `-lrknnrt`), or bring CPython ≤ 3.12
of your own in venv or container. Converting model to `.rknn` runs on PC, as it always
has.

## Undervolting (opt-in, inert at flash)

### `h96-kernel-switch`  (`/usr/sbin`, needs root for changes; v8.0)

Selects boot kernel. v8.0 image carries default kernel 6.12.69 (`6.12.69-h96v58-8.0`)
and fallback kernel `6.1.172-h96v58-8.0`, staged by packages `h96-kernel-<release>` and
`h96-dtb-<release>` under `/usr/lib/h96-kernel/<release>/` (modules in
`/usr/lib/modules/<release>/`). Kernel packages never write `/boot`. `try` writes kernel,
fresh `uInitrd` and device tree into generation directory `/boot/h96ks/<release>.g<n>`;
`/boot/Image`, `/boot/uInitrd` and (once device tree differs) board DTB link through
`/boot/h96ks/cur`, so one rename switches all three and power loss never leaves mixed set.
Boot guard points `h96ks/cur` back to previous generation at start of trial boot unless
`confirm` runs in that boot; guard also completes interrupted `confirm` and `rollback`.
Never writes `boot.scr` or `armbianEnv.txt`; refuses short `/boot` free space, existing
`/boot/extlinux` and Image whose embedded release differs.
Same release, new content: `try` makes new generation (`<release>.g<n>`, lowest free number;
numbers are reused after `prune`) when staged Image
or DTB differs from in-boot generation, and refuses when both are equal; `list`, `status`,
`in-use` and `prune` name generations.
Module tree per kernel build: builds of one release share
`/usr/lib/modules/<release>`, and package upgrade replaces it. Tool keeps tree of each staged
build under `/var/lib/h96-kernel-switch/modules` (hard links; apt saves it before dpkg runs).
At boot, before udev, `h96-kernel-switch-modules.service` mounts saved tree of running build
read-only when package tree belongs to other build, so fallback and rollback load own modules.
`try` of other build of in-boot release refuses without saved tree of in-boot build.

```
h96-kernel-switch list                       staged kernels: running, default, in-boot, trial
h96-kernel-switch status                     default release, link targets, recorded trial, last results
h96-kernel-switch default                    release that boot files start
sudo h96-kernel-switch try <release>         new generation, trial recorded, guard armed; reboot next
sudo h96-kernel-switch try <release> --auto-confirm   trial confirms itself 180 s after boot (multi-user.target active)
sudo h96-kernel-switch confirm               in trial boot: keep trial kernel as default
sudo h96-kernel-switch rollback              cancel recorded trial, or back to default before last confirm
sudo h96-kernel-switch prune <release>       remove generations of one kernel unless links or records name it
h96-kernel-switch in-use <release>           roles: default, trial, trial-previous, rollback-target
h96-kernel-switch dtb                        board DTB path, layout (plain, managed, link), file; read only
sudo h96-kernel-switch dtb-plain             managed DTB link back into plain file
sudo h96-kernel-switch snapshot-modules      save module tree of each staged build (apt does it before dpkg)
sudo h96-kernel-switch repair-modules        running build without own modules: mount saved tree or tree from apt cache deb
```

Guard unit and confirm timer stay disabled until first `try`. Kernel package postinst shows
`try` hint unless release is already default or on trial; prerm blocks removal of running,
default, trial or rollback kernel. Coexists with `h96-undervolt` (see below). Manual:
`man h96-kernel-switch`.

### `h96-undervolt`  (`/usr/sbin`, needs root)
Lowers CPU voltage **for your specific chip**. RK3588 measures every individual chip
at boot and assigns it one of eight voltage bins, so there is no single value that could
be baked into shared image. This tool reads your bin, takes vendor's voltage for
that bin, and subtracts your offset from it. It edits device tree, which is only
place this voltage can be changed from.

**Nothing is undervolted unless you ask for it.** Out of box tool has done
nothing.

```bash
sudo h96-undervolt status      # your bin, its vendor voltage, floor, headroom (read-only)
sudo h96-undervolt set 15      # subtract 15 mV, and arm a one-boot trial
sudo reboot
sudo h96-undervolt test        # 60s NEON/SIMD load across all cores
sudo h96-undervolt confirm     # keep it, otherwise it reverts on next boot
sudo h96-undervolt revert      # back to vendor voltages, then reboot
sudo h96-undervolt revert --force  # stock backup although device tree changed outside tool
```

Trial is safety net: `set` arms `/var/lib/h96-undervolt-trial`, and if you do not
`confirm`, `h96-undervolt-trial.service` restores stock device tree early on next
boot. Tool also refuses to go below lowest voltage vendor tables list for
that frequency, and always derives from pristine backup, so repeated `set` calls
cannot compound. `status` writes nothing; first `set` or `oc` creates stock backup.

What trial cannot do is rescue value so low kernel never reaches userspace. If
that happens box will not boot and you will need to reflash it over USB in Maskrom
mode. Move in steps of 10 to 15 mV.

**Read `/usr/share/doc/h96-tools/README.undervolt.md` before using this.** It covers per-chip bin table, why
shell busy-loop is not valid stability test, and silent-miscomputation failure mode
that does not announce itself. It is not repeated here.

Files: `/boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb` (active),
`...panthor.dtb.stock-backup` (vendor tree, written by first `set` or `oc`, kept forever),
`/var/lib/h96-undervolt-trial`, `/var/lib/h96-undervolt-state`.

With `h96-kernel-switch`: `set`, `oc` and `revert` write plain DTB file only and refuse while
boot DTB links into kernel generation (`h96-kernel-switch dtb` prints `layout=managed`;
`sudo h96-kernel-switch dtb-plain` turns link back into plain file). `set` and `oc` refuse while
kernel trial is recorded, and `h96-kernel-switch try` refuses while undervolt trial is recorded.
`h96-kernel-switch try` refuses DTB change while `set` or `oc` change is active: run
`h96-undervolt revert` first, or `try KREL --keep-dtb` keeps modified DTB. Device tree that
differs from stock backup with no change recorded (new kernel DTB): `set` and `oc` refuse,
`revert` needs `--force`.

---

**Measured on this board:** every offset up to −50 mV cap was stable, but
thermally-matched comparison showed **−50 mV costs 4.4% performance to save 1 °C**
(stock 3758.40 events/s at 962/975 mV, versus 3594.62 at 912/925 mV, same verified 2208 MHz).
Combined with overclock result (+8.7% clock → +0.53% work), **both directions are
net-negative on this hardware and stock is right setting.** Tool remains available
because silicon varies and you may want to check your own chip.

When measuring: `revert` only applies after reboot, voltage is field 6 of
`regulator_summary` (field 5 is `opmode`), it must be read under load with clock pinned,
and runs must start from matched temperature.

#### `h96-undervolt oc [mhz] [mV]`

Adds higher CPU operating point. Vendor device tree stops A76 clusters at
2208 MHz; this clones that node to new frequency. Default is **2400 MHz at 975 mV**,
only combination validated on this board. It refuses anything above 2400 MHz or 1025 mV (
regulator's own ceiling is 1050 mV).

**It works, and it is not worth using.** Measured here: **+8.7% clock produced +0.53% work**
(3730.5 → 3750.2 events/s), with peak temperature rising 82 °C → 85 °C. Clock is
sustained (verified live and via `time_in_state`), but limit on this SoC is memory
bandwidth (about 21 GB/s), not core frequency.

When testing one, **pin to big cores**. 8-thread run hides effect completely,
because four A55s are unchanged and gate total. Topology is not contiguous:
`policy0` is cpus 0,5,6,7 (A55) and big cores are **1,2,3,4**.

```
taskset -c 1,2,3,4 sysbench cpu --threads=4 --time=15 run
```

`set` and `oc` edit same device tree, so only one may be active; each arms trial that
self-reverts on next boot unless you `h96-undervolt confirm`.

## Subtitles

### `h96-subtitles`

Generates timed `.srt` from any media file, on box.

```
h96-subtitles                       what is installed
h96-subtitles file VIDEO [options]  transcribe to VIDEO.srt
  -o, --out FILE      write somewhere else
  -e, --engine        auto (default) | cpu | npu
  -l, --lang          en (default) | zh-en
  -t, --threads N     default 1 - more measured SLOWER on this SoC
      --force         overwrite an existing .srt
h96-subtitles live                  (experimental, see below)
```

**Measured on this board**, film audio, one A76 core: **RTF 0.130, 7.7× realtime**.
2-hour film takes about 15 minutes and leaves seven cores free for playback. Accuracy: **WER
1.09%** on LibriSpeech test-clean (human ground truth); on 1936 film dialogue with music it
stays coherent and usable.

**It runs on CPU, and that is deliberate.** This was built to use NPU. Measured here
NPU *lost*:

| engine                     | RTF       |
|----------------------------|-----------|
| NPU (rknn, 3 cores)        | 0.271     |
| **CPU int8, ONE A76 core** | **0.124** |
| CPU int8, 4 A76 threads    | 0.147     |

One CPU core is **2.2× faster than whole NPU**, and more threads are slower; limit is
memory bandwidth, as everywhere else on this SoC. `--engine npu` exists for comparison.

### `h96-subtitles-setup`  (`/usr/sbin`, needs root)

```
sudo h96-subtitles-setup              install engine + English model
sudo h96-subtitles-setup --lang zh-en install engine + bilingual model instead
h96-subtitles-setup status            show installed parts (no download)
sudo h96-subtitles-setup --uninstall  remove everything it installed
```

Fetches **prebuilt** `sherpa-onnx` (28 MB) and model into `/var/lib/h96/subtitles`:
English model 310 MB, bilingual `zh-en` model 510 MB. Size is only reason they are not
bundled; all are Apache-2.0. **No compiler is needed.** Each archive is checked against
SHA-256 pinned in tool before extraction and recorded for later re-checks. Unknown
argument prints usage and exits 2 with no download.

### `h96-widevine-setup`  (`/usr/sbin`, needs root)

```
sudo h96-widevine-setup           install Widevine L3 CDM (browser DRM)
sudo h96-widevine-setup status    show install state
sudo h96-widevine-setup remove    remove everything it installed
```

Google publishes no Widevine CDM for generic ARM64 Linux, so browser DRM streams
(Discovery+, Netflix, Prime, Disney+) cannot play on this image by default.
This tool fetches AsahiLinux `widevine-installer` (MIT), which downloads
Chrome (LaCrOS) image from Google (about 150 MB), extracts ARM64 L3 CDM,
applies its glibc ELF fixups, and installs to `/var/lib/widevine`; tool then wires
Chromium (system-wide bundle dir, all users) and Firefox (`MOZ_GMP_PATH`).
Installer archive, LaCrOS image and resulting CDM are checked against pinned SHA-256
values; mismatch installs nothing.
CDM is proprietary Google software and is never bundled in this GPL-2.0
image; it is fetched on your request, same policy as `h96-npu-setup`.

LIMIT: this box is Widevine **L3** everywhere, Android firmware included.
DRM streams cap at SD (about 480p); factory trust chain L1 needs is absent and
no firmware adds it. Non-DRM video is unaffected. Verified on hardware: Chromium registers bundled CDM 4.10.2662.3 system-wide, Discovery+ plays at SD. Check other services at https://bitmovin.com/demos/drm.

### Live subtitles: experimental

`h96-subtitles live` is present but **not finished**. Each piece is verified separately:
streaming ASR runs at **2.5× realtime** with about 3.2 hypothesis updates/sec, and mpv overlay
renderer is protocol-verified (5/5 repeat draws on one persistent socket; mpv destroys
overlay moment its IPC client disconnects, so that persistence is whole design).

What is missing is environment: **PipeWire is not running on headless image** and
renderer needs display. Install desktop first. Command refuses with actionable errors
rather than pretending to work. Note also **640 ms algorithmic floor** (chunk-16 × 4 × 10 ms)
that no amount of CPU speed removes.

## Desktop

> Released image has no desktop and no user account. Install one with `armbian-config`
> (System, Desktop) or `apt install kde-plasma-desktop`. `h96-autologin.service` sets
> lightdm autologin on `plasmax11` (X11) session at next boot, one time, `sudo h96-autologin-setup`
> at once. X11 is default session. Plasma Wayland is offered as experimental option
> (`sudo h96-autologin-setup --session plasma`, or "Plasma (Wayland)" at login screen):
> 4K60 video drops frames there (X11 drops none), and display tools follow it as listed
> under **Plasma Wayland session** below.

### `h96-autologin-setup`  (`/usr/sbin`, needs root)

```
sudo h96-autologin-setup          autologin for first desktop account on plasmax11 (same as --on)
sudo h96-autologin-setup --off    remove H96 autologin drop-in; login screen asks for password
h96-autologin-setup --status      autologin user and session, or off
sudo h96-autologin-setup --session plasma     autologin into Plasma Wayland (experimental)
sudo h96-autologin-setup --session plasmax11  back to Plasma X11 (default)
```

**Plasma Wayland session** (experimental). Login screen lists "Plasma (Wayland)" beside
default "Plasma (X11)"; `--session plasma` makes it autologin session (needs
`/usr/share/wayland-sessions/plasma.desktop`, package `kwin-wayland`). Tools in that session:
`h96-scale` sets output scale through `kscreen-doctor`; `h96-display revert` and `native` switch
mode through `kscreen-doctor`; `h96-display color` applies through kernel EDID only; RGB range
control is not available there (KWin exposes no RGB range on HDMI-A-1 under kernel 6.12), so
`h96-display range` prints notice and changes nothing; `h96-display status` adds session and
kernel EDID lines; display wake asks
KWin for DPMS on (no X modeset re-drive); HDMI detect asks KWin to re-read connectors; mpv uses
`vo=dmabuf-wayland` (auto profile `h96-wayland` in `/etc/mpv/mpv.conf`); `h96-waydroid start`
runs Android natively in KWin window that can be resized (stop with "Stop Android (Waydroid)").
Known issue: 4K60 video drops frames on every Wayland output path. Proton games: KWin resets its GPU
context on panthor job timeouts (short freezes); play Proton titles in Plasma X11 session (see **Gaming**).

Drop-in: `/etc/lightdm/lightdm.conf.d/70-h96-autologin.conf`. Boot service runs `--boot`
once: it sets autologin when desktop account and Plasma session exist and records
`/var/lib/h96/autologin-set`; with that file present, or any LightDM file already naming
`autologin-user`, boot leaves autologin as it is. `--off`, `--on` and `h96-restore` set it
too, so choice stays across reboots. Unknown option exits 2. armbian-config autologin menu
acts on SDDM files, not on this LightDM drop-in.

### Screen locking, off by default (v5.0)

`/etc/skel/.config/kscreenlockerrc` sets `Autolock=false`, so KDE user created after
flash does not get locked out of their own TV box after idling. It is skeleton default:
it seeds new users only, and never overwrites setting existing user has already chosen.

Turn it back on in System Settings, Screen Locking, or by setting `Autolock=true` in your own
`~/.config/kscreenlockerrc`.

### `h96-desktop-fixup.sh`  (`/usr/lib/h96`, needs root)
Installs desktop pieces Armbian's `APT::Install-Recommends "0"` policy leaves out.
Every Debian/Ubuntu desktop metapackage puts large share of its function in Recommends,
so plain install on this image produces skeleton: no PipeWire session manager and
therefore no audio sinks at all, no network applet, no printer or Bluetooth module, and no
polkit agent, which is what makes Discover unable to install anything.

It is called automatically by `h96-kde-configure.service` and
`h96-gnome-configure.service`. It is idempotent and safe to run by hand on existing
install:

```bash
sudo /usr/lib/h96/h96-desktop-fixup.sh            # auto-detect installed desktop
sudo /usr/lib/h96/h96-desktop-fixup.sh --kde
sudo /usr/lib/h96/h96-desktop-fixup.sh --gnome
sudo /usr/lib/h96/h96-desktop-fixup.sh --none     # desktop-independent pieces only
```

It waits for dpkg lock rather than failing, reports every package individually instead
of hiding failures, and logs to `/var/log/h96-desktop-fixup.log`. It also installs
`nvtop`, `bluez`, and PipeWire and Bluetooth-codec packages.

### Desktop install and removal through `armbian-config`

Desktop install in `armbian-config` ends by starting display manager. Drop-ins
`/etc/systemd/system/sddm.service.d/zz-h96-handoff.conf` and
`/etc/systemd/system/gdm.service.d/zz-h96-handoff.conf` run `h96-dm-handoff` as
`ExecCondition` of that start: H96 desktop setup (`h96-kde-configure.service` or
`h96-gnome-configure.service`) runs first, and install's last step waits until it finishes,
with progress shown in `armbian-config` terminal (SSH or local console).

- KDE: SDDM start is skipped; desktop starts on LightDM with autologin. SDDM is masked after
  hand-off ends.
- GNOME: GDM starts once H96 GNOME setup is done.
- Other display manager starts (restart, autologin change, removal) pass straight through.
- Setup incomplete: log `/var/log/h96-kde-configure.log` or `/var/log/h96-gnome-configure.log`;
  setup runs again at next boot.

Desktop removal: apt hook `/etc/apt/apt.conf.d/99-h96-desktop-cleanup` runs
`h96-desktop-cleanup --check` after each dpkg run. When KDE or GNOME is gone, it queues
`h96-desktop-cleanup.service`, which waits for apt to go idle, undoes H96 desktop setup
(LightDM, KDE settings, kwin wrapper, masked SDDM) and re-arms it, so next install, also in
same boot, runs desktop setup again. LightDM and its greeter stay when another desktop's
session remains installed. PipeWire, Bluetooth and GPU libraries stay. Log:
`/var/log/h96-desktop-cleanup.log`. Both helpers are internal and hidden from `h96` index.

### `settings-launch`
Wrapper that starts GNOME Control Center with cairo renderer, and clears any stuck
instance first. Used by desktop's own Settings launcher.

---

## Media suite (opt-in)

Every media tool includes command plus its config only. First `enable` installs its
apt packages (from box's arm64 repos) and activates its service. Nothing auto-starts,
nothing is enabled at flash. Full mechanism: `docs/MEDIA-FEATURES.md` in GitHub repo
source (not installed on box).

### `h96-cec`
HDMI-CEC on HDMI0 (v6.2 kernel, `/dev/cec0`): TV remote controls box, and box puts TV
in standby and wakes it. Verified on Sony TV. `h96-cec.service` runs `h96-cecd`, which
maps CEC remote keys to uinput key events. On by default: remote works out of box with
CEC TV (CEC enabled in TV settings, named by brand, such as Bravia Sync, Anynet+ or
SimpLink). TV must show box's HDMI input: box claims active source on display wake and on
`h96-cec on`; TV on other input keeps remote keys. Unit starts when `/dev/cec0` appears
(enable link under `dev-cec0.device`): no CEC adapter, no start; no CEC TV, daemon idles.
Boot does not wait for it. Package enables unit once at install (marker
`/var/lib/h96/cec-default-on`); `systemctl disable` stays in effect across upgrades.
Key map: `/etc/h96/cec-keymap.conf` (CEC key name = `KEY_` symbol, only overrides needed;
`sudo h96-cec restart` applies). Back, Return and Exit send Escape (Steam Big Picture, dialogs).
Play, Pause, Stop, Fast Forward and Rewind send X11 media keys;
KDE media controller passes them over MPRIS, so TV remote Play/Pause/Stop/seek control mpv
(MPRIS plugin, loaded by `/etc/mpv/scripts/h96-mpris.lua` only when session bus exists)
and Chromium; Fast Forward and Rewind seek about 8 s
per press (KDE step per repeated remote event). Steam Big Picture navigates with arrows, Enter and
Back (Escape). Remote power
key puts box in standby (`systemctl poweroff`) only while `/etc/h96/cec-power-standby.on`
exists (off by default; at most once per 30 s); otherwise it sends `KEY_POWER`. Daemon needs `cec-ctl` (`v4l-utils`, installed by
`h96-pkgs-setup` 30 s after first boot, which then starts service).

```bash
sudo systemctl disable --now h96-cec.service  # turn off (on by default)
sudo systemctl enable --now h96-cec.service   # turn back on
h96-cec status             # CEC device, adapter, physical addresses, daemon state
h96-cec on                 # wake TV, make box active source
h96-cec off                # put TV in standby
h96-cec monitor            # live CEC bus traffic
h96-cec keys               # live view of keys remote sends (daemon log), Ctrl+C ends
h96-cec test               # ask TV who it is
sudo h96-cec restart       # restart h96-cec.service daemon
sudo h96-cec phys-addr [a.b.c.d|auto]   # set kernel CEC physical address
sudo h96-cec wake on|off|status         # TV on when display wakes (default on)
sudo h96-cec standby-on-blank on|off|status   # TV standby when display blanks (default off)
sudo touch /etc/h96/cec-power-standby.on      # remote power key: box standby (default off)
```

Display wake, on while service runs: when key or mouse wakes display from DPMS off, box
sends TV Image View On and Active Source; TV powers on and switches to box. Keypress
after 10 min idle does same, for TV put in standby with its own remote while display
stayed on. At most once per 10 s. Session watcher `h96-cec-wake` (XDG autostart) reports
display state to `h96-cecd` over `/run/h96-cec/wake.sock`; daemon accepts root and active
seat user only. Watcher stays running only while `h96-cec.service` is enabled or active, so
disabled CEC leaves no session poller; after `sudo systemctl enable --now h96-cec.service`,
display wake starts at next login. `standby-on-blank on` sends TV to standby when display goes DPMS off.
Settings are flag files, `/etc/h96/cec-wake.off` and `/etc/h96/cec-standby-on-blank`,
read per request (no restart) and kept by `h96-backup`.

Physical address comes from `h96-display detect`; service sets it before daemon starts.
On DVI monitor (EDID without CTA extension) `h96-cec status` reports
`no CTA physical address (DVI)`: CEC needs HDMI sink.
v6.1 kernel has no CEC adapter, so `/dev/cec0` exists only with v6.2 and later images.

### `h96-hdr`
mpv HDR10 handling. On desktop: tone-maps HDR10 to SDR with `vo=gpu-next` + libplacebo.
On HDR display: `play` shows HDR10 video full screen on free text console through KMS with
HDR metadata, then returns to desktop. Off by default.

```bash
sudo h96-hdr tonemap       # also: on; HDR10 to SDR BT.709, include line in /etc/mpv/mpv.conf (backup kept)
sudo h96-hdr setup         # list VP0 plane overlay in /boot/armbianEnv.txt; reboot (setup off: remove)
sudo h96-hdr play FILE     # HDR10 on text console (KMS, /etc/mpv/hdr-kms.conf), back to desktop on exit
sudo h96-hdr passthrough   # older verb: selects tonemap, points at play
sudo h96-hdr off           # remove exactly that include line
h96-hdr test [file]        # check vo=gpu-next renders frames (run in desktop session); exits 1 with reason when mpv does not start
h96-hdr status             # also: h96-hdr with no argument
```

Drop-in is `/etc/mpv/hdr.conf`; `test` uses same `gpu-api` as `/etc/mpv/mpv.conf`. `play` refuses
without HDR (PQ) in display EDID or without VP0 overlay plane; SIGTERM to `h96-hdr` stops mpv
with SIGTERM and restores SDR output.

### `h96-motion`
mpv built-in frame interpolation (judder reduction), GPU-side, zero deps
(`video-sync=display-resample; interpolation=yes; tscale=oversample`). SVP/MVTools path
is intentionally not used: vapoursynth + mvtools have no arm64 build in box repos.

```bash
sudo h96-motion on
sudo h96-motion off
h96-motion status
```

### `h96-npu-upscale` and `h96-npu-upscale-setup`
OFFLINE / batch super-resolution on RKNPU: `Real-ESRGAN` x4. Not live playback (one tile
inference is about 100 ms; clip takes minutes). For stills and short low-res clips.

```bash
sudo h96-npu-setup                    # once: fetch RKNN runtime (librknnrt.so)
sudo h96-npu-upscale-setup            # once: fetch + verify model (58 MB, MIT, pinned SHA-256)
sudo h96-npu-upscale-setup --status   # NPU, runtime and model state
sudo h96-npu-upscale-setup --uninstall  # remove model
h96-npu-upscale in.png out.png        # upscale an image x4
h96-npu-upscale clip.mp4 out.mp4      # short clip (slow: minutes)
h96-npu-upscale --info                # NPU + model info
# options: --overlap 16  --max-frames 900  --model PATH
```

Model realesrgan_x4_96.rknn (96x96 -> 384x384) lands in `/var/lib/h96/upscale/models/`.
Talks to librknnrt.so via ctypes (C API). Images tiled into overlapping 96x96 tiles,
each upscaled on 3-core NPU, feather-blended back. Video shells to box ffmpeg:
split to frames, upscale each, reassemble with hevc_rkmpp, copy audio.

### `h96-audio-passthrough`
Multichannel LPCM to AV receiver over HDMI, instead of decoding to stereo on
box. Stereo PCM works; multichannel PCM (5.1, 7.1) untested. Compressed passthrough:
AC-3 only, experimental and off by default; not verified with AC-3 decoder.

```bash
h96-audio-passthrough devices                                     # list HDMI ALSA devices and PipeWire sinks
sudo h96-audio-passthrough codecs on                              # offer AC3 on HDMI node (display lists AC-3; v7.1 kernel)
sudo h96-audio-passthrough bitstream                              # mpv: AC-3 through PipeWire (--audio-spdif=ac3)
sudo h96-audio-passthrough lpcm hdmi:CARD=rockchiphdmi0,DEV=0 5.1   # multichannel LPCM in mpv (stereo|5.1|7.1)
sudo h96-audio-passthrough off                                    # revert mpv to base config
sudo h96-audio-passthrough codecs off                             # PCM only (default)
sudo h96-audio-passthrough set-device hdmi:CARD=rockchiphdmi0,DEV=0 # persist HDMI ALSA device
sudo h96-audio-passthrough detect                                 # same as h96-display detect ('detect --help')
h96-audio-passthrough test                                        # silent probe: mpv spdif, hw_params per layout, PipeWire node
h96-audio-passthrough selftest                                    # offline test of kernel EDID logic, changes nothing
h96-audio-passthrough status
h96-audio-passthrough route-sync                                  # saved HDMI route codecs = advertised codecs
```

`route-sync` sets codecs WirePlumber saves for HDMI route to list HDMI node advertises (PCM
only while codecs are off); user unit `h96-hdmi-route-sync.service` runs it at every
WirePlumber start, and every WirePlumber restart by this tool runs it too.
`devices` run as root lists PipeWire sinks of desktop session. `lpcm` without channel
count uses layout detected from display or receiver. `lpcm` configures mpv to open
HDMI ALSA device directly, bypassing PipeWire,
for multichannel PCM. `codecs on` lists AC3 on PipeWire HDMI node when display lists AC-3;
refused on kernel without HDMI IEC958 channel-status fix (`status` shows it). `bitstream`
sets mpv to `--ao=pipewire --audio-spdif=ac3`, refused while codecs are off; HDMI must be
default output. DTS, E-AC-3, TrueHD and DTS-HD MA not offered. Passthrough bypasses
software volume: TV or receiver volume sets level. PipeWire exposes passthrough formats only on `hdmi:` / `iec958:`
device paths, and this box's HDMI node opens `hw:0,0`, so PipeWire apps
(browsers, desktop players) receive PCM through default HDMI sink.

### `h96-audio-eq`
System-wide parametric EQ via native PipeWire filter-chain (no extra deps). AutoEQ
presets in `/etc/h96/eq/presets/` (bass-boost, flat, headphone-generic, loudness,
tv-speakers, voice-clarity).

```bash
sudo h96-audio-eq enable [--target <sink>]
h96-audio-eq list                      # presets
sudo h96-audio-eq load tv-speakers     # also: preset
sudo h96-audio-eq load flat
sudo h96-audio-eq disable [--purge]    # --purge also drops EQ files
sudo h96-audio-eq crossfeed on|off     # headphone crossfeed, experimental
sudo h96-audio-eq easyeffects-install  # optional Flatpak EQ window (online)
h96-audio-eq status
```

`--target <sink>` sets which output EQ feeds; with no target it follows current default
hardware sink, ALSA or Bluetooth. Default output switch applies to desktop session of caller:
`sudo` user, else active seat user.

EQ curve is written inline into `/etc/pipewire/filter-chain.conf.d/90-h96-eq.conf`, loaded
by `filter-chain.service`; file exists only while EQ is on, so "H96 EQ Sink" is listed
only then. Preset change restarts `filter-chain.service` only. `Preamp:` line of preset is
applied. Off by default; `status` with EQ off reads `EQ off (default)`.

```bash
sudo h96-audio-eq migrate [--enabled yes|no] [--no-restart]   # older active.txt into preset
```

`migrate` runs by itself before `enable`, `disable`, `load` and `crossfeed` when old
files exist: `active.txt` becomes named preset (or `flat`), old main-daemon conf and
tmpfiles entry are removed.

### `h96-bt-speaker`
Box as Bluetooth A2DP sink: pair phone, its audio plays out box HDMI.

```bash
sudo h96-bt-speaker on [SECONDS]   # discoverable + pairable (0 = until off, default)
sudo h96-bt-speaker off            # revert adapter, stop bridge and agent
h96-bt-speaker status              # adapter, bridge, connections
h96-bt-speaker devices             # paired and connected audio devices
sudo h96-bt-speaker forget MAC     # unpair device
h96-bt-speaker test                # check dependencies
```

Settings in `/etc/h96/bt-speaker.conf`.

### `h96-cast`
AirPlay audio (shairport-sync) + screen mirror (uxplay) + DLNA renderer
(gmediarender). AirPlay 2 downgrades to AirPlay 1 (nqptp has no arm64 build). Google
Cast reception is not openly possible; DLNA is substitute.

```bash
sudo h96-cast enable [airplay|mirror|dlna|all]    # default all
sudo h96-cast disable [airplay|mirror|dlna|all]
h96-cast status
```

Receivers run as user of active seat0 session (logind); with no active seat session, as user
who called `sudo`. `h96-cast status` run as root reads that user's default sink.

### `h96-transcode-server`
Opt-in network **hardware transcode node**. Drop video into watch folder and
VPU transcodes it (rkmpp hardware decode + encode, about 7.5x realtime at 1080p with CPU
idle) to output folder. No extra packages: it reuses image's rkmpp ffmpeg and
`/dev/mpp_service`, so it adds nothing until enabled. **Disabled** by default.

```bash
sudo h96-transcode-server enable    # create folders + start the watch service
sudo h96-transcode-server disable   # stop it
h96-transcode-server status         # config, service state, recent jobs
h96-transcode-server --help         # verbs and settings
h96-transcode-server once IN OUT    # one-shot transcode, no service
h96-transcode-server logs           # follow job log
```

Drop files over SFTP into `/srv/h96-transcode/in/` (or Samba/NFS-export that folder);
results land in `/srv/h96-transcode/out/`, originals move to `done/`. Settings in
`/etc/h96/transcode.conf` (codec hevc/h264/mjpeg, bitrate, container, optional scale).
This is box's strength, low-power always-on transcode appliance, not AI
upscaler.

---

## USB game controllers

Base kernel had no `xpad` driver, so X-input controllers and 2.4GHz pad dongles
did nothing over USB (only D-input/HID pads worked). v4.1 added `xpad.ko`; since v6.0
`xpad` is part of kernel's own module set, built with player-LED
(`CONFIG_JOYSTICK_XPAD_LEDS`) and force-feedback (`CONFIG_JOYSTICK_XPAD_FF`) support.
2.4 GHz X-input dongles that wait for Xbox 360 player-LED command before they start
reporting work (verified with 8BitDo Ultimate 2C Wireless Controller and its dongle;
before v6.0 such dongle enumerated and bound but sent no input), and rumble is available
on xpad-driven controllers. Module is autoloaded at boot, and udev catch-all
(`99-h96-xpad.rules`) force-binds any X-input-interface device to xpad, so unlisted
dongles bind too. No command needed: plug in, it appears as joystick
(`/dev/input/js0`). Verify with `evtest` or `jstest`.

---

## Gaming

> `box64` is included as offline fallback `.deb` in `/usr/lib/h96/gaming`
> (`box64-rk3588-fallback.deb`), and `box64-rk3588` plus `gamescope` install from
> apt via `h96-online-extras` first time box reaches network, `box64-rk3588` pinned to tested 0.4.3 (with
> `libspa-0.2-modules-extra`, which Bluetooth AAC needs). `box86` is included as
> offline package in `/opt/h96-pkgs`. Both DXVK builds are in image under `/usr/lib/h96/gaming`;
> Wine (about 100 MB) downloads on first `h96-game-mode` run (see below).

Proton games on kernel 6.12 can log panthor job timeouts (GPU job reset); in Plasma X11 session no visible
effect; in Plasma Wayland session KWin resets its GPU context repeatedly (short freezes). Play Proton titles in
Plasma X11 session.

### `h96-steam`
Steam, installed on demand. New in v6.1; native route is Steam ARM 3.1 from package `steam-arm-setup` in v8.0. Installs nothing by default and bundles no game code.

```bash
h96-steam                          print usage: subcommands, options, examples
sudo h96-steam install             native ARM64 Steam client (Steam ARM); in terminal, its settings menu
sudo h96-steam install emulated    x86-64 Steam client under FEX-Emu, on the desktop
sudo h96-steam install --defaults  no questions, recommended components without pad-hidraw, xpad-dedup, map-count
sudo h96-steam install --keep      no questions, components and account of last run
h96-steam install --list           print the optional components for a route (no sudo needed)
h96-steam install --help           native installer usage: options, components, examples (no sudo needed)
h96-steam status                   what is installed and what is running
steam-arm-config                   Steam ARM settings menu: components, graphics, games, maintenance, uninstall
```

| route            | client                                  | games                                                                                     | interface          |
|------------------|-----------------------------------------|-------------------------------------------------------------------------------------------|--------------------|
| native (default) | ARM64, runs on Mali GPU                 | x86 titles through client's emulation tool; Windows titles through its ARM64 Proton build | Big Picture        |
| emulated         | x86-64 under FEX-Emu, software rendered | x86 titles through FEX-Emu with graphics thunks                                           | KDE desktop window |

Emulated route installs Valve `steam-launcher` 1.0.0.81 into x86-64 root filesystem after
SHA-256 check; its work files sit in private root-only directory, never in fixed `/tmp` path.

Both install into desktop user's account and keep separate Steam libraries, so one box can
carry both. Run one client at time: two clients compete for controller and for `steam://`
links. Native route starts from application menu entry "Steam ARM" or `steam-arm`;
emulated route from "Steam" or `steam-fex`.

Each route installs x86-64 root filesystem of about 2 GB on first run, and each Steam
library is separate, so disk is practical limit on carrying both.

Native route runs Steam ARM 3.1 installer, `/usr/lib/h96/steam/steam-arm-install.sh`;
its `README.md` sits beside it. On 8.0 both are links into package `steam-arm-setup`, which
`h96-gaming` recommends (not depends on): removing that package to install Steam ARM by its
own script (`steam-arm-install.sh`) keeps `h96-gaming` installed, and `h96-steam` then runs
installed copy `/usr/local/share/steam-arm/steam-arm-install.sh`.
Its driver archive for `gpu-in-emulation` sits beside it, and `h96-steam` hands it to
installer in place of download, so install works offline for that part. Settings live in
`/etc/steam-arm/steam-arm.conf`; new install puts client in `~/.local/share/steam-arm`. Box
moved from Steam ARM 1.2 by v6.2.1 fix keeps its client folder (`ARMHOME_DIR` in settings
file), games and sign-in. Image already carries pad rules (`60-h96-gamepad-hidraw.rules`), pad dedup
(`71-h96-xpad-dedup.rules`) and memory-map limit (`zz-h96-steam.conf`), so `--defaults` leaves out
`pad-hidraw`, `xpad-dedup` and `map-count`, and `--replace-other` puts those image files back after
retiring Steam ARM 1.2.

Components are selectable in both installers and removed again when deselected on later run:
`glx-lax` (private Mesa GLX copy for titles that bind one GL context from several threads),
`vk-spoof` (Vulkan layer for device features Direct3D layer requires), `map-count`
(memory-map limit), `xpad-dedup` (duplicate joystick node), `pad-hidraw` (client reads pads
directly, for rumble and battery level), `pad-xbox` (pads from other makers presented as
Xbox 360 pads, off unless asked for) and `desktop` (menu entry). Native route adds
`gpu-in-emulation` (Mali drivers inside x86 emulation, for titles that fail on forwarding;
on for Mali), `physx-skip` (PhysX install step of Windows titles marked done, else stopped after
60 s; on), `shader-cache` (Steam shader pre-caching, in-game videos of Windows titles;
off, several GB), `desktop-mode` (menu entry "Steam ARM (Desktop mode)", for signing in),
`icon-bigpicture` and `icon-desktop` (desktop icons), `tray` (panel tray icon),
`kde-input-prompt` (KDE Plasma on Wayland: no "Remote control requested" prompt, and any X11
program may then send input; off, listed only where KDE Plasma Wayland compositor is installed)
and `page-size` (Raspberry Pi only; hidden on this box). Emulated route adds `multiblock` and
`big-cores`.

Install, re-run, component changes and package upgrades keep installed games, sign-in and
settings.

Titles protected by anti-cheat do not run on either route: those components require system
call filter emulator does not implement.

Native client's launcher, `steam-arm`, takes `--desktop` to start client in its desktop interface and `--bigpicture` to force Deck interface; `STEAM_ARM_UI=desktop` in `/etc/steam-arm/steam-arm.conf` makes desktop default. Either option switches running client: it closes through its own shutdown and starts again in that interface; power menu's Switch to Desktop does same. `steam-arm-tray` places Steam icon in panel's system tray, with menu to open client in either interface, stop it, or quit tray; installer's `tray` component installs it with autostart entry.

Launch handler, `/usr/local/lib/steam-arm-handler.py`, runs inside Valve's emulation tool before each Linux x86 title starts and sets it up with no launch options: x86 Steam overlay core, MangoHud when title asks for it (`mangohud %command%` or `MANGOHUD=1 %command%`), OpenGL renderer with GL 3.3 report for Godot 4 titles, and for Unity titles Vulkan renderer (`-force-vulkan`) where player carries it, else GL 4.5 report; 32-bit Unity players start with Steam overlay off. 32-bit titles lose `-vulkan` and `-force-vulkan` (Vulkan forwarding is 64-bit only); start scripts (Source engine style) are followed to binary they start; Source 2 titles are logged. Graphics: forwarding to host GPU drivers by default; with `gpu-in-emulation`, titles that fail on forwarding (Java titles, 32-bit titles started with `-vulkan`) switch to Mali drivers inside emulation by themselves. Title profiles, one app id per line, later files override earlier ones:

```
/usr/local/share/steam-arm/titles.conf   included with installer
/etc/steam-arm/titles.conf               local
~/.config/steam-arm/titles.conf          client home

<appid> key=value ...
  overlay=x86|vulkan|off   mangohud=on|off   godot=gl|vulkan   unity=vulkan|gl
  env=NAME=VALUE;NAME=VALUE   args=ARG;ARG
  gl32=off    title not detected as 64-bit on emulated x86 Mesa, no GL forwarding
  vk32=keep   32-bit title keeps -vulkan
  gfx=b       Mali drivers inside emulation;  gfx=a  forwarding;  unset = automatic
```

`GFX_DEFAULT` in `/etc/steam-arm/steam-arm.conf` sets route for titles without `gfx=`: `auto` (default), `a` or `b`. `steam-arm-config` sets both (Graphics). `overlay=vulkan` adds arm64 overlay core and arm64 overlay Vulkan layer, for Vulkan titles. Launch options `STEAM_ARM_OVERLAY=x86|vulkan|off` and `STEAM_ARM_PRELOAD_KEEP=a,b` override profiles. Handler does not run for Proton titles; there MangoHud and arm64 overlay layer stop title at device creation, so leave `MANGOHUD` unset for them. For Proton titles launcher sets `PROTON_DXVK_D3D8=1`, so Direct3D 8 titles run through DXVK, and it clears shared-memory segments Steam overlay leaves in `/dev/shm`; overlay buffers client still maps are freed within about 2 minutes once no game runs.

`steam-arm-remoteplay` pins two Remote Play client settings this box requires, hardware decoding off and HEVC off, in client's stored configuration. Streaming client decodes through Vulkan Video, which Mali driver does not provide, so with hardware decoding advertised session can sit on launch screen and never finish negotiating; with it off host keeps to H.264 and software decoder. Launcher runs it before each start, and it runs on its own with `--check` to report without changing anything.

This project is not affiliated with, endorsed by or sponsored by Valve Corporation. Steam, Proton, Steam Deck and Steam Frame are trademarks of Valve Corporation. No Valve artwork is included in image.

### `h96-emulators`
Opt-in game-emulator suite, GPU-accelerated. New in v5.0. Installs nothing by default and
bundles no game code, no BIOS and no ROM.

```bash
h96-emulators                     interactive multi-select menu
h96-emulators list                catalog, install state, GPU backend per entry
h96-emulators install <names|all> install and wire to the Mali GPU, then verify
h96-emulators remove  <names|all> remove again
h96-emulators bootstrap           install flatpak + Flathub (needed on a fresh flash)
h96-emulators gpu                 report the GPU backend each emulator is using
```

`install`, `remove`, `bootstrap` and `gpu` elevate through `sudo` and ask for password
when needed; `list` and menu run as normal user.

Eight entries, all of them systems that offload 3D rendering to Mali-G610:

| name        | system                                     | how it runs                       | recommended backend         |
|-------------|--------------------------------------------|-----------------------------------|-----------------------------|
| `retroarch` | multi-system (NES/SNES/Genesis/PS1/GB/PCE) | Flatpak, ARM64                    | Vulkan or glcore, per core  |
| `dolphin`   | GameCube / Wii                             | Flatpak, ARM64                    | Vulkan (PanVK)              |
| `ppsspp`    | Sony PSP                                   | Flatpak, ARM64                    | Vulkan (PanVK)              |
| `flycast`   | Sega Dreamcast / NAOMI                     | Flatpak, ARM64                    | Vulkan or OpenGL            |
| `melonds`   | Nintendo DS                                | Flatpak, ARM64                    | OpenGL (GLES)               |
| `rmg`       | Nintendo 64 (Rosalie's Mupen GUI)          | Flatpak, ARM64                    | Vulkan (Parallel-RDP) or GL |
| `azahar`    | Nintendo 3DS                               | Flatpak, ARM64                    | Vulkan (PanVK)              |
| `cemu`      | Nintendo Wii U                             | x86-64 build under box64, no wine | Vulkan (PanVK)              |

Seven are native ARM64 Flatpaks and render through PanVK/Panfrost. Cemu has no ARM build,
so it runs x86-64 build under box64; its files land under invoking desktop user's
home and it gets `h96-cemu` launcher. Cemu AppImage is checked against SHA-256 digest
GitHub lists for release asset; release without digest is refused.

`install` runs GPU wiring and verification pass: it exposes Mali render node and
PanVK ICD to each Flatpak sandbox, then probes live renderer and warns when emulator
would fall back to llvmpipe software rendering rather than letting it fail quietly.
`h96-emulators gpu` re-runs that report on demand. Pick backend shown by `list` inside
each emulator's own settings.

Fresh flash has no flatpak. Install auto-bootstraps it (apt `flatpak` plus Flathub
remote) after warning, or run `h96-emulators bootstrap` first. Both need internet. Full
install is about 5 GB including shared Flatpak runtimes.

#### Measured, per emulator

| emulator    | what was measured                                                                                                               |
|-------------|---------------------------------------------------------------------------------------------------------------------------------|
| `retroarch` | verified hardware from its own log: `Renderer: Mali-G610 MC4 (Panfrost)`, Mesa 26.1.6, GPU load rising to 34 percent at 600 MHz |
| `flycast`   | verified hardware from its own renderer log                                                                                     |
| `dolphin`   | `Mali-G610 MC4 (Panfrost)` verified for both GL and Vulkan in its sandbox; 3D path only runs once game is loaded                |
| `melonds`   | as `dolphin`: GL and Vulkan verified in sandbox, 3D once game is loaded                                                         |
| `rmg`       | as `dolphin`: GL and Vulkan verified in sandbox, 3D once game is loaded                                                         |
| `azahar`    | as `dolphin`: GL and Vulkan verified in sandbox, 3D once game is loaded                                                         |
| `cemu`      | runs under box64; GUI measured on hardware GL at 7 percent at 600 MHz                                                           |
| `ppsspp`    | see known issue below                                                                                                           |

**Known issue: PPSSPP's default OpenGL backend does not work on this box.** It fails with
`EGL_BAD_ALLOC` and never opens window. Fix is Vulkan: set

```ini
GraphicsBackend = 3
```

in `ppsspp.ini`, which works. Nothing else in suite needs backend change.

**mGBA and ScummVM are deliberately not in this suite.** They are 2D: they do not
meaningfully use Mali GPU, so this tool's GPU wiring has nothing to do for them. They
are not missing from box. Install them from software store (Discover) as
aarch64 Flatpaks `io.mgba.mGBA` and `org.scummvm.ScummVM`, or from apt as `mgba-qt` and
`scummvm`. They run on CPU and are fine there.

### `h96-game-mode`
Run Windows game under box64 plus wine plus stripped DXVK build, inside nested
Wayland compositor started from X11 desktop.

```bash
h96-game-mode /path/to/game.exe [game args]
h96-game-mode -d sarek /path/to/game.exe     # DXVK-Sarek for D3D8/9 and ddraw titles
h96-game-mode -c gamescope -r 1280x720 /path/to/game.exe
h96-game-mode --winecfg                      # winecfg in default prefix
h96-game-mode --wine-file FILE               # install Wine from local tarball, then exit
h96-game-mode status                         # Wine, DXVK, Vulkan ICD and compositor state; installs nothing
```

Options: `-p, --prefix DIR` (default `~/.local/share/h96-gaming/prefixes/default`),
`-d, --dxvk sarek|stripped|auto` (`auto` = stripped DXVK 2.7.1 for D3D10/11),
`-c, --compositor cage|gamescope` (default cage), `-r, --res WxH` (gamescope),
`--hud` (DXVK frame-time overlay), `--no-dxvk` (leave prefix DLLs as they are),
`--wine-file FILE` (local `wine-11.12-staging-tkg-amd64-wow64.tar.xz`; archive with paths outside
one top folder is refused), `--stack-file FILE` (older all-in-one `h96-gaming-stack.tar.gz`).
Run as desktop user: as root (`sudo`) tool refuses, except `--wine-file` and `--stack-file`;
Wine install asks for `sudo` itself. Without game path, tool prints usage and exits with
code 2 before any download.

DXVK builds (stripped 2.7.1, Sarek 1.12) are in image under `/usr/lib/h96/gaming`. On first run,
if Wine is absent, tool downloads Kron4ek Wine 11.12 staging-tkg amd64-wow64 (about 100 MB)
from github.com/Kron4ek/Wine-Builds, checks its sha256, unpacks it to `/opt/h96-gaming/wine`, then proceeds.
`/etc/h96/wine.url` selects other Wine build; `/etc/h96/wine.sha256` holds its sha256 (64 hex
digits) and is required with it. Missing or mismatching sha256: tool refuses, nothing written.
When address does not answer HTTP 200, tool prints address, status, `--wine-file` and `wine.url` options, and
exits with code 2; nothing is written. Later runs skip download. Wine Mono and Gecko install dialogs are suppressed
(`WINEDLLOVERRIDES=mscoree,mshtml=d`, unless set by caller).
Wine stays out of image for majority who do not game.

x86 emulation: wine runs under explicit `box64`, and box64 starts wine's x86 child
processes itself. While Steam ARM is installed, FEX owns x86 binfmt entries and
box64/box32 entries stay disabled; `h96-game-mode` works in both states.

### `h96-dxvk-install`
Install DXVK (image copy in `/usr/lib/h96/gaming`) into wine prefix, offline.

```bash
h96-dxvk-install $HOME/.wine             # stripped DXVK 2.7.1: D3D10/11 (default)
h96-dxvk-install $HOME/.wine sarek       # DXVK-Sarek 1.12: D3D8/9 and ddraw
```

### Re-running gaming setup
`h96-gaming-setup.service` runs once on first boot: installs gaming stack (offline:
`vulkan-tools`, `cage`, `mesa-utils`, box64 fallback `.deb`; online, best effort:
`box64-rk3588`, `gamescope`), validates PanVK and box64, writes
`/var/lib/h96-gaming-setup-done`, then retires. To force fresh run after manual
change, or to re-validate:

```bash
sudo rm /var/lib/h96-gaming-setup-done
sudo systemctl start h96-gaming-setup
```

Watch progress with `journalctl -fu h96-gaming-setup`. Wine is not installed by this
step; it downloads on first use of `h96-game-mode`.

---

## Android (Waydroid)

### `h96-waydroid`
Android in container: Waydroid 1.6.2 plus nested Weston window on X11 desktop. Opt-in.
No Android image is bundled. Added in v5.0, and it is reason kernel is rebuilt
with `CONFIG_PSI=y`: Android 11 and later `init`/`lmkd` hard-require `/proc/pressure`, and
without it container boots and dies in about 15 seconds.

**Changed in v5.0:** `init gapps|vanilla` wires Mali-G610 by default instead of forcing
SwiftShader software rendering, cgroup v1 tmpfs shims are applied only on legacy
Android 11 path, and two profile bugs are fixed (`status` reported wrong profile, and
image identity leaked across profile switch). Both are described under **Profile hygiene**
below.

```bash
h96-waydroid                     interactive menu / status
h96-waydroid status              binder, PSI, service, session, image, GPU report (as user: probes via sudo rule)
h96-waydroid install             apt repo + waydroid + weston + cgroup/nft fixes
h96-waydroid init gapps|vanilla  latest official LineageOS 20 (Android 13), GPU wired.
                                 DEFAULT. Downloaded once, then stashed
h96-waydroid init gpu [dir]      LEGACY Android 11 Panthor image you supply (about 5 GB)
h96-waydroid init vanilla fresh  force a NEW download, replacing the stash
h96-waydroid init custom <dir>   your own system.img + vendor.img PAIR
h96-waydroid size [WxH|fullscreen]  set launch window / render size (picker if no argument);
                                 fullscreen = borderless window filling screen
h96-waydroid state save [name]   save current Android state (apps, logins, files)
h96-waydroid state list          list saved states
h96-waydroid state load <name>   restore a saved state
h96-waydroid state delete <name> delete a saved state
h96-waydroid spoof               show reported device identity + device list
h96-waydroid spoof list          list device profiles
h96-waydroid spoof <device>      report that device to Aurora Store / Play
h96-waydroid spoof off           restore image's own identity
h96-waydroid start               launch UI in a nested Weston window (X11)
h96-waydroid stop                stop session + container + weston
h96-waydroid hw [on|off]         re-apply / remove Panfrost GPU wiring, then verify
h96-waydroid remove              full uninstall
```

`install`, `init`, `hw`, `stop` and `remove` auto-elevate through sudo. `start` runs as
desktop user because it needs your X `DISPLAY`; first `start` after `install` works from
desktop user with no root step for its launcher. `snapshot` is accepted as alias for
`state`. `h96-waydroid-lockwin` is helper `h96-waydroid` writes and calls to pin window
size; it is not run by hand.

**Image profiles.** Images are 2 to 5 GB each and are NOT bundled with this build.

- **`gapps` / `vanilla`** fetch latest official Waydroid LineageOS 20
  (`lineage-20.0-20260403-VANILLA-waydroid_arm64`, Android 13, vendor type MAINLINE, about
  900 MB). Download-and-go, no files to supply. This is DEFAULT and recommended profile,
  and it wires GPU: `drm_device=/dev/dri/renderD130`, `ro.hardware.gralloc=gbm`,
  `ro.hardware.egl=mesa`, with `renderD130` and `card2` nodes bound into container.
  **Measured on this board:** `waydroid shell dumpsys SurfaceFlinger` reports
  `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`. GPU load reads
  `0@300000000Hz` at idle, reaches 50 percent at 1000 MHz under UI activity, and sits at 19
  to 26 percent at 600 MHz. `boot_completed=1` with session ready in about 8 seconds.
  Android 13 is cgroup v2, so this path applies no cgroup v1 shims, and window follows
  Weston output size.
- **`gpu`** is LEGACY profile, kept for anyone holding that specific stashed image:
  third-party Panthor-in-image Android 11 build (LineageOS 18.1) of about 5 GB that YOU
  supply. Place `system.img` and `vendor.img` in `/etc/waydroid-extra/gpu-images` (or pass
  directory), then `h96-waydroid init gpu`. **Measured on this board:**
  `GLES: Mesa, Mali-G610 (Panfrost), OpenGL ES 3.1 Mesa 24.0.5`, GPU load 27 to 41 percent
  at 300 to 700 MHz. First cold boot takes 1 to 2 minutes. Against official image it is
  older Android (11 against 13), older Mesa (24.0.5 against 26.0.1), unsigned, third-party,
  and abandoned since April 2024 (author WillzenZou, repos frozen). It also needs cgroup
  v1 tmpfs shims, pins itself to 960x512 display that has to be overridden, and Vulkan
  never worked on it. Do not choose it for new installs.
- **`custom <dir>`** takes image you supply. It must be arm64 Waydroid-style
  `system.img` plus `vendor.img` PAIR (LineageOS-for-Waydroid or similar). ROM zip, OTA
  payload, or plain GSI will not boot. GPU acceleration only if that image has
  Mesa/Panfrost compiled in; `hw on` verifies and reports what it finds.

Every image, downloaded or supplied, is stashed under `/etc/waydroid-extra/`
(`gpu-images`, `los-images`, `custom-images`) and symlinked into path Waydroid
auto-detects, so switching profiles is instant and offline and never re-downloads.
`init vanilla fresh` forces new download. Stashes are not part of released image.

**Window is fixed size, and that is deliberate.** Any window-manager geometry change
(drag-resize, edge snap, quick tile, maximise, fullscreen) makes Weston reconfigure its X11
output. Waydroid client renders Android at ONE fixed size and cannot follow that
reconfigure: it drops off compositor and window goes PERMANENTLY black. KWin ignores
min-size-only hint when quick-tiling, so launcher pins `WM_NORMAL_HINTS` min equal to
max and window is not resizable.

```bash
h96-waydroid size            picker: desktop sizes, half/full of your monitor, phone portrait
h96-waydroid size 1280x720   set it directly
h96-waydroid size fullscreen borderless window at 0,0 filling screen, still fixed size
```

Picker detects your display, marks current choice, and warns on any entry bigger
than screen. Size applies on next launch.

**Profile hygiene (fixed in v5.0).** Two bugs made tool describe image it was not
running.

- **`status` reported wrong profile.** It inferred image profile from `drm_device`.
  That property is now always set, because GPU is wired on every profile, so `status`
  labelled official Android 13 image as "gpu / Panthor". It keys off which image stash is
  linked now.
- **Image identity leaked across profile switch.** After moving from legacy Android 11
  image to Android 13, `ro.product.waydroid.model` still reported Android 11 board string
  `Rockchip RK3588 NVR DEMO LP4 V10`. That also poisoned `spoof`, which read those stale props
  as image's stock identity and restored them on `spoof off`. Identity props are cleared
  on `init` now, and Android 13 correctly reports
  `ro.product.model = WayDroid arm64 Device`.

**`spoof`.** Stock Waydroid image reports brand `waydroid`, model `WayDroid arm64
Device`. No Play device profile matches that, so Aurora Store and Play Store hide or
refuse apps. `spoof` writes standard identity props (brand, manufacturer, model, name,
device, `ro.build.fingerprint`, `ro.build.description`) so Android reports common phone
instead. Five devices: `pixel5`, `pixel7`, `galaxys9`, `galaxys20`, `oneplus8t`. Props
apply on next container start.

Verified on this box: `ro.product.model` read `Pixel 7` inside Android after
`h96-waydroid spoof pixel7`, and `spoof off` restored every original prop.

**It changes availability only. It does NOT pass Play Integrity or SafetyNet.** Those attest
hardware-backed key and verified-boot state; container has neither. Banking apps,
DRM playback, and some games will still refuse to run, and no spoof profile changes that.

**`state` (alias `snapshot`).** Saves and restores Android's `/data` directory: installed
apps, logins, settings, files.

```bash
sudo h96-waydroid state save before-update
sudo h96-waydroid state list
sudo h96-waydroid state load before-update
sudo h96-waydroid state delete before-update
```

It stops session first, and archives with `tar --numeric-owner -p` because Android app
identity depends on per-app uids and archive that flattens them breaks every installed
app. **It refuses cross-profile restore**: restoring Android 11 data onto Android 13
crashes `system_server` with PackageManager NPE, so profile is recorded with each
snapshot and checked on load. Measured: 27 MB `/data` produced 7.8 MB archive, and
Android booted from restored copy. Snapshots live in `/var/lib/waydroid-snapshots` and
are not part of image.

**What `install` sets up beyond packages.** Waydroid on this board needs three fixes,
written for you:

- **cgroup v2 delegation.** Container's `/sys/fs/cgroup` is mounted read-only by
  default, so Android `init` cannot create its per-app cgroups and lmkd and every service
  fail. Drop-in delegates writable cgroup to `waydroid-container.service`, enables
  controllers at cgroup root before it starts, and LXC's `config_base` is switched from
  `cgroup:ro` to `cgroup:rw`.
- **cgroup v1 tmpfs shims** in `config_nodes` (`/acct`, `/dev/stune`, `/dev/cpuset`,
  `/dev/memcg`), which legacy Android 11 image expects on cgroup-v2 host. Applied on
  Android 11 path only. Android 13 is cgroup v2 and needs none of them.
- **`LXC_USE_NFT=false`** as service `Environment=`. nftables breaks Waydroid LXC
  networking on RK3588.

**Limitations, stated plainly:**

- **Container cannot use RK3588 NPU.** Its `vendor.img` contains no RKNN libraries
  and no `neuralnetworks` HAL, so even passing `renderD129` node through would give
  Android device file with no driver behind it.
- **Vulkan and hardware video decode inside Android do not work** on any RK3588 Waydroid
  configuration, legacy Panthor Android 11 image included. GLES is accelerated path,
  and it is hardware Panfrost on both images.
- **HALIUM vendor images are stripped of Mesa GPU drivers.** MAINLINE vendor type is
  required for hardware GLES, and `init gapps` / `init vanilla` fetch MAINLINE.
- **Kernel driver naming is confusing on purpose:** kernel driver is `panthor`, Mesa
  Gallium driver is still called `panfrost`. Both names refer to same GPU stack.
- **Do not shadow `/dev/kmsg`.** Binding `/dev/null` over container's `dev/kmsg` mounts
  cleanly, and container then never starts: LXC state stays STOPPED and Android never
  reaches "Android with user 0 is ready". Android `init` requires writable kmsg.
  Tested and rejected; quiet journal with journald limits instead.

### `h96-vm` (v6.2, off by default)
KVM virtual machines under QEMU, hardware-accelerated. Nothing downloads or installs until
`install`. Slim installer's `vm` layer removes tool.

```bash
sudo h96-vm install [--yes]         # install qemu, UEFI firmware, cloud-init tools
h96-vm create NAME [--image ubuntu-24.04|debian-12|URL] [--mem MB] [--cpus N] [--disk GB] [--insecure]
h96-vm start NAME [--gui]           # headless by default; --gui needs desktop session
h96-vm stop NAME [--force]          # ACPI shutdown; --force stops unresponsive guest
h96-vm list                         # VMs, state, resources, SSH forward
h96-vm ssh NAME
h96-vm delete NAME [--yes]
h96-vm status                       # install state, KVM, VM list
sudo h96-vm remove [--yes]          # purge qemu packages and all VM data
```

`create` downloads base cloud image (cached, checked against vendor SHA256SUMS or
SHA512SUMS), makes qcow2 overlay and cloud-init seed with your SSH key, or prints generated
password once when no key is found. Image is refused when checksum list cannot be fetched
or has no entry for it; `--insecure` uses it unverified.

---

## Backup and restore (v6.0)

Reflashing writes whole eMMC, so every on-demand feature installed on top of console
base (desktop, emulators, Waydroid, Widevine, gaming stack, NPU runtime) and every config and
save is gone after flash. `h96-backup` and `h96-restore` carry configured box across
reflash. Both auto-elevate through `sudo` and detect desktop user dynamically; no username
is hardcoded. Current version is v2.5 (`--version`). `h96-restore` reads backups made on
v5.0.1 and every later release, and backward compatibility is kept for every future release.
On 8.0 `h96-restore` changes program paths of earlier releases in restored `~/.config` text files
(autostart entries, Plasma launchers, `mpv` files) to 8.0 package paths, for example
`/usr/local/sbin/h96-display` to `/usr/sbin/h96-display`; path changes only when 8.0 file exists
and old one does not. Binary files keep their bytes. Restore never writes under `/usr`, `/opt`,
`/bin`, `/sbin` or `/lib`.

### `h96-backup`  (needs root, auto-elevates)
Capture configured box into one archive: manifest of which on-demand features are present
plus passive data that cannot be re-downloaded.

```bash
h96-backup                 write an archive under the desktop user's home
h96-backup <dir>           write the archive into <dir>
h96-backup <path>          write to an explicit path (extension appended)
h96-backup --with-images   also bundle the Waydroid image stashes (multi-GB; default off)
h96-backup --with-vm-disks also bundle h96-vm disk images (multi-GB; default off)
h96-backup --with-proton-prefixes  also bundle Steam ARM Proton prefixes (multi-GB; default off)
h96-backup --with-steam-runtime    also bundle Steam client program (multi-GB; default off)
h96-backup --only a,b      capture only these categories
h96-backup --skip a,b      capture everything except these categories
h96-backup --emulators x,y limit the emulator list (names as in h96-emulators)
h96-backup --probe-json    print what is on this box as JSON and exit (needs no root)
```

Categories: `desktop`, `configs`, `emulators`, `waydroid`, `waydroid-images`, `widevine`, `gaming`, `npu`, `wifi`, `autologin`, `system`, `vm`. `waydroid-images` is same as `--with-images`. Manifest records which
categories archive holds.

It probes each feature (any absent one is skipped cleanly): desktop environment
(`kde-plasma-desktop` or `gnome-shell`), installed emulators (Flatpak apps in
`h96-emulators` catalog, plus `cemu` box64 build), Waydroid profile and which image
stashes exist, Widevine, gaming wine prefix, NPU runtime, and WiFi credentials and networks. It
then writes `manifest.json` and passive data into one archive: tar plus zstd when `zstd` is
present (`.tar.zst`), otherwise gzip (`.tar.gz`). `h96-restore` reads `.tar.zst` through `zstd`, else
through Python built-in zstd module.

Passive data captured: subset of desktop user's `~/.config` (`plasma*`, `kwinrc`,
`kdeglobals`, `kglobalshortcutsrc`, `kscreenlockerrc`, `kcmfonts`, `mpv`, `autostart`, and
`dconf` for GNOME), KDE display configuration (`~/.local/share/kscreen`) and WirePlumber
state (`~/.local/state/wireplumber`); emulator saves and per-app config; gaming wine
prefixes; WiFi confs and NetworkManager or netplan WiFi files (mode 0600); lightdm autologin setting; and Waydroid Android `/data`.
v2.1 adds `system` category (opt-in service states, display flags `hdmi20` and `frl`,
CEC flags `cec-wake.off` and `cec-standby-on-blank`,
per-display colour and range files, hotspot configuration, Steam ARM configuration) and
`vm` category (VM definitions; disks only with `--with-vm-disks`).
v2.2 (v6.2.1 fix) captures Steam ARM 2.0 settings and local game profiles
(`/etc/steam-arm/steam-arm.conf`, `/etc/steam-arm/titles.conf`), or on box still on Steam ARM
1.2 its `/etc/h96/steam-arm.conf` and `/etc/h96/titles.conf`. `h96-restore` writes them as
Steam ARM version box runs: settings from other version are translated (client folder,
account, components, interface), game profiles from other version are added for titles
box has none for.
v2.3 (v7.0) adds NPU power state to `system` category: follow mode (`/etc/h96/npu-follow`)
and governor chosen with `h96-npu power`; restore applies them, and archives without them
leave NPU settings alone. Lock files (`*.lock`) are never archived.
v2.4: archive file mode 0600, owner desktop user; Waydroid image stashes only with
`--with-images` or `--only waydroid-images`; manifest records source home path.
v2.5: `wifi` also holds NetworkManager WiFi connections (`.nmconnection` of type wifi) and
netplan WiFi files; `system` records audio passthrough mode, channels, device and compressed
codecs opt-in as values; per-display files keep `hdr=` and other plain `key=value` lines.
Waydroid image stashes are bundled only with `--with-images` (they run to several GB); without
it manifest records their byte sizes so restore re-downloads them through
`h96-waydroid init`.

Steam ARM home is captured in `gaming` category. Game content (`steamapps/common`,
downloads, shader cache, workshop) is always left out and downloads again. Proton prefixes
and Steam client runtime are left out by default; `--with-proton-prefixes` and
`--with-steam-runtime` include them.

### `h96-restore`  (needs root, auto-elevates)
Replay `h96-backup` archive onto freshly reflashed box: reinstall recorded features,
then restore passive data to correct paths and owners.

```bash
h96-restore                      list the archives found and ask which one to use
h96-restore <folder>             use the newest archive in that folder
h96-restore --list               print the archives found, change nothing (needs no root)
h96-restore <archive>            reinstall each recorded feature, then restore the data
h96-restore <archive> --open     do not auto-run installers: print the installer commands
                                  to confirm, then still restore the passive data
h96-restore <archive> --dry-run  print the plan only, change nothing (needs no root)
h96-restore <archive> --force    overwrite files that are newer on disk; use it with the
                                  desktop session stopped (sudo systemctl stop lightdm)
                                  when a fresh image has already written default configs
h96-restore <archive> --only a,b       restore only these categories
h96-restore <archive> --skip a,b       restore everything except these categories
h96-restore <archive> --emulators x,y  limit which emulators are reinstalled and restored
h96-restore <archive> --plan-json      print what the archive holds as JSON (needs no root)
```

Categories: `desktop`, `configs`, `emulators`, `waydroid`, `waydroid-images`, `widevine`, `gaming`, `npu`, `wifi`, `autologin`, `system`, `wol`, `vm`. `wol` (wake-on-LAN through `h96-wol`) is network state:
restore applies it only when `--only` names it, never by default and never through `system`.
Category selection filters both installer steps and data
written; `--emulators` filters emulator list and their saves.

Naming archive is optional. Argument takes folder as well as file, and folder
gives up newest archive in it or one level below it, so mounted stick can be named
instead of path. Run tool with no argument on terminal and it lists archives it
finds on mounted media and in home folders, numbers them with their size and date, and
asks which one; path typed at that prompt is accepted in place of number. `--list` prints
same list and stops. Anywhere without terminal, such as systemd unit, argument is
still required. `--dry-run` reports one line per category with file count and byte total,
then sample of destinations under each, rather than one line per file.

It reads `manifest.json` from head of archive, reinstalls desktop if absent, then
re-runs recorded installers (`h96-emulators install`, `h96-waydroid init`,
`h96-widevine-setup`, `h96-npu-setup`) and restores data; Wine downloads on first
`h96-game-mode` run as desktop user. It is
idempotent: config file already present and newer than archived copy is kept and noted,
not overwritten. WiFi confs and NetworkManager or netplan WiFi files restore as `root:root`
mode 0600 (`netplan generate` runs after netplan files); user files are chowned to
detected desktop user; Waydroid `/data` restores with its recorded numeric owner; and
autologin is restored as setting through one drop-in,
`/etc/lightdm/lightdm.conf.d/70-h96-autologin.conf`, for detected desktop user, because
reflash can create different account name; archived lightdm files are never written back.
Opt-in services are enabled only when backup had them enabled; `h96-leds` recorded off is
switched off. Steam ARM settings carry owner choices only. Archive members with absolute or
`..` paths, symlinks in system folders and symlinks leading outside target home are refused
(wine drive links kept). Old home paths in `~/.config` text files, Steam library files and
symlinks follow new home. v2.5 reads whole archive before writing anything (`checking archive
...`); damaged or incomplete archive exits 1 with `archive damaged or incomplete` and writes
nothing. Audio passthrough re-applies through `h96-audio-passthrough`; box that refuses
compressed codecs or bitstream keeps passthrough off. mpv HDR `passthrough` restores as
`tonemap`. Restored autologin sets `/var/lib/h96/autologin-set`, so boot setup keeps restored
user. Feature whose installer tool is missing is skipped with warning.
After restore, log out and back in for desktop config and autologin to take effect, and
start Waydroid session to finish its first boot; desktop user's `filter-chain` and
`wireplumber` restart during restore when user manager runs, so EQ and default output apply
at once.

### `h96-backup-gui`
Graphical front end for two tools. Back up tab reads box and lists each category
with what it holds and its size; tick what to include, pick emulators, choose folder
or mounted USB stick, and matching `h96-backup` command runs in terminal window.
Destination line reports free space on chosen folder, and command line carries
estimate of how much data selection comes to. Restore tab lists archives found on
mounted media and in home folders, reads chosen archive, shows which categories it holds
with file count and byte total for each, and offers `--force` and `--open` plus dry-run
preview in its own window (`q` or Esc closes it); Restore runs `h96-restore` in terminal
window so its prompts stay visible. With
`--force` and Desktop settings selected, restore runs from transient systemd unit that
stops display manager first and starts it again after, with output in
`/var/log/h96-restore-force.log`.

Archive and Save-to fields take typed path as well as pick from list: give file
to use that archive, or folder to search it, with outcome reported under field as it
is typed. Every panel window opens, including file browser and confirmations, is
drawn in same theme as window. Reading box and reading archive run on
background thread with progress bar in status strip, so window keeps painting while
they work; archive is read twice from v2.5 (full check, then contents), so reading takes
longer than before. Layout is sized
from display, so action buttons stay on screen at 1024x768.

```bash
h96-backup-gui                    open the window (application menu: H96 Backup and Restore)
h96-backup-gui --restore          open on Restore tab with newest archive loaded
h96-backup-gui --install-desktop  write the application menu entry
h96-backup-gui --selftest         print the command lines it would build
```

Package depends on `python3-tk`, so window opens on first launch without download. All logic
stays in CLIs; window only selects and launches.

Older boxes: Boxes on v5.0.1 or earlier have no backup tool; `h96-migrate-kit.zip` (updated for v2.5) installs same three tools there (`sudo bash install.sh`, `--gui` for window, `--help` for usage) so box can be captured to USB stick before flash. Kit keeps newer tools already on box unless `--force` is given.

---

## Front panel

### `h96-vfd`
Front-panel display daemon: clock with blinking colon, plus Ethernet, WiFi,
USB and play icons driven from live system state. Runs as `h96-vfd.service`.

```bash
sudo systemctl status h96-vfd
sudo systemctl restart h96-vfd
```

### `h96-leds` (steady by default)
Front-panel LEDs. `on` (default) keeps them lit and steady: `net-led` lit while Ethernet
link is up, `hdd-led` and `work-led` lit. `blink` switches to activity: `net-led` blinks on
Ethernet traffic, `hdd-led` on eMMC access, `work-led` heartbeat. `off` darkens all three and
disables `h96-leds.service`. Choice is saved in `/etc/h96/leds.conf` and applied at every
boot; first boot enables service in steady mode.

```bash
sudo h96-leds on             # steady (default)
sudo h96-leds blink          # activity blinking
sudo h96-leds off
h96-leds status              # mode, trigger and brightness per LED
```

---

## Services added by this build

Most of these run once on first boot and then mark themselves finished. You should not
need to start any of them by hand.

### First boot

| Unit                                                 | What it does                                                                                                                                                |
|------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `h96-firstboot.service`                              | first-boot setup: enables units below, masks noisy stock timers, then retires itself                                                                        |
| `h96-firstboot-cleanup.service`                      | installs offline runtime dependencies and purges boot splash (plymouth) and unused packages that nothing depends on. Guarded by `/var/lib/h96-firstboot-cleanup-done` |
| `h96-firstboot-reboot.service`                       | waits for dpkg lock to clear, then performs single automatic reboot that ends first-boot setup; first-login wizard started before reboot waits for it. Guarded by `/var/lib/h96-firstboot-reboot-done`             |
| `h96-gpu-setup.service`                  | stage open GPU stack                                                                                                                                        |
| `h96-video-setup.service`                            | hardware video stack                                                                                                                                        |
| `h96-gaming-setup.service`                           | gaming stack, offline half and best-effort online half                                                                                                      |

### Running services

| Unit                                      | What it does                                                                                                                                                                                                                                                                                                                                      |
|-------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `h96-tune.service`                        | applies `/etc/h96-tune.conf` at boot via `h96-bench --apply-tune`: `schedutil` on both clusters, big cores up to 2208 MHz                                                                                                                                                                                                                         |
| `h96-zram-heal.service` (v5.0)            | oneshot at boot: re-enables `armbian-zram-config.service` when its `sysinit.target.wants` symlink has gone missing. Fresh flash was measured booting with no swap at all, because image's want had no `deb-systemd-helper` enabled-state record behind it and package operation removed it silently. Working zram measures 3.8 GB, algorithm zstd |
| `h96-power-profiles.service`              | D-Bus power-profile provider (`/usr/lib/h96/h96-power-profiles.py`). Replaces `power-profiles-daemon`, which is masked, and is what desktop power applet talks to; applies `balanced` at boot before display manager                                                                                                                                                                              |
| `h96-bt.service`                          | loads BCM4362A2 Bluetooth firmware and brings `hci0` up                                                                                                                                                                                                                                                                                           |
| `h96-vfd.service`                         | front-panel display                                                                                                                                                                                                                                                                                                                               |
| `h96-wpa-supplicant-wlan0.service`        | standalone WiFi supplicant for `wlan0`                                                                                                                                                                                                                                                                                                            |
| `h96-dhcpcd-wlan0.service`                | DHCP client for WiFi path                                                                                                                                                                                                                                                                                                                         |
| `h96-display-guard.service`               | reverts unconfirmed `h96-display` mode on second boot after it was set                                                                                                                                                                                                                                                                            |
| `h96-undervolt-trial.service`             | restores stock device tree if undervolt was set but never confirmed. Does nothing unless `/var/lib/h96-undervolt-trial` exists                                                                                                                                                                                                                    |
| `h96-branding.service` / `.path`          | restores board banner if package overwrites it                                                                                                                                                                                                                                                                                                    |
| `h96-kde-configure.service` / `.path`     | applies KDE fixes when KDE is installed                                                                                                                                                                                                                                                                                                           |
| `h96-gnome-configure.service` / `.path`   | same for GNOME                                                                                                                                                                                                                                                                                                                                    |
| `h96-lightdm-configure.service` / `.path` | display manager configuration                                                                                                                                                                                                                                                                                                                     |
| `h96-rfcomm.service`                      | runs `depmod` for running kernel, then loads `rfcomm` and `xpad` before BlueZ, so headset microphone (HFP) and X-input pads work                                                                                                                                                                                                                  |
| `bt-sco-hci.service`                      | routes Bluetooth SCO audio over HCI (Broadcom vendor command 0xFC1C, read back with 0xFC1D) so headset microphone carries data; runs `/usr/lib/h96/h96-bt-sco.py`, restarts with `h96-bt.service` and after each `bluetoothd` start; ordered after `multi-user.target`, off boot path                                                                                                                                                                                         |
| `h96-hdmi-audio-detect.service` (v6.2)   | `h96-display detect` at boot: display modes, HDMI audio layouts and passthrough, CEC physical address from display's EDID |
| `h96-hdmi-hotplug.service` (8.0)         | started by udev rule `99-h96-hdmi-audio.rules` on HDMI hotplug: detect for new display only, same display = nothing done |
| `h96-scdc.service` (v6.2)                | HDMI 2.0 tier: verifies SCDC scrambling lock after each modeset and switches back to last working mode when lock fails; off with `h96-display hdmi20 off` |
| `h96-hotspot-repair.service` (v6.2)      | oneshot at boot: restores Wi-Fi client mode when box rebooted with hotspot on; no-op otherwise |
| `h96-leds.service` (v6.2)                | front-panel LEDs (steady or blink, `/etc/h96/leds.conf`, no file = steady); enabled at first boot, `sudo h96-leds off` disables it; `h96-leds clear` at shutdown |
| `h96-display-wake.service`               | daemon: re-drives HDMI output on key or button press when connector is `connected` but `enabled=disabled` (`/usr/lib/h96/h96-display-wake-daemon.py`) |
| `h96-display-wake-once.service`          | started by udev rule `97-h96-display-wake.rules` after HDMI hotplug: one re-drive of stuck output |
| `h96-display-console.service`            | oneshot at boot before display manager: when bootloader left HDMI in YCbCr, one blank cycle lets kernel pick RGB (`h96-display console-apply`); no-op on RGB |
| `h96-autologin.service`                  | oneshot at boot before lightdm: runs `h96-autologin-setup --boot`, which sets lightdm autologin for first desktop user on Plasma X11 session once both exist, one time (`/var/lib/h96/autologin-set`); no-op before that and after |
| `h96-timezone-sync.service` / `.path` (v7.2) | `/etc/timezone` follows `/etc/localtime`: runs at boot and when `/etc/timezone` changes; also run when `systemd-timedated` exits (drop-in below) |
| `h96-armbian-update-guard.service` / `.path` (v7.2) | puts refusing `/usr/sbin/armbian-update` back when `armbian-sync` (ophub script sync) replaces it with ophub kernel updater; journal tag `h96-armbian-update-guard` |
| `h96-dm-handoff-check.service` (v7.1)    | boot check after KDE setup: masks SDDM when reboot came before hand-off mask step; no change when SDDM already masked |
| `h96-protect-updates.service` (v7.0)     | oneshot at every boot, before Armbian first run, video setup, PackageKit and unattended upgrades: `h96-protect-updates` keeps H96 firmware and video stack in place across package updates (see below) |

### Timers

| Unit                        | What it does                                                                                                                          |
|-----------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| `h96-online-extras.timer`   | starts `h96-online-extras.service` once per boot, 40 seconds after kernel boot stamp                                                  |
| `h96-online-extras.service` | retries packages that require internet (`box64-rk3588`, `gamescope`, `libspa-0.2-modules-extra` for Bluetooth AAC) until they install |
| `h96-ytdlp-update.timer`    | `yt-dlp` update 15 min after boot and weekly                                                                                                                |
| `h96-ddc-setup.timer`       | 20 s after boot: installs `ddcutil` from offline repo for `h96-brightness` and KDE brightness slider; done flag `/var/lib/h96-ddc-setup-done`, retries next boot until then |
| `h96-pkgs-setup.timer`      | 30 s after boot: installs `v4l-utils` (`h96-cec`) and `dnsmasq-base` (`h96-hotspot`) from offline repo, then starts enabled `h96-cec.service`; done flag `/var/lib/h96-pkgs-setup-done`, log `/var/log/h96-pkgs-setup.log` |

**About `h96-online-extras`.** Ethernet PHY on this board can take up to 190 seconds to
negotiate, so first-boot gaming setup routinely ran its online half before there was
any connectivity, and never tried again. This unit waits for working connectivity (up to five
minutes, checked by name resolution, because `network-online.target` is satisfied on this
board before link is usable), installs each package on its own so one failure cannot
take others down, and retries on next boot for anything still missing. It sets
`/var/lib/h96-online-extras-done` only when everything is present, and it exits 0 on every
path, so it can never appear in `systemctl --failed`.

It is started by timer, deliberately, and has no `[Install]` section. Pulling it into
`multi-user.target` put its connectivity wait inside boot transaction and pushed
measured boot time to 1min41s, of which 1min35s was this one unit. Log:
`/var/log/h96-online-extras.log`.

### `h96-protect-updates`  (`/usr/sbin`, needs root)

Keeps H96 files in place when package updates carry same paths. Local dpkg diversions send
package copy of each protected path to `/usr/lib/h96-distrib/<path>`; H96 file stays, and
other files of same package install and upgrade normally. Parked copies lie outside library
search path and are never loaded.

- Firmware from `armbian-firmware` (package install or upgrade), under `/lib/firmware` and `/usr/lib/firmware`: Mali GPU
  CSF firmware (`arm/mali/arch10.8/mali_csffw.bin`), Bluetooth patch file
  (`brcm/BCM4362A2.hcd`), AP6275P WiFi firmware, CLM blob and nvram
  (`brcm/fw_bcm43752a2_pcie_ag.bin`, `brcm/clm_bcm43752a2_pcie_ag.blob`,
  `brcm/nvram_ap6275p.txt`).
- Video stack from Ubuntu `mpv`, `libmpv2`, `libmpv-dev`, `ffmpeg` and `librockchip-mpp1`:
  `/usr/bin/mpv`, `/usr/bin/ffmpeg`, `/usr/bin/ffprobe`, `libmpv.so*`,
  `librockchip_mpp.so.0`, and `/etc/mpv/mpv.conf` (purging Ubuntu `mpv` keeps it).

```bash
sudo h96-protect-updates            # add diversions (default, idempotent)
sudo h96-protect-updates --status   # protected or OPEN per path
sudo h96-protect-updates --remove   # drop diversions and parked copies; H96 files stay
h96-protect-updates --help          # usage; no root needed
```

Installing Ubuntu `mpv` adds no second menu entry: `/usr/share/applications/mpv.desktop`
hides package entry (`NoDisplay=true`); "Play in mpv (hardware video)" runs same `/usr/bin/mpv`.

`h96-protect-updates.service` runs it at every boot. After `--remove`, next install or upgrade
of owning package overwrites H96 file again; `sudo apt-get install --reinstall <package>`
puts package version back at once.

### `h96-armbian-update-guard`  (`/usr/sbin`, v7.2)

`/usr/sbin/armbian-update` (ophub kernel updater) is replaced by stub that prints why and
exits 1: ophub updater would write ophub kernel into `/boot` over H96 kernel. `armbian-sync`
copies ophub scripts, ophub updater included, into `/usr/sbin`; `h96-armbian-update-guard.path`
sees it and puts stub back (copy `/usr/lib/h96/armbian-update-h96`). Other ophub
scripts `armbian-sync` updates stay. Kernel arrives with image releases.

### Configuration drop-ins

| File                                                                  | What it does                                                                                                                                                                                                          |
|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `/etc/systemd/system/bluetooth.service.d/20-h96-policy.conf` (v6.2) | runs `/usr/lib/h96/h96-bt-policy.py` before `bluetoothd`: sets `FastConnectable = true` and `ReconnectAttempts = 15` with intervals up to 60 s in `/etc/bluetooth/main.conf`, original kept as `main.conf.orig` |
| `/etc/wireplumber/wireplumber.conf.d/30-h96-bluetooth.conf` (v7.0) | `bluez5.auto-connect = [ a2dp_sink hfp_hf ]`: paired, trusted headset gets stereo and Handsfree links back after audio session restart; Bluetooth sinks never suspend |
| `/etc/sysctl.d/zz-h96-perf.conf` (v7.0)                              | network buffers (`rmem_max`, `wmem_max` 16 MB), TCP Fast Open, BBR; sorts after `99-sysctl.conf`, so values apply |
| `/etc/sysctl.d/zz-h96-hardening.conf` (v7.0)                         | `fs.protected_symlinks = 1`, `fs.protected_hardlinks = 1`, `fs.protected_fifos = 1`, `fs.protected_regular = 1` |
| `/etc/initramfs-tools/hooks/h96-edid` (v7.0)                         | forced EDID (1080p placeholder) in initramfs for first HDMI probe; `h96-display` loads connected display's EDID about 15 s into each boot |
| `/etc/systemd/system/user@.service.d/zz-h96-stop.conf` (v7.0) | user session processes (Steam, games) get 30 s after SIGTERM at logout or shutdown (Ubuntu default 5 s) |
| `/etc/xdg/ddcutil/ddcutilrc` (v7.0) | ddcutil and KDE brightness skip SoC i2c buses 0, 2, 3, 4, 6; HDMI DDC bus stays |
| `/etc/systemd/user/psd.service.d/10-h96-not-root.conf` (v7.0)        | Profile-sync-daemon not started in root's user manager (also `psd-resync.service.d`) |
| `/etc/pipewire/pipewire.conf.d/95-h96-silence-source.conf` (v6.2)   | "Silence (no microphone)" input, so KDE audio applet shows input selector; ranks above output monitors of non-pro sinks and below non-pro capture devices 0 to 27 and Bluetooth microphones, so it becomes input when last such microphone leaves; output monitor of card in pro-audio profile outranks it                                                                                                                          |
| `/etc/xdg/autostart/h96-display-session.desktop` (v6.2)             | re-applies connected display's stored colour format and range at login                                                                                                            |
| `/usr/lib/udev/rules.d/70-h96-pinhole.rules` (v6.2)                      | desktop ignores pinhole recovery button                                                                                                                                           |
| `/etc/systemd/system/fake-hwclock-load.service.d/zz-h96-rtc.conf` (v7.0) | saved clock loads only when hym8563 RTC cannot be read; unit stays active so desktop install or removal through armbian-config no longer sets clock back |
| `/etc/adduser.conf` (v7.0) | `ADD_EXTRA_GROUPS=1`, `EXTRA_GROUPS` audio video render input netdev plugdev: accounts made in KDE System Settings or with `adduser` get hardware video decode, GPU and WiFi tray access |
| `/etc/systemd/system/sddm.service.d/zz-h96-handoff.conf`, `/etc/systemd/system/gdm.service.d/zz-h96-handoff.conf` (v7.0) | `ExecCondition=/usr/sbin/h96-dm-handoff`: desktop install's display manager start runs H96 desktop setup first (see Desktop) |
| `/etc/apt/apt.conf.d/99-h96-desktop-cleanup` (v7.0) | after each dpkg run, queues `h96-desktop-cleanup.service` when KDE or GNOME was removed (see Desktop) |
| `/etc/systemd/system/bluetooth.service.d/zz-h96-sco.conf` (v7.1) | every `bluetoothd` start restarts `bt-sco-hci.service`, so SCO route to HCI is set again after BlueZ comes up |
| `/etc/systemd/system/h96-tune.service.d/zz-h96-after-hwopt.conf`, `/etc/systemd/system/h96-power-profiles.service.d/zz-h96-after-hwopt.conf` (v7.1) | both ordered after `armbian-hardware-optimize` (disabled after first boot), so H96 clocks and governors apply last |
| `/etc/systemd/system/h96-video-setup.service.d/zz-h96-apt-order.conf`, `h96-firstboot-cleanup.service.d/`, `h96-pkgs-setup.service.d/`, `h96-online-extras.service.d/` and `.timer.d/` (v7.1) | boot-time apt runs serialised: first-boot units wait for `armbian-firstrun` (up to 120 s); package timers ordered DDC 20 s, packages 30 s, online extras 40 s |
| `/etc/systemd/system/h96-firstboot-reboot.service.d/zz-h96-journal-orphans.conf` (v7.1) | boot 2 moves boot-1 journal files of replaced machine ID into current machine directory as archived files, so `journalctl --list-boots` lists boot 1 |
| `/etc/systemd/system/h96-hdmi-audio-detect.service.d/10-after-guard.conf` (v7.1) | HDMI detect runs after `h96-display-guard`, so DVI boot-argument sync sees reverted `armbianEnv.txt` |
| `/etc/systemd/system/systemd-timedated.service.d/zz-h96-timezone-sync.conf` (v7.2) | `h96-timezone-sync` runs when `systemd-timedated` exits, about 30 s after zone change through `timedatectl` or KDE |
| `/usr/lib/systemd/user/h96-hdmi-route-sync.service` (v7.2) | wanted by `wireplumber.service`: `h96-audio-passthrough route-sync` in desktop session |
| `/etc/mpv/scripts/h96-dpms-wake.lua` (v7.2) | mpv wakes sleeping X11 display when video playback starts |
| `/etc/apt/preferences.d/00-h96-protect-boot` | Armbian kernel, device tree, U-Boot and board support packages, `u-boot-menu`, `flash-kernel` and its provider `piboot-try` (v7.2) pinned -1; login banner update line reads `Kernel upgrade disabled` |

### Steam helpers

Installed by `sudo h96-steam install` (native route, Steam ARM), not present on fresh image.

| File                                     | What it does                                                                                                                                  |
|------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| `steam-arm`                              | native client launcher; `--desktop` / `--bigpicture` pick interface                                                                           |
| `steam-arm-config`                       | settings menu: install, components, graphics, games, controllers, Remote Play, maintenance (repair, logs, settings backup), uninstall         |
| `steam-arm-tray`                         | panel tray icon with open, open in desktop mode, stop and quit (`tray` component)                                                             |
| `steam-arm-remoteplay`                   | pins Remote Play hardware decoding off and HEVC off; `--check` reports only                                                                   |
| `steam-arm-compatmap <appid> <tool>`     | pins title to compatibility tool (`proton-stable-arm64`, `proton_11`, `proton_experimental`) in client's `config.vdf`; run with client closed |
| `steam-arm-icon`                         | draws menu icons from client's own `steam_tray.ico`                                                                                           |
| `steamos-session-select`                 | called by power menu's Switch to Desktop; restarts client in chosen interface                                                                 |
| `/usr/local/lib/steam-arm-handler.py`    | launch handler run inside Valve's emulation tool before each Linux x86 title                                                                  |
| `/usr/local/lib/steam-arm-fexpatch.py`   | points Valve's emulation tool at launch handler                                                                                               |
| `/usr/local/lib/steam-arm-compatmap.py`  | `config.vdf` editor behind `steam-arm-compatmap`                                                                                              |

### Present but not enabled

| Unit                         | Why                                                                                                                                                        |
|------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `waydroid-container.service` | installed and enabled only by `h96-waydroid init`. Absent until then                                                                                       |
| `h96-shairport.service`, `h96-uxplay.service`, `h96-gmediarender.service` | AirPlay audio, screen mirror and DLNA receivers; `sudo h96-cast enable` enables them |
| `h96-transcode-server.service` | hardware transcode watch folder; `sudo h96-transcode-server enable` enables it |
| `h96-cec.service` (v6.2)     | HDMI-CEC remote daemon, on by default (8.0), starts when `/dev/cec0` appears; `sudo systemctl disable --now h96-cec.service` turns it off |

### Disabled in v5.0

| Unit                             | Why                                                                                                                                                                                                                           |
|----------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `rsyslog`                        | duplicated whole journal to eMMC: 27.8 MB of `/var/log/syslog` in about 10 hours. `/var/log` measured 33 MB before and 3.6 MB right after, with journal capped at 200 MB. `journalctl` is unaffected and still has everything |
| `lxc`, `lxc-net`, `lxc-monitord` | zero LXC containers exist on this image, and Waydroid brings up its own `waydroid0` bridge. Verified after disabling: Android still leases address on its own bridge and pings 8.8.8.8 with 0 percent packet loss. 8.0: lxc arrives with `h96-waydroid install`, which disables and masks `lxc-net` (`h96-waydroid remove` unmasks it) |

journald keeps `Storage=persistent` on purpose, so crash and boot forensics survive
reboot, with `SystemMaxUse=200M` and rate-limit backstop.

Check any unit with:

```bash
systemctl status h96-<name>
journalctl -u h96-<name>
```

To confirm whole system is healthy:

```bash
systemctl --failed          # expect: 0 loaded units listed
systemd-analyze             # see the note below before reading its total
systemd-analyze critical-chain graphical.target
```

In v5.0, `systemctl --failed` reports zero. Two units failed on every boot before that
release: `h96-rfcomm` (its `rfcomm.ko` was 0 byte file and self-heal guard tested with
`-f`, which passes for empty file; it now uses `-s`) and `systemd-modules-load`
(`brcmfmac` was requested alongside `bcmdhd`, which owns WiFi chip, and `rknpu`
is built into kernel). 8.0 lists no WiFi module in `/etc/modules-load.d`: udev loads
`bcmdhd` by its PCI alias on both kernels. `Invalid argument` from module loading means
kernel build and module tree differ (see `h96-kernel-switch status`, `repair-modules`).
`run-rpc_pipefs.mount` stays unmasked; NFS client needs only
`sudo systemctl unmask rpcbind.service rpcbind.socket`.

**Read `systemd-analyze`'s total carefully.** Measured: `graphical.target` is reached
4.860 seconds into userspace, and critical chain contains nothing slower than 19 ms.
42 second figure `systemd-analyze` prints is time until last unit settles, and
two units responsible are Bluetooth units deliberately ordered off boot path in
v4.2. Boot speed was audited on this basis and left unchanged.

> Do not judge either of these during first-boot setup. First boot reboots once on its own,
> and unit that has not run yet reads as failed. Wait until `systemd-analyze` prints
> `Startup finished` before believing any of it.

---

*Unofficial community build; provided as-is, no warranty. All trademarks belong to their
respective owners.*
