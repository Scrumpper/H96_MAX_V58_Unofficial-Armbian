# Changelog



## v6.2 (2026-09-26)

v6.2 over v6.1. Kernel: HDMI-CEC, HDMI 2.0 modes through GPIO DDC bus, colour-format switch without green cast, extended cursor power-domain fix, RGA 2D accelerator. Display: mode list from connected display, per-display colour and range with confirm-or-revert. Native Steam route update: `h96-steam install` carries Steam ARM 1.2. Audio: flat EQ file restores device setup on PipeWire 1.6, and Bluetooth headset microphone, codecs and reconnect behaviour are reworked.

### Kernel

Kernel release string moves to `6.1.115-h96v58v2`. Image, modules and device tree are rebuilt and arrive only by reflash; v6.1.1 hotfix cannot deliver these changes.

- VOP2 window power-domain tracking, extended from v6.1: cursor no longer vanishes after mode change and cursor hide in one frame.
- HDMI-CEC on HDMI0: `/dev/cec0` exists. TV remote controls box; box puts TV in standby and wakes it. Verified on Sony TV. `h96-cec` ships off.
- HDMI0 DDC on GPIO I2C bus, since on-chip DDC controller never completes transfers. Kernel reads EDID natively and drives HDMI 2.0 SCDC scrambling. Verified: 2560x1440 at 120 and 144 Hz, 3840x2160 at 60 Hz.
- Plane colour conversion re-applied on colour-format switch without modeset: switching between RGB and YCbCr no longer leaves green cast.
- HDMI audio channel allocation derived while ELD bypass is on: groundwork for multichannel output. Multichannel is not verified; no AV receiver tested.
- EDID override: guard against NULL dereference. HDMI audio infoframe: pack error checked.
- RGA 2D accelerator binds after deferred probes; `/dev/rga` works.
- stmmac Wake-on-LAN: wake IRQ enable and disable balanced; toggling WoL logs no kernel warning.
- SARADC volume key: driver for pinhole recovery button.
- Kernel build banner carries no build user or host.
- HDMI output stays muted 1 s when colour format changes between RGB and YCbCr: no green flash at boot handover from loader. `dw_hdmi_qp.fmt_switch_mute_ms` sets hold (0 = off).

Two ways to get it:

- **Box already on v6.1:** unzip `h96-v6.1.1-HOTfix.zip` on box and run `sudo bash apply-fix.sh`. No reflash; brings userland changes below, display and backup tools included, not kernel changes above. Colour-format switch without green cast and fullscreen compositor bypass in mpv need v6.2 kernel. Installed games, sign-in and settings are kept.
- **New flash:** `H96-MAX-V58_Unofficial-Armbian_v6.2.img.xz`, flashed as in `FLASHING.md`. Carries kernel changes above that hotfix cannot deliver.

### Added

- `h96-bt-a2dp-heal.service`: when connected Bluetooth headset loses its stereo (A2DP) link, for example after audio session manager restarts, service reconnects it within about 10 s. Checks BlueZ every 5 s; acts only when device advertises A2DP and has no A2DP endpoint for two checks.
- EQ file self-repair: `/etc/tmpfiles.d/h96-eq.conf` restores flat `/etc/h96/eq/active.txt` at every boot if it is missing.
- Wideband Bluetooth microphone (mSBC, 16 kHz) for headsets that support it; CVSD (8 kHz) remains fallback. Measured on box: mSBC link active, voice packets flowing, test signal picked up.
- Classic Bluetooth codec allow-list removed: every A2DP and HFP codec PipeWire has installed is offered; each headset uses best one it supports. Playback: LDAC, aptX HD, aptX, aptX LL, AAC, AAC-ELD, SBC-XQ, SBC, FastStream, Opus. Microphone: LC3-SWB, mSBC, CVSD. AAC and AAC-ELD need package `libspa-0.2-modules-extra`, which `h96-online-extras` installs once box reaches network; it is not in offline repo. LE Audio (BAP) is not offered.
- Launch handler, `/usr/local/lib/h96-steam-handler.py`. Valve's FEX compatibility tool runs it in place of its removal of `LD_PRELOAD`, before runtime container starts. It decides per title, with no launch options:
  - Steam overlay: x86 overlay core for Linux x86 titles by default. Title profile `overlay=vulkan` adds arm64 overlay core and arm64 overlay Vulkan layer, for Vulkan titles; `overlay=off` removes overlay.
  - MangoHud: `mangohud %command%` and `MANGOHUD=1 %command%` both work in Linux x86 titles, OpenGL and Vulkan.
  - Godot 4 titles: OpenGL renderer and GL 3.3 report, found from game's `.pck` header. Godot's Vulkan renderer freezes on splash on PanVK; Panfrost reports GL 3.1.
  - Unity titles, found from player next to game: 64-bit players that carry Vulkan renderer start with `-force-vulkan` and overlay for Vulkan titles; other Unity 5 and later players get GL 4.5 report, since their OpenGL core context asks for more than Panfrost's 3.1 and title stops with `GLXBadFBConfig`; 32-bit Unity players start with Steam overlay off, as title stops when overlay attaches. Profile key `unity=vulkan|gl`.
  - If handler fails, tool behaves as Valve wrote it.
- Title profiles, one Steam app id per line: `/usr/local/share/h96/titles.conf` (shipped), `/etc/h96/titles.conf` (local), and `~/.config/steam-arm/titles.conf` in client home. Keys: `overlay`, `mangohud`, `godot`, `unity`, `env`, `args`, `gl32`, `vk32`. Launch options `STEAM_ARM_OVERLAY=x86|vulkan|off` and `STEAM_ARM_PRELOAD_KEEP=a,b` override profiles.
- Steam ARM 1.2 handler rules: 32-bit titles lose `-vulkan` and `-force-vulkan`, since FEX forwards Vulkan for 64-bit code only (profile key `vk32=keep` keeps them); titles started through start script (Source engine style) are detected by binary script starts; profile key `gl32=off` runs title not detected as 64-bit on emulated x86 Mesa instead of forwarded host Mesa; profile `args` count for Unity and Godot renderer rules; Source 2 titles logged. Component checklist appears as desktop dialog when installer starts with no controlling terminal.
- arm64 Steam overlay Vulkan layer, which client ships but does not register, registered behind `STEAM_ARM_VK_OVERLAY`; handler sets it only for titles profiled `overlay=vulkan`.
- Direct3D 8 titles under Proton run through DXVK's `d3d8`: launcher sets `PROTON_DXVK_D3D8=1`. Proton's default for Direct3D 8, wined3d on OpenGL, draws them wrong on Mali driver. Launch option `PROTON_DXVK_D3D8=0 %command%` restores default.
- Launcher removes shared-memory segments no process maps from `/dev/shm`, at start and every minute. Steam overlay's 26 MB frame buffers stay mapped by `steamwebhelper` after game ends; with no game running, sweep frees their pages within about 2 minutes (hole punched, files and mappings kept).
- `desktop-mode` component: menu entry "Steam ARM (Desktop mode)", opens client in its desktop interface, for signing in.
- `icon-bigpicture`, `icon-desktop` and `tray` components: each desktop icon and tray icon chosen on its own, or none.
- Power menu's Switch to Desktop: `steamos-session-select` restarts client in desktop interface.
- `steam-arm --desktop` and `--bigpicture` switch running client: it closes through its own shutdown and starts again in that interface.
- Right-click actions on main menu entry open either interface.
- `h96-steam install --help` prints usage: options, components with defaults marked, examples, environment variables.
- Page size check before anything installs; emulation needs 4K pages. This box runs 4K pages, so check passes. `page-size` component has no effect on this box.
- Installer states that installed games, sign-in and settings are kept on install, re-run and component changes.
- Display mode list from connected display: `h96-display detect` reads display's EDID and lists its modes, up to 8K. Modes wider than 4096 px and FRL tier (above 600 MHz) are listed but untested and experimental; `sudo h96-display frl off` removes them. Mode is picked in KDE System Settings → Display; choice persists per display across replug and reboot.
- HDMI 2.0 tier (340 to 600 MHz, SCDC scrambling), on by default: 2560x1440 at 120 and 144 Hz, 3840x2160 at 60 Hz. `sudo h96-display hdmi20 off` opts out.
- Colour format and range, command line only: `sudo h96-display color rgb|ycbcr|auto` and `sudo h96-display range full|limited|auto`; `color status` and `range status` report setting and signal. New value applies live, then asks "Keep this ...? Reverting in 15 s [y/N]". Only y keeps it; timeout, other keys, Ctrl-C or closed terminal revert. `--yes` keeps without asking. Kept values are stored per display, keyed by display's manufacturer, product and serial, and re-applied at boot and login (`/etc/xdg/autostart/h96-display-session.desktop`). Display with no stored value starts at RGB full range, default. YCbCr always uses limited range (display engine limit); range setting applies to RGB only. Screen may blank for about 2 s during switch.
- mpv: VPU decode through `rkmpp-copy`; `hwdec=rkmpp,rkmpp-copy` falls back to it automatically, since zero-copy path is unavailable under X11. YouTube in mpv prefers 8-bit VP9; 10-bit HDR streams decode in software; AV1 is excluded. Fullscreen video bypasses KWin compositing (`x11-bypass-compositor=fs-only`). Measured: 1440p60 VP9 plays without dropped frames; 4K60 VP9 drops frames, limited by frame copy-back. On 4K display pick 1440p or lower in YouTube playback.
- `h96-leds`: front-panel LEDs lit and steady by default. `sudo h96-leds blink` adds activity blinking (Ethernet traffic, eMMC access, heartbeat); `sudo h96-leds off` darkens them. Order after `armbian-led-state` keeps saved state from overwriting it at boot.
- Opt-in tools, installed and off until enabled: `h96-wol` (Wake-on-LAN; netplan-aware, so setting persists), `h96-cec` (TV remote and TV power over HDMI-CEC), `h96-vm` (KVM/QEMU virtual machines; slim installer can remove it), `h96-hotspot` (Wi-Fi access point). Enable commands: README, "New in v6.2".
- HDMI-CEC display wake, on whenever `h96-cec.service` runs: when key or mouse wakes display from DPMS off, box sends TV Image View On and Active Source, so TV powers on and switches to box. Keypress after 10 min idle does same, for TV put in standby with its own remote while display stayed on. At most once per 10 s. `sudo h96-cec wake off` turns it off. `sudo h96-cec standby-on-blank on` (off by default) sends TV to standby when display goes DPMS off. Verified on Sony TV.
- `h96-hotspot-repair.service`, enabled: restores Wi-Fi client mode when box rebooted with hotspot on.
- Pinhole button ignored by desktop (`70-h96-pinhole.rules`).
- HDMI audio auto-detect, on: channel layouts follow display's EDID and show as card profiles in KDE audio applet and System Settings. Compressed passthrough (AC3/DTS) not supported yet: HDMI path sends it as PCM noise; stereo PCM works; multichannel PCM (5.1, 7.1) untested.
- `h96-backup` / `h96-restore` v2.1. Restores backups from v5.0.1 and newer; backward compatibility is kept for every future release. Archive adds display and CEC flags, per-display colour and range files, KDE display configuration (kscreen) and WirePlumber state. Autologin is restored as setting through one drop-in, never raw LightDM files. Steam client runtime is left out by default (`--with-steam-runtime` includes it). `h96-migrate-kit.zip` is updated.

### Fixed

- Native Steam installer stopped at RootFS step when earlier RootFS download was left behind (FEX's fetcher asked to overwrite it and aborted). Leftover download is removed before fetch. Shipped title profile list is empty; handler's engine rules cover Unity titles on Vulkan.
- `h96-restore` created missing folders in desktop account's home owned by root, and restored symlinks as root: Steam and other programs then failed to write there. Folders and symlinks restore owned by desktop account.
- Console text green on displays whose EDID lists YCbCr: loader left HDMI in YCbCr and kernel kept it until desktop login. `h96-display-console.service` blanks console once at boot (about 2 s) when output is YCbCr; kernel then selects RGB.
- Enabling mSBC removed Bluetooth headset profile: codec allow-list in `30-h96-bluetooth.conf` did not name HFP codecs, which PipeWire 1.6 loads as plugins, so negotiated mSBC codec was never found (`failed to get HFP codec 2`). Allow-list removed.
- Choppy Bluetooth audio: at PipeWire's 512-sample cycle (10.7 ms) Bluetooth encoder and h96 EQ filter chain missed their deadline now and then (xruns). While Bluetooth headset plays, it now forces 2048-sample cycle (43 ms); other outputs keep low latency.
- Bluetooth headsets powered off or disconnected after audio stopped: sink suspended after 5 s idle, and headset then dropped link on its own timer. Bluetooth sinks no longer suspend (A2DP stream stays open with silence; costs some headset battery). BlueZ reconnects faster (`FastConnectable`) and retries dropped headset 15 times with backoff to 60 s (`/etc/bluetooth/main.conf`, original kept as `main.conf.orig`).
- Bluetooth headsets showed no audio device or microphone, and sound streams started after it (Remote Play among them) got no output: h96 EQ filter chain reads `/etc/h96/eq/active.txt`, which only `h96-audio-eq` writes. PipeWire 1.6 stops filter graph when that file is missing, and failed node stalls WirePlumber, so no later device or stream is set up. Image now ships flat `active.txt` (0 dB).
- Titles drew on CPU renderer (llvmpipe) after fresh install. Client downloads Valve's FEX tool at first title start, after launcher applied its settings, so GL and Vulkan forwarding stayed off until next client start. Launcher now applies them within one second of tool appearing or being replaced, and covers `/run/gfx/main`, where current runtimes mount graphics libraries.
- Steam overlay UI (`gameoverlayui`) crashed on every start: client's helper programs load libraries from client's own directory, which launcher now puts on library path.
- Client's desktop windows had no title bar until next login: setup now tells KWin to reload its window rules after writing frame rule.
- Menu icon missing on fresh install: icons now come from client's own `steam_tray.ico`, not from x86 Steam package that fresh root filesystem does not carry.
- `vk-spoof` resolves `vkDestroyDevice` when device is destroyed, not straight after device creation.
- Every title failed to start, with `Bus error`, after many game sessions: `/dev/shm` filled with 26 MB segments Steam overlay left behind per session, and launch helper died writing to one. Launcher now sweeps unmapped segments at start and every minute; overlay buffers `steamwebhelper` still maps are freed within about 2 minutes of last game ending.
- Launch handler did not run when FEX tool had been patched by standalone Steam ARM installer (same marker, other handler path). Installer and launcher now check for their own handler path and re-point tool.
- Menu entry and desktop icon "Steam ARM" showed no icon: icon file carried wrong name.
- Re-run keeps client home: installer reads `ARMHOME_DIR` from `/etc/h96/steam-arm.conf` that earlier run wrote, so re-run or fix script never moves client away from its games.
- Kernel module tree `/lib/modules/6.1.115-h96v58v1` was owned by desktop account (uid 1000): module archive stored builder's owner and first boot kept it. Archive now stores root, and first boot extracts with `--no-same-owner`.
- Persistent journal moved to `/var/log.hdd` every day, so `journalctl --list-boots` showed only current boot: `armbian-ramlog` is masked, but `ENABLED=true` in `/etc/default/armbian-ramlog` still made logrotate move logs and let `armbian-truncate-logs` wipe them at 75 % root use. Set to `false`.
- `h96-audio-eq` state file was readable by root only, so `status` without sudo showed EQ off and `preset` without sudo lost stored settings. State file now 0644, and every EQ file is written atomically.
- `h96-audio-eq enable` always put EQ in front of HDMI, even with Bluetooth headset as default output. It now follows current default output (ALSA or Bluetooth); `--target <sink>` picks one.
- Bluetooth adapter stayed discoverable to every nearby device: `h96-bt-attach.py` set inquiry scan after bluetoothd started. It now sets page scan only (connectable, paired devices reconnect).
- HDMI codec rule `51-h96-iec958.conf` matched no output (exact name instead of pattern).
- `h96 <tool>` ran tool's action when tool had no help option: `h96 h96-wifi-connect` saved Wi-Fi network named `--help`, and other tools installed, unbound pads or started second VFD daemon. Every h96 tool now answers `-h` and `--help` without side effects; `h96` shows help text on error output too and lists no backup copies.
- `h96-bt-speaker status` showed blank adapter fields (BlueZ 5.85 rejects `show hci0`).
- `h96-steam status` printed stray `not-found` line; `h96-steam-remoteplay --check` looked in wrong home and reported no `localconfig.vdf`.
- Steam installer re-run reset component selection and account and wiped other keys in `/etc/h96/steam-arm.conf`. Selection (`COMPONENTS_ON`, `COMPONENTS_OFF`) and account (`GAMEUSER`) are now saved there and kept; `--keep` re-runs with them. Deselecting `map-count` no longer removes image baseline `zz-h96-steam.conf`.
- Launcher left its FEX tool watcher running after 60 s switch timeout; watcher now stops on every exit path. Launcher re-applies FEX settings when tool's server socket path names other account.
- Unity scan in launch handler looped forever on engine file without Vulkan marker.
- Native and standalone Steam ARM installers overwrote each other's launcher; each now stops when other one is installed, unless `--replace-other` is given.
- Desktop install from `armbian-config` left its console mid-install: first-boot configure scripts started display manager while install still ran. They now wait for dpkg lock and for `armbian-config` to exit, so installer stays on screen until setup finishes.

### Changed

- "Silence (no microphone)" input device, lowest priority: KDE audio applet shows input selector only with two or more inputs, so default microphone can now be confirmed and set from tray. Choosing it silences input for apps that follow default device.
- Bluetooth headset microphone listed at all times, by device name: WirePlumber autoswitch is on, so headset uses Handsfree while app records and returns to stereo A2DP after. Before, mic existed only after picking Handsfree by hand, so voice apps started earlier did not see it and tray input selector could not switch to it. While mic is open, output is mono call quality.
- `h96-steam` help drops two lines: route option note and "Steam on this box, installed on demand".
- Menu icons: dark, grainy green disc with small squares of vivid colour; chartreuse logo for Big Picture, bone logo for desktop mode.
- `desktop` component covers menu entry and window frame rule only; desktop icons and tray are components of their own.
- Launcher starts tray helper, so tray icon appears in session setup ran in, not only after next login.
- Component checklist shows all twelve components without scrolling.

### Known issues

- Proton ARM64 titles: MangoHud and arm64 Steam overlay layer each crash title at device creation, together with `vk-spoof`. Handler does not run for these titles; leave `MANGOHUD` unset for them.
- Steam overlay in OpenGL titles: controller Steam button opens it but cannot close it; Shift+Tab or on-screen close button does. In Vulkan titles Shift+Tab does not open it; controller Steam button opens and closes it.
- Remote Play: Shift+Tab goes to host PC and can stall picture; use controller Steam button.
- Some native OpenGL titles stop when Steam overlay attaches. Profile `overlay=off` for that title in `/etc/h96/titles.conf`, or launch option `STEAM_ARM_OVERLAY=off %command%`.
- Some native titles leave one thread behind on quit; client shows title as running until Stop.
- Windows titles whose first start runs legacy PhysX installer (msiexec) stop there, and title does not start without it.
- Windows titles that need Direct3D feature level 11_0, such as Unreal Engine 4 titles, do not start: DXVK on Mali driver offers 10_1.
- After installer or fix script runs, restart Steam once (tray icon > Stop Steam, then open Steam ARM). Client left running across update can fail to start titles until then.
- Multichannel HDMI audio (5.1, 7.1) is not verified; no AV receiver tested.
- Compressed passthrough (AC3/DTS) not supported yet: HDMI path sends it as PCM noise; stereo PCM works; multichannel PCM (5.1, 7.1) untested.
- AV1 has no hardware decode path; YouTube in mpv excludes AV1.
- 4K60 VP9 in mpv drops frames (frame copy-back limit); 1440p60 VP9 plays without drops.
- One HDMI output (HDMI0).

## v6.1 (2026-09-20)

v6.1 over v6.0. Ships as new image only. Kernel release string changes, so moving to it
is reflash, not `apt upgrade`. One device tree node changes: watchdog is enabled, and
every v6.0 feature and command is retained.

**Steam, installed on demand.** `h96-steam` installs either of two clients and downloads
nothing until it runs. Native route installs ARM64 client, which runs on Mali GPU
as ARM program; titles built for x86 run through emulation tool client downloads,
and Windows titles through client's ARM64 Proton build. Emulated route installs
x86-64 client under FEX-Emu on KDE desktop. Both install into desktop user's account
and keep separate libraries, so one box can carry both; run one at time, because two clients
compete for controller and for `steam://` links. Titles protected by anti-cheat do not run
on either route: those components require system call filter emulator does not implement.
Both installers present checklist of components and remove component again when it is
deselected on later run.

**ARM64 client.** ARM64 client is build of Steam that Valve made for its ARM based
VR headset, Steam Frame: native ARM program that runs title's x86 code through emulation
tool client downloads. On this box that means client interface, overlay, input
stack and download and shader systems run on CPU and GPU directly, only title itself
is emulated, and title's OpenGL and Vulkan calls reach Mali driver through
forwarding libraries. Windows titles go through Valve's ARM64 Proton build, whose Direct3D layer
reaches Mali Vulkan driver same way. Valve maintains this build for hardware of same
architecture, so emulation tool updates, ARM64 Proton builds and per-title fixes arrive with
client updates. VR itself is not part of this box: there is no VR runtime or headset support,
and launcher removes client's VR argument from streaming client. Emulated route
runs x86-64 client under FEX-Emu, with every part of client emulated and its interface
software rendered.

`steam-arm --desktop` starts client in its desktop interface instead of Deck interface,
`--bigpicture` forces Deck interface, and `H96_STEAM_ARM_UI=desktop` in
`/etc/h96/steam-arm.conf` makes desktop default. Deck build of client registers no
item in panel's system tray, so `desktop` component also installs `h96-steam-tray`,
which places Steam icon in tray with menu to open client in either interface, stop
it, or quit tray, and autostart entry so it appears at login.

`h96-steam-remoteplay` pins two Remote Play client settings this box requires, hardware
decoding off and HEVC off, in client's stored configuration. Streaming client decodes
through Vulkan Video, which Mali driver does not provide, so with hardware decoding
advertised session can sit on launch screen and never finish negotiating; with it off
host keeps to H.264 and software decoder. Launcher runs it before each start, and it
runs on its own with `--check` to report without changing anything. Keep game window in
foreground on host: game in background renders nothing new, so stream
shows one frame and takes no input.

**Hardware cursor: window's power domain.** v6.0 fixed cursor latch in VOP2 display
driver. v6.1 fixes second path in same driver, where power domain that feeds
cursor window could be switched off while window still held reference to it. Pointer
then moved and clicked with nothing drawn, and state held until reboot. Driver now
records reference per window, powers domain on whenever window needs it, and refuses
release that has no matching reference, reporting it once in kernel log so recurrence
names its caller. Change is published as `patch/kernel/h96-vop2-cursor-pd.patch`,
applied after `patch/kernel/h96-vop2-cursor.patch`, and `config/linux-rk35xx-vendor.config`
is v6.1 build's configuration.

**One joystick node per pad.** Third-party Xbox 360 style pads that expose headset interface
were bound twice by `xpad` driver, so one pad appeared as two identical joysticks and
two-player game handed player 2 copy of player 1. Udev rule unbinds driver from that
interface as pad is connected, and `/usr/local/sbin/h96-xpad-dedup` does same for pads
that are already up. Pads that expose one interface are unaffected.

**Controller access for game clients.** Client runs as desktop user and reads pad over
`/dev/hidraw`, which kernel creates for root account only. Rules that hand those
devices to logged-in user cover pads client has drivers for, so pad from any
other maker stayed unreadable: client fell back to generic event device, where pad
reports no battery level and cannot rumble. `/etc/udev/rules.d/60-h96-gamepad-hidraw.rules`
covers every pad kernel's `xpad` driver recognises, 243 of them, and `/dev/uinput`, which
client uses to present its own controller to title. Each pad is matched on vendor and product
rather than vendor alone, because several makers in that list also make keyboards and mice,
which rules leave untouched.

**`vm.max_map_count`.** Raised to value Proton expects, since Windows titles map many small
regions and warn below it. Drop-in is named `zz-` because `systemd-sysctl` reads every
directory in one filename order and `/etc/sysctl.conf` joins that order as `99-sysctl.conf`, so
`99-` name is read before it and lower value in `/etc/sysctl.conf` would win at every boot.

**Kernel release `6.1.115-h96v58v1`.** Suffix names board and kernel revision number
that moves independently of image version, so kernel is identifiable from `uname -r`
alone. Module set is rebuilt against it with `CONFIG_MODVERSIONS=y` as in v6.0, so module
built for v6.0 release is refused rather than loaded. Two kernel debug options are off in this build that were on in v6.0, `SLUB_DEBUG` and `SCHEDSTATS`; neither is used by anything image ships, and `perf sched` and `/proc/schedstat` lose their scheduler statistics as result. This build adds `CONFIG_LOCKUP_DETECTOR=y`, `CONFIG_SOFTLOCKUP_DETECTOR=y` and `CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y`: CPU that makes no scheduling progress for 20 seconds is reported and kernel panics.

**Hang recovery.** During acceptance testing of v6.1 image one boot stopped 86 seconds in,
with box powered and no record of cause, and box needed power cycle. v6.1 adds
watchdog and set of kernel checks that reset box when kernel or PID 1 stops
responding, and keep record of why. Device tree enables RK3588 DesignWare watchdog,
`watchdog@feaf0000`, so `/dev/watchdog0` exists. `/etc/systemd/system.conf.d/zz-h96-watchdog.conf`
sets `RuntimeWatchdogSec=30s` and `RebootWatchdogSec=2min`: systemd opens device with 30 second timeout,
driver rounds that up to 44 second hardware period, systemd pets it at half that
period, and kernel or PID 1
that stops responding is reset after 44 seconds. `/etc/sysctl.d/zz-h96-hang.conf` sets
`kernel.hung_task_timeout_secs = 120`, `kernel.hung_task_panic = 1` and `kernel.panic_on_oops = 1`,
so task blocked for 120 seconds panics and oops panics instead of continuing, and
`kernel.panic = 10` holds panic on console for 10 seconds before rebooting. Panic
record survives reset: `/sys/fs/pstore` at next boot is moved by `systemd-pstore` to
`/var/lib/systemd/pstore/` as `console-ramoops-0`, which holds previous boot's console and is
replaced at every boot, so copy it before next reboot; panic kernel log lands in same
directory as `dmesg-ramoops-*` files. Verified end to end: with `kernel.panic` set
to 0, so panic path itself could not reboot box, forced kernel panic led to watchdog
reset, and box was back on network 75 seconds later, with panic recorded in
`/var/lib/systemd/pstore/console-ramoops-0`.

**Desktop authentication.** Kernel has no pidfd support, so polkit's socket-activated helper
stays masked and authentication runs through setuid helper
`/usr/lib/polkit-1/polkit-agent-helper-1`. `polkitd` upgrade reinstalls that helper without
setuid bit, after which KDE authentication dialog opens and closes at once and Discover installs
fail. Image registers helper in `/var/lib/dpkg/statoverride` as `root root 4755`
(`dpkg-statoverride --update --add root root 4755 /usr/lib/polkit-1/polkit-agent-helper-1`), so
dpkg keeps setuid bit through every `polkitd` upgrade.

**Offline package repo is signed.** `/opt/h96-pkgs` carries `Release`, `InRelease` and
`Release.gpg`, and its apt source names `/usr/share/keyrings/h96-local-archive-keyring.gpg` in
`Signed-By`, so apt verifies it as it does every other repo. It was marked `Trusted: yes` before,
which apt 3 reports on each update as `Missing Signed-By`. Signature and Release date are
2026-01-01, so offline first boot verifies with clock at image's saved date. Public keyring,
source file and pin are in `packages/bsp/h96-max-v58/apt/`; signing key stays with image build.

**Backup and restore window.** Dry run opens in its own window, closed with `q` or Esc. On
displays under 1200 pixels tall window opens maximized, and category rows carry no padding, so
every row, note and button of either tab is on screen. Terminal window that Back up now and
Restore now open waits for Enter at end and then closes. Wrapped notes follow window width.

**Theme.** `h96-backup-gui` banner, header rule and band above status strip carry `scrumptop`
texture, redrawn to window width. `scrumptop` banner and `h96-backup-gui` block text share one
colour, chartreuse `#9cc865`; texture in both is darker and sparser, with scattered bright
blocks. `q` closes backup window when no text field has focus.

This project is not affiliated with, endorsed by or sponsored by Valve Corporation. Steam,
Proton, Steam Deck and Steam Frame are trademarks of Valve Corporation. No Valve artwork ships in image.


## v6.0 (2026-09-07)

v6.0 over v5.0.1. Ships as new image only. Kernel Image changes, so moving to it is
reflash, not `apt upgrade`. Device tree is unchanged since v4.3. Every v5.0 feature and
command is retained.

v6.0 absorbs planned v5.2. Kernel changes across several rebuilds, cluster-aware
scheduling together with VOP2 cursor driver fixes, are substantial enough to warrant
major version rather than point release. This is versioning and scope statement, not
performance claim: `CONFIG_SCHED_CLUSTER` is topology-correctness only and cursor work is
correctness fix; benchmarking found no measurable change in throughput, and none is claimed.

- **Hardware cursor during GPU compositing, fixed in kernel driver.** v5.0.1 kept mpv
  cursor visible during playback (`cursor-autohide=no`) as workaround for RK3588 VOP2
  hardware-cursor latch bug: under continuous GPU compositing hardware cursor plane was not
  restored once it had been hidden, so after mpv hid cursor during fullscreen playback
  pointer stayed invisible until reboot. v6.0 fixes it in kernel driver by re-asserting
  cursor on video-port latch each frame, so hardware cursor stays visible during
  continuous GPU compositing (fullscreen video, animated browser pages, desktop splash); it
  still auto-hides over video and returns on movement, and it survives leaving mpv back to
  desktop. `/etc/mpv/mpv.conf` restores `cursor-autohide=1000` with `x11-bypass-compositor=never`,
  so autohide is active during playback and KWin compositing stays on in fullscreen.
- **`h96-backup` and `h96-restore`.** Flash writes whole eMMC and removes every on-demand
  feature installed on top of console base. `h96-backup` captures one archive: manifest of
  which features are present (desktop, emulators, Waydroid, Widevine, gaming, NPU runtime) plus
  passive data that cannot be re-downloaded (config subset, emulator saves, wine
  prefix, WiFi credentials, Waydroid `/data`). Multi-GB Waydroid image stashes are left
  out by default (`--with-images` includes them); restore re-downloads them instead.
  `h96-restore` reads manifest, reinstalls recorded features, then restores passive
  data to correct paths and owners. Config file already present and newer than
  archived copy is kept, not overwritten; `--force` overwrites it (stop desktop session
  first on fresh image, whose session has already written default configs). `--open`
  prints installer commands for you to run yourself instead of running them; `--dry-run`
  prints plan and changes nothing. Both tools take `--only` and `--skip` category lists
  and `--emulators`; `h96-backup-gui` presents same choices as checkboxes and runs
  tools in terminal window. Boxes on v5.0.1 or earlier have no backup tool; migration kit (`h96-migrate-kit.zip` in release) installs same three tools there (`sudo bash install.sh`, `--gui` for window) so box can be captured to USB stick before flash.
- **`h96-undervolt` trial flow corrected.** Trial flow now works as documented: `set <mV>`,
  then reboot, and setting is active on that boot so you can test it under load; `test` runs
  SIMD load; `confirm` keeps it. Reboot without confirming and boot-time guard reverts to
  stock device tree on its own. Previously guard could revert setting before there
  had been boot on which to confirm it.
- **Kernel: `CONFIG_SCHED_CLUSTER`.** Kernel now enables `CONFIG_SCHED_CLUSTER`, which
  represents RK3588 as its three CPU clusters instead of one flat group, so scheduler's
  topology view matches hardware. On this board clusters are 4x Cortex-A55 (cpu0, cpu5,
  cpu6, cpu7), 2x Cortex-A76 (cpu1, cpu2) and 2x Cortex-A76 (cpu3, cpu4); two A76 pairs are
  separate DVFS clusters. This is topology-correctness change: benchmarking found no
  measurable change in throughput, and none is claimed.
- **Kernel BTF type data.** Kernel carries BPF Type Format (BTF) data
  (`CONFIG_DEBUG_INFO_BTF`, with `CONFIG_DEBUG_INFO_BTF_MODULES` for module set):
  `/sys/kernel/btf/vmlinux` describes kernel's types (7 MB) and every module exports its
  own, so `bpftool`, `bcc` and CO-RE BPF programs read kernel and module types on box
  without kernel headers. `bpftrace` kprobes walk kernel structs same way; pass
  `--traceable-functions` with symbol list from `/proc/kallsyms`, since this kernel has no
  ftrace function list. BTF is data that BPF tools read; machine code is same with or
  without it, and kernel Image grows by 7 MB. Armbian's own rk35xx kernel configuration
  ships with BTF on. VOP2 cursor fix ships in this repo as
  `patch/kernel/h96-vop2-cursor.patch`, built with `config/linux-rk35xx-vendor.config`.
- **Known kernel-log item.** At boot kernel prints two `WARNING` traces from
  `pinctrl-rockchip.c` (`rockchip_pmx_gpio_set_direction`, `pin 143 already requested by
  fde80000.hdmi` and `pin 144 already requested by fde80000.hdmi`). They come from
  `h96-ddc-i2c-gpio` overlay reassigning HDMI DDC pins to i2c-gpio bus for DDC/CI
  brightness control. They are harmless; kernel sets its `W` taint flag and nothing else
  changes.
- **Kernel log cleanup.** `H96DBG` diagnostic lines that v5.0.1 printed during HDMI setup
  are gone; HDMI PHY driver reports clock setup errors instead of hiding them, and
  unused secure-OTP driver is left out of build (`CONFIG_NVMEM_ROCKCHIP_SEC_OTP=n`).
  Board-support patch set is published as `patch/kernel/h96-board-support.patch`.
- **Kernel release `6.1.115-h96`, modules rebuilt with symbol versioning.** Release
  string is `6.1.115-h96` (`CONFIG_LOCALVERSION="-h96"`) and modules live in
  `/lib/modules/6.1.115-h96`. Full module set (3110 modules) is built from same
  source and configuration as kernel Image, with `CONFIG_MODVERSIONS=y`: every module
  carries symbol versions, and loader rejects module built against different kernel
  layout instead of loading it unchecked. Earlier releases shipped module set built against
  pre-PSI configuration; those modules loaded on 6.1.115 kernels because vermagic
  string matched, and only modules in use had been checked by inspection. Bcmdhd
  WiFi module and every other module now carry matching symbol versions, and kernel's
  `O` (out-of-tree) taint flag is gone; only taint left is `W` from DDC pinctrl
  warning above. Moving to v6.0 remains reflash. `H96-rfcomm` service no longer
  hardcodes kernel release; it reads `uname -r`. `config/linux-rk35xx-vendor.config` is
  full kernel configuration Image and modules were built with;
  `config/kernel-h96-max-v58.config` summarises options that differ from vendor
  default, and README build steps install modules with kernel.
- **Repository.** Full kernel configuration is published as
  `config/linux-rk35xx-vendor.config` (Armbian framework consumes full config, not
  fragment). Device tree source is `patch/kernel/rk3588-h96-max-v58-panthor.dts`,
  decompile of DTB image boots; earlier copy predated PCIe WiFi enablement,
  and board file's `BOOT_FDT_FILE` now names booted DTB. Board file pins
  kernel source to commit kernel was built from and restores options
  framework rewrites. `packages/bsp/h96-max-v58/systemd/h96-rfcomm.service` is added.
- **`CONFIG_RT_GROUP_SCHED` off.** It was on, inherited from vendor Android
  configuration. Realtime scheduling is now available to processes outside root cgroup:
  PipeWire's data-loop threads run at `SCHED_RR` priority 20 through rtkit, so audio threads
  keep their priority under CPU load, and `cyclictest` runs. Previously journal logged
  `Failed to make ourselves RT: Operation not permitted` on every boot and audio threads
  ran as normal tasks.
- **`xpad` built with player-LED and force-feedback support.** `Xpad` USB
  game-controller module is built with `CONFIG_JOYSTICK_XPAD_LEDS=y` and
  `CONFIG_JOYSTICK_XPAD_FF=y`. 2.4 GHz X-input dongles that wait for Xbox 360 player-LED
  command before they start reporting now work; verified with 8BitDo Ultimate 2C Wireless
  Controller and its dongle. Previously dongle enumerated, driver bound and
  `/dev/input/js0` existed, but no input arrived, while same pad worked over Bluetooth.
  Force feedback (rumble) is available on xpad-driven controllers. Kernel Image is
  unchanged by this; only module set changed. Both options are in
  `config/linux-rk35xx-vendor.config`, `config/kernel-h96-max-v58.config` and board
  file's `custom_kernel_config` hook.

## v5.0.1

v5.0.1 over v5.0. Ships as new image and as fix-script for running box (no reflash).
Kernel Image and device tree unchanged since v4.3.

- mpv cursor over fullscreen video fixed. `/etc/mpv/mpv.conf` sets `cursor-autohide=no` and
  `x11-bypass-compositor=never`. RK3588 VOP2 hardware cursor plane is not restored after
  mpv hides it during playback (kernel driver un-hide fault), so once hidden cursor
  stayed invisible until reboot. `cursor-autohide=no` stops mpv from hiding hardware
  cursor. Driver fix that lets cursor fade during playback and return on movement is
  deferred to v6.0.
- `h96-waydroid` clean teardown. Closing Android window stops session and
  container, releasing GPU container held. Sudoers drop-in lets desktop user run
  `h96-waydroid stop` without password. Stop Android menu entry was added.
- `h96-waydroid` borderless fullscreen. `h96-waydroid size fullscreen` opens window
  borderless at 0,0 filling screen. It opens at screen size, so there is no output
  reconfigure and no black surface.
- `h96-waydroid` q to quit. Started from terminal, launcher quits and tears down on `q`
  then Enter, in addition to closing window.

## v5.0

Kernel rebuild, two new opt-in tools, and stability pass over
v4.2.1. Shipped as one full image; flasher still slims it to headless, no-GPU, or
bare-server build on demand.

Released image is **console only**: no desktop and no user account. Desktop is
installed on demand (`armbian-config`, or `apt install kde-plasma-desktop`), and
`h96-autologin-setup` then wires lightdm autologin to `plasmax11` (X11) session.
Reflashing wipes existing desktop install.

- `.img`    sha256 `6a193bdf330b6de0156a7a26ca24e2fbe0343b57783295581f9aada7606a990c`
- `.img.xz` sha256 `f9f824d52bc381cac37f591452fe4aa8111543b2af3678146dc506ad8ad3ae95`

- **Kernel rebuilt with `CONFIG_PSI=y`** (`PSI_DEFAULT_DISABLED` off), from
  armbian/linux-rockchip, branch `rk-6.1-rkr5.1`, commit `95e85f6c`. Android 11 and later
  `init`/`lmkd` hard-require `/proc/pressure`; without it Waydroid container boots and
  then dies in about 15 seconds. It is **Image-only rebuild**: PSI is built in and
  kernel release string is unchanged at 6.1.115, so `/lib/modules/6.1.115` stays valid and
  no module is rebuilt. Verified on hardware: 69 modules load with matching vermagic.
  **Existing users cannot `apt upgrade` into this kernel. It needs new image.**

- **New `h96-waydroid`: Android in container.** Waydroid 1.6.2 plus nested Weston
  window inside X11 session. Three image profiles:
  - `init gapps|vanilla`, DEFAULT: official Waydroid LineageOS 20 image
    (`lineage-20.0-20260403-VANILLA-waydroid_arm64`, Android 13, vendor type MAINLINE,
    about 900 MB), with Mali-G610 wired by default (`drm_device=/dev/dri/renderD130`,
    `ro.hardware.gralloc=gbm`, `ro.hardware.egl=mesa`, `renderD130` and `card2` bound into
    container). Measured: `dumpsys SurfaceFlinger` reports
    `GLES: Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.1`; GPU load reads
    `0@300000000Hz` at idle, reaches 50 percent at 1000 MHz under UI activity, and sits at
    19 to 26 percent at 600 MHz. `boot_completed=1` with session ready in about 8
    seconds. Android 13 is cgroup v2, so no cgroup v1 shims are applied.
  - `init gpu`, LEGACY: third-party Panthor-in-image Android 11 build (LineageOS 18.1,
    about 5 GB) that you supply. Measured on this profile, `dumpsys SurfaceFlinger` reports
    `GLES: Mesa, Mali-G610 (Panfrost), OpenGL ES 3.1 Mesa 24.0.5`; GPU load runs 27 to 41
    percent at 300 to 700 MHz. Older Android, older Mesa, unsigned, needs cgroup v1 tmpfs
    shims, pins 960x512 display that has to be overridden, Vulkan never worked, and it
    has been abandoned since April 2024 (author WillzenZou, repos frozen). Kept only for
    anyone holding that image.
  - `init custom <dir>`: your own arm64 Waydroid-style `system.img` plus `vendor.img`
    PAIR.
  - `hw off` forces software rendering, as diagnostic and fallback; `hw on` re-applies
    GPU wiring and verifies it.

  Correction to earlier claim in this changelog: official LineageOS 20 image was
  described as carrying no Panfrost and software rendering through SwiftShader. That was
  wrong. Tool's own `init` was forcing `ro.hardware.egl=swiftshader` and deleting
  `drm_device`, so measurement described our configuration, not image. Upstream
  enables ARM drivers in `waydroid_arm64/BoardConfig.mk`
  (`BOARD_MESA3D_GALLIUM_DRIVERS += ... panfrost lima`, `BOARD_MESA3D_VULKAN_DRIVERS +=
  ... panfrost`), not in the root `BoardConfig.mk`, which lists only llvmpipe, virgl and
  friends. One constraint stands: HALIUM vendor images are stripped of Mesa GPU
  drivers, so MAINLINE vendor image is required, and MAINLINE is what these profiles
  fetch.

  Images are 2 to 5 GB, are **not** bundled, and are stashed under `/etc/waydroid-extra/`
  so switching profiles never re-downloads. Window is **fixed size on purpose**: any
  window-manager geometry change makes Weston reconfigure its X11 output, Waydroid
  client cannot follow, and window goes permanently black; launcher pins
  `WM_NORMAL_HINTS` min equal to max. `spoof` reports box as common phone for Aurora
  Store, and does **not** defeat Play Integrity or SafetyNet. `state save|list|load|delete`
  snapshots Android `/data`, and refuses cross-profile restores because Android 11 data
  on Android 13 crashes `system_server`.

  **Honest limit: container cannot use RK3588 NPU.** Its `vendor.img` has no RKNN
  libraries and no neuralnetworks HAL, so passing node through would hand Android
  device file with no driver.

- **New `h96-emulators`: 8 GPU-accelerated systems.** `retroarch`, `dolphin`, `ppsspp`,
  `flycast`, `melonds`, `rmg` and `azahar` as native ARM64 Flatpaks through PanVK/Panfrost,
  plus `cemu` as x86-64 build under `box64`. `install` wires each Flatpak's sandbox to
  Mali GPU and then verifies it, warning when emulator would silently fall back to
  `llvmpipe` software rendering. mGBA and ScummVM are deliberately excluded: they are 2D,
  do not meaningfully use GPU, and are already in software store as `io.mgba.mGBA`
  and `org.scummvm.ScummVM` on Flathub, or as apt `mgba-qt` and `scummvm`.

- **`h96-npu` gains `power [performance|balanced|powersave|sync|status]`.** NPU devfreq
  had been pinned at 1000 MHz for 100 percent of uptime while nothing used it; `powersave`
  parks it at 300 MHz. `power sync` matches NPU to system CPU and GPU profile, and
  `sync on` makes it follow `h96-perf` automatically. `h96-perf` is now listed in `h96`
  command index.

- **Two units that failed every boot are fixed**, so `systemctl --failed` now reports zero.
  `h96-rfcomm` shipped 0 byte `rfcomm.ko` and its self-heal guard tested `-f`, which
  passes for empty file; it now tests `-s`. `systemd-modules-load` requested `brcmfmac`
  alongside `bcmdhd`, which owns WiFi chip, and `rknpu`, which is built in.

- **`rsyslog` disabled.** It duplicated whole journal to eMMC: 27.8 MB of
  `/var/log/syslog` in about 10 hours. `/var/log` measured 33 MB before change and 3.6 MB immediately after. Journal itself is deliberately persistent and capped at 200 MB on eMMC plus 32 MB in tmpfs, so `/var/log` settles under that cap rather than staying at 3.6 MB. `journalctl`
  is unaffected.

- **`lxc`, `lxc-net` and `lxc-monitord` disabled.** Zero LXC containers exist and Waydroid
  uses its own bridge. Verified afterwards that Android still leases address and pings
  8.8.8.8 with 0 percent loss.

- **Boot speed audited and deliberately NOT changed.** `graphical.target` is reached 4.860
  seconds into userspace. 42 second figure in `systemd-analyze` is time until last
  unit settles, which is two Bluetooth units intentionally ordered off boot path.

- **TESTED AND REJECTED: shadowing container's `/dev/kmsg`** to cut log noise. It
  mounts cleanly, but Waydroid container then never starts. Recorded here so nobody
  retries it.

- **`h96-emulators` GPU verification, four bugs fixed.**
  1. `gpu_probe()` only tested that Panfrost ICD **file** existed inside sandbox.
     That file ships with `org.freedesktop.Platform.GL.default`, so it is present for every
     app using that extension: check could never return "software" and verified nothing.
     It reported PPSSPP as hardware while PPSSPP's default OpenGL backend was failing with
     `EGL_BAD_ALLOC` and never opening window. Probe reads renderer string now
     and falls back to file test only as last resort, labelled "renderer NOT verified"
     rather than claiming hardware.
  2. Tool's user environment set only `WAYLAND_DISPLAY`, never `DISPLAY` or
     `XAUTHORITY`, and this box is X11 on purpose, so no GL probe could reach display.
     After fix automatic probe verifies four of seven Flatpaks directly as
     `Renderer: Mali-G610 MC4 (Panfrost)`, Qt based ones where renderer tool exists
     inside runtime. Other three report "renderer NOT verified" rather than claiming
     hardware; hand testing from their own logs confirmed `retroarch` and `flycast` on
     hardware too, and PPSSPP only on its Vulkan backend.
  3. `gpu` silently skipped `cemu` (`if kind != "flatpak": continue`), hiding entry most
     likely to have GPU trouble. It is reported explicitly now.
  4. `elevate()` re-execs tool as root with `sudo -E`, which is deliberate so `DISPLAY`
     and `XAUTHORITY` survive for probe. But `-E` also carried `HOME=/home/<user>` into
     root process, and flatpak initialises per-user repo at
     `$HOME/.local/share/flatpak` on almost any invocation. Run as root that repo landed in
     desktop user's home owned by root with mode 700, so every later `flatpak run` as
     that user failed with `Permission denied` and probe could only report `unknown`,
     which reads as missing GPU when GPU is fine. `elevate()` now pins `HOME=/root`
     while keeping `-E`, and repair pass corrects ownership on boxes already in that
     state.

- **`h96-waydroid` wires GPU by default.** `init gapps|vanilla` no longer forces
  SwiftShader. cgroup v1 tmpfs shims are applied only on legacy Android 11 path, since
  Android 13 is cgroup v2. `status` now keys profile off which image stash is linked
  rather than off `drm_device`, which is always set now, and image identity properties are
  cleared on init so profile switch cannot leak previous image's model string.

- **zram self-heals.** Swap came up disabled on fresh flash despite being configured.
  Self-heal unit re-establishes it at boot.

- **KDE screen locker is off by default.** `/etc/skel/.config/kscreenlockerrc` ships
  `Autolock=false`, `LockOnResume=false`, `Timeout=0`, so TV box does not lock itself.

- **Image builder no longer leaks orphan inodes.** It issued blind `mkdir` per path
  component; `debugfs` leaks inode when directory already exists, which is where
  34 empty numbered directories under `/lost+found` came from. Builder stats before
  creating now. 35 inherited from earlier builds are still present, empty and harmless.

- **First boot no longer races Armbian's setup wizard for dpkg lock.**
  `h96-online-extras.service` runs right after `multi-user.target`, exactly when first-run
  wizard is creating user account. It took lock with no wait, so wizard died with
  "could not get frontend lock" and finished its work in background. Script now waits
  for lock (`fuser` poll, pattern `h96-gaming-setup.sh` already used) and passes
  `DPkg::Lock::Timeout=600` on both apt calls.

- **Flashing no longer needs pinhole button.** Box that still boots is put into Loader
  mode with `reboot loader` over SSH, and flasher converts Loader to Maskrom itself.
  Pinhole method stays documented as fallback for box that will not boot.

## v4.2.1

Adds `h96` command index. Type `h96` on box to list every command grouped by
category, or `h96 <command>` to open that command's help. Otherwise identical to v4.2.

## v4.2

Efficiency delta on v4.1. Same kernel (6.1.115), device tree, and hardware enablement.
Shipped as one full image; flasher slims it to headless, no-GPU, or bare-server build
on demand.

- **Faster boot.** Bluetooth attach was moved off boot-critical path with
  `After=multi-user.target` drop-in on `h96-bt` and `bt-sco-hci`. `multi-user.target` is
  reached in about 3 to 4 seconds, against about 44 seconds on v4.1 where attach blocked
  it while BCM4362A2 firmware loaded. Bluetooth still attaches a few seconds into
  already-booted system.
- **`h96-gaming-setup` retires after first boot.** Its completion flag was gated on wine
  binary that v4.1 moved to fetch-on-demand, so it re-ran apt work on every boot. Flag
  now sets on first successful boot and service retires.
- **zram swap compression changed from lzo-rle to zstd**, and VM sysctl tuning
  (`/etc/sysctl.d/zz-h96-tune.conf`) is baked into image so it survives fresh flash.
- **Flasher input validation.** Unrecognized menu input no longer advances to flash; only
  listed menu keys are accepted.

## v4.1

Shipped as three pre-built image variants, all booting to text console:

- **v4.1** (full): KDE Plasma is not pre-installed. Install it on demand through
  `armbian-config`; first launch of Plasma applies H96 desktop settings.
- **v4.1-NODESKTOP**: headless, no desktop-install capability.
- **v4.1-NODESKTOP-NOGPU**: headless, with Mali GPU removed (driver blacklisted
  and GPU packages pruned) while hardware video (VPU) path is kept.

Image free space is zeroed with `zerofree` before compression, so zips are
smaller than earlier releases: about 1.22 GB (full), 1.01 GB (nodesktop), and
0.91 GB (nodesktop-nogpu).

1. Bluetooth headset MICROPHONE now works. Every earlier release could play audio
   to Bluetooth headset but never capture its mic: stock kernel shipped no RFCOMM,
   so Hands-Free profile could not open and Bluetooth was pinned to A2DP-only.
   v4.1 ships `rfcomm.ko` built for this exact kernel (6.1.115), loads it before
   BlueZ, and re-enables Hands-Free / Headset roles. Headset mic shows up as
   input source under "Headset Head Unit" profile; apps that record can switch to
   it. Codec is CVSD (call quality, narrowband). Wideband mSBC negotiates with
   headset but its audio link will not carry over this box's Broadcom UART Bluetooth
   radio, hardware limit, so CVSD is ceiling here. Selecting headset-mic
   profile drops output to mono call quality until deselected; that is how classic
   Bluetooth works, not bug.

2. Bluetooth headset profile now stays selected. WirePlumber used to revert
   manually chosen Hands-Free (mic) profile back to A2DP whenever no application was
   recording, so selected mic profile did not hold. v4.1 disables that autoswitch
   (`bluetooth.autoswitch-to-headset-profile = false`), so chosen profile is
   single coherent choice, input follows output, and it persists across reconnects.
   A2DP carries no mic (classic Bluetooth limit), so mic exists only under
   Hands-Free profile.

3. AAC Bluetooth audio output. Headsets that advertise AAC now negotiate it instead
   of plain SBC. AAC plugin installs on first networked boot
   (`libspa-0.2-modules-extra`). Codec preference: LDAC, aptX-HD, aptX, AAC, SBC-XQ,
   SBC.

4. Bluetooth adapter reliability on boot. BlueZ could start before UART Bluetooth
   adapter finished attaching, then report no controller, so KDE showed no Bluetooth
   after some reboots. v4.1 orders BlueZ after adapter bring-up and waits for adapter
   node to appear.

5. Bluetooth boot fix for headless images. On minimal (headless) base SCO
   audio-routing service (`bt-sco-hci.service`) failed because BlueZ `hcitool`
   CLI is only pulled in by desktop install, so headless boxes booted
   `degraded`. Service now skips when that CLI is absent and still sends SCO
   routing command on desktop images. Ordering race that let routing command
   fire before adapter finished attaching is also fixed: service polls
   adapter for `UP RUNNING` before sending, and retries send.

6. USB game-controller dongles. Base kernel had no xpad driver, so X-input
   controllers and 2.4GHz pad dongles did nothing over USB; only D-input / HID pads
   worked. v4.1 ships xpad built for this kernel with updated device table and
   vendor-wide matches for common controller makers, autoloaded, plus udev
   catch-all that binds any X-input dongle even if its USB id is not in table.

7. Media feature suite. All OPT-IN: image ships command only; each tool
   installs its packages and activates on first use, so fresh flash carries no
   extra weight and nothing auto-starts.
   - h96-cec: control box with TV remote over HDMI-CEC.
   - h96-hdr: HDR10 tone-mapping to SDR in mpv (vo=gpu-next / libplacebo).
   - h96-motion: mpv built-in frame interpolation (judder reduction), on GPU.
   - h96-npu-upscale: offline Real-ESRGAN x4 super-resolution on NPU.
   - h96-audio-passthrough: HDMI bitstream (AC3 / DTS / E-AC3) + multichannel LPCM.
   - h96-audio-eq: system-wide parametric EQ via native PipeWire filter-chain.
   - h96-bt-speaker: box as Bluetooth A2DP speaker (pair phone, audio to HDMI).
   - h96-cast: AirPlay audio + screen mirror + DLNA renderer (open Cast substitute).

8. Slimmer image. Wine + DXVK gaming stack (~206 MB) is no longer baked in;
   h96-game-mode fetches it on first use.

9. Experimental Steam installer removed. Steam under x86 emulation on RK3588 is
   unstable and too heavy for this box. Gaming path stays `h96-game-mode`
   (Windows games under wine + DXVK on open GPU).

10. Note for GameCube/Wii emulation: apt `dolphin-emu` is broken by this image's
    Qt 6.10, Qt-internal fault that pins one CPU core at 100% and freezes its
    window. Use Flatpak Dolphin instead; it carries its own Qt and renders on GPU
    via PanVK.

## v4.0

1. Hardware video decode now works for desktop users and on fresh flashes. It was
   root-only in every earlier release, and fresh flashes could not install video
   stack at all.
2. Desktop lists connected display's native resolutions and refresh rates,
   updates list when different display is plugged in. Off by default; enable with
   `sudo h96-display autodetect on`. `h96-display` also gains `auto`, `4k60`, and `8k`.
3. Monitor backlight control over DDC/CI: `h96-brightness`, plus desktop's own
   brightness slider.
4. `scrumptop`: themed terminal system monitor built for this SoC.
5. Desktop lock screens authenticate. They could not in any earlier release.
6. NPU and hardware video encoder are exposed for first time
   (`h96-npu`, `h96-npu bench`, `h96-encode`), plus GPU upscaling (`h96-upscale`)
   and on-device subtitle generation (`h96-subtitles`).
7. CPU overclock and undervolt tools with measured results (`h96-undervolt`).
8. Screen wake: blanked HDMI output that never returned on keypress is
   re-driven automatically (`h96-display-wake.service`; manual:
   `sudo h96-display wake`). See 2c.
9. Widevine L3 browser DRM, opt-in: `sudo h96-widevine-setup`
   fetches CDM on demand; DRM streams cap at SD (L3 hardware limit). See 8.
10. Display scale: `h96-scale <factor>` sets KDE global scale and applies it live
    (restarts Plasma shell); autologin enabled so logout re-applies it. On
    X11 log out/in is required for scale change to reach all apps. Wayland
    not used (breaks GPU/compositing/mpv).

11. `h96-bench --gpu` renders on Mali GPU under X11. Earlier it invoked
    Wayland-only glmark2 binary that cannot initialize EGL canvas on this X11
    image, so `--gpu` printed "Could not initialize canvas" and reported no
    score. Now picks `glmark2-es2` on X11, `glmark2-es2-wayland` on Wayland.
    Progress-loop abort under `set -e` that ended runs early with no summary is
    also fixed, so benchmark now shows live ticks and exits clean.
    Measured: Mali-G610 MC4 (Panfrost), GLES 3.1, 4111 FPS build scene at 1000 MHz.

### 1a. Hardware video decode was root-only

`/dev/dma_heap/*` is where MPP allocates decode frame buffers. It defaults to 0600,
root-only. Hardware decode initialization fails for non-root processes
(`Failed to init MPP context: -1`) and mpv falls back to software decode with no error
shown in UI. Root processes are unaffected. Prior validations of video stack ran
as root over SSH and did not encounter failure. Present in every release to date.

v4.0 ships udev rule setting DMA heaps to `root:video 0660`. Desktop users are in
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

On fresh flash, **both mpv and ffmpeg failed to start**:

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

**Fix.** `fontconfig-config` is now included in offline repo, with correctly generated
`Packages` entry. Its own dependency (`fonts-dejavu-core`) was already in image, so that
one package completes chain. Also: offline repo is now pinned low (priority 1) so its packages, some of which exist online at same version (fontconfig-config, usb.ids), are no longer offered as phantom updates in Discover that never finish. It stays fully usable for offline first-boot install.

**Verified on fresh flash with nothing done by hand:** mpv v0.41.0 starts, ffmpeg starts,
three hardware encoders present, and `h96-video-setup` finally sets its done-flag and skips on
following boot.

**If you are on v3.4** and hardware video does not work, this is why. Either update to v4.0 or
run once:

```bash
sudo apt update && sudo apt install -y fontconfig-config libass9 libplacebo360 libxv1 libxpresent1
```

**Why it went unnoticed for so long:** every earlier test ran on box where other packages had
been installed by hand, which pulled `fontconfig-config` in as side effect. It only shows on
clean flash.

### 2a. Display autodetect (opt-in): native mode lists

Kernel cannot read display's EDID (DDC controller defect), so desktop lists only
baked default modes. `sudo h96-display autodetect on` turns on native-mode
enumeration: service reads attached display's EDID over `i2c-ddc` bus and places
it for desktop to read, and udev rule re-reads it on cable hotplug. It enumerates
modes only and never switches output: it strips EDID's color-format bits (YCbCr,
deep color, HDR) so driver stays RGB 8-bit, sets preferred timing to 1080p60 so
first login is safe, and never forces re-detect or modeset. Live output is never
re-driven, so it cannot tint or blank screen. Reboot after enabling so desktop
reads new mode list, then pick mode; KDE remembers it per display. OFF by
default (box runs forced 1080p60); `sudo h96-display autodetect off` reverts.
Measured on 2560x1440@144 monitor: native mode list present, output stays clean.
`h96-display` also gains `4k60` and `8k` presets (`8k` is unproven: needs HDMI 2.1 FRL
output, 8K display, and certified cable).

**Choosing refresh rate.** When autodetect is on and you pick higher resolution in
Display Settings, also set refresh rate HDMI cable can carry. High refresh rates
(120 Hz, 144 Hz) and 4K at 60 Hz need Premium High Speed or Ultra High Speed HDMI cable;
standard or TV-grade cable may show black screen at those rates while working at 60 Hz.
On this box, 2560x1440 at 60 Hz was confirmed over standard cable; 120/144 Hz and
4K at 60 Hz require certified cable. KDE reverts unconfirmed mode after 15
seconds, so wrong pick returns to previous mode. Known limit: enabling autodetect
can disable HDMI audio (audio path reads capabilities from boot EDID, which
autodetect replaces). If sound disappears, run `sudo h96-display autodetect off`
and reboot; audio returns.


### 2b. `h96-display auto` reads display's EDID

SoC's HDMI DDC i2c controller never completes transaction on this kernel, which is
why this image forces display mode. DDC wires work: stock Android reads EDID over
them. `sudo h96-display auto` reads EDID over `i2c-ddc` kernel bus created by
brightness overlay, falling back to direct GPIO read (character-device uAPI) when that
bus is absent. It validates EDID (header, per-block checksums), picks display's preferred mode capped at
this box's limits, and sets it through existing one-boot trial and `keep`
confirmation. On any read or parse failure current mode is left unchanged. Measured
on hardware: 256-byte read takes 1.5 s at 2 kHz bit-banged clock and does not disturb
running display; 5 consecutive reads were byte-identical. Reader source:
`packages/bsp/h96-max-v58/src/ddc-edid-read.c` (image ships it precompiled).

### 2c. Screen wake: HDMI re-drive on keypress

Once HDMI output is dropped (X starting while monitor is asleep, or hotplug
while blanked), BSP kernel never re-initialises PHY/VOP path on its own:
connector sits `connected` / `enabled=disabled`, kernel logs `User-defined
mode not supported` on re-probe, and keypress shows nothing while box stays
SSH-reachable. Box never suspends (Armbian base masks suspend targets; RK3588
BSP suspend does not resume), so dark unresponsive screen is always this
output-drop state, not sleep. Fix: `h96-display-wake.service` watches input
devices; on key or button press while connector is connected but disabled,
it re-drives output with explicit X modeset at forced boot mode plus
`xset dpms force on`. Udev rule runs same check after hotplug
(`HOTPLUG=1`). Normal blanking is untouched: healthy DPMS keeps
`enabled=enabled` and daemon acts only in broken state. Manual trigger:
`sudo h96-display wake`. Measured: broken state forced via `xrandr --off`,
one injected keypress, picture back in about 4 s (`hdptx phy lane locked`,
`vop enable intf`, journal `re-drove HDMI-1 (1920x1080@60)`).

### 3. Monitor brightness over DDC/CI

`h96-brightness` sets connected monitor's backlight over DDC/CI (VCP 0x10), not
software gamma dim. SoC's HDMI DDC i2c controller does not complete transactions on this
kernel, so `h96-ddc-i2c-gpio` device-tree overlay (enabled by default) exposes two
DDC pins (GPIO4_B7=SCL, GPIO4_C0=SDA) as kernel i2c-gpio bus named `i2c-ddc` at 100 kHz,
and ddcutil drives DDC/CI over it. 100 kHz rate is required: at 2 kHz monitor's
DDC/CI controller could not clock value bytes and writes failed verification. Measured on
Dell P2419H: brightness set to 30/75/15/60 tracked exactly with on-screen change. ddcutil installs
automatically at first boot. Display must accept DDC/CI writes (most
PC monitors; enable "DDC/CI" in monitor menu). Most TVs gate DDC/CI behind HDMI/CEC
handshake this box cannot perform and are not controllable. With KDE plus ddcutil, PowerDevil
shows brightness slider. Overlay source: `packages/bsp/h96-max-v58/overlays/`; CLI:
`packages/bsp/h96-max-v58/tools/h96-brightness`. Because overlay reassigns pins HDMI
controller already holds, kernel prints two `WARNING` traces from `pinctrl-rockchip.c`
(`rockchip_pmx_gpio_set_direction`, `pin 143 already requested by fde80000.hdmi` and `pin 144
already requested by fde80000.hdmi`) at boot. They are harmless; the kernel sets its `W` taint
flag and bus works.

### 4. `scrumptop` system monitor

Terminal system monitor in project color scheme (purple frames; green/amber/red
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

New command `h96-npu bench` runs INT8 matmul through NPU runtime. Measured:
~625 GOPS one core; `h96-npu bench all` pins one job per core for ~1.29 TOPS across 3 cores. Requires runtime installed by `h96-npu-setup`.

Whole terminal is framed in theme: wordmark badge in outer border, side
rails, and block wordmark set in green into dark textured banner. Usage bars are
segmented; temperature gauges use narrower glyph. Rendering is line-diffed (only changed lines
are rewritten each tick). Measured at 1 s refresh: 0.66% of one core, 20 MB resident.

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

|               |                                                          |
|---------------|----------------------------------------------------------|
| kernel driver | `RKNPU driver: v0.9.8` (build 20240828)                  |
| cores         | 3, with live per-core load in `/proc/rknpu/load`         |
| frequency     | 1000 MHz, 8 OPPs from 300 MHz, governor `rknpu_ondemand` |
| DRM node      | `card1` (`DRIVER=RKNPU`) → `/dev/dri/renderD129`        |
| permissions   | default user is already in `render`, so no root needed   |

New command **`h96-npu`** reports all of it, watches per-core load live, and can pin
frequency to specific OPP (validated against kernel's own OPP list, root only, resets
on reboot).

### 6b. Inference runtime is NOT bundled, deliberately

`librknnrt.so` is proprietary. It ships under Rockchip's **"RKNN SDK License"**, whose
clause 1.2 permits reproducing copies **"on internal basis only"**. This image is
published publicly under GPL-2.0, so it cannot carry that binary, and build now
**fails on purpose** if file is ever found inside image.

New command **`sudo h96-npu-setup`** fetches it from Rockchip instead, showing you their
licence first. Verified end to end: it installs `librknnrt version: 2.3.2` against driver
v0.9.8, validates that download is aarch64 shared object before installing
anything, and `--uninstall` removes it cleanly.

**Known limitation, stated.** Rockchip publishes `rknn-toolkit-lite2` wheels only
up to CPython 3.12. This image is Ubuntu 26.04 with Python 3.14, so **those wheels will
not install against system interpreter**. C API works (`dlopen` and `rknn_init`
confirmed present); Python convenience layer needs CPython ≤ 3.12 you bring yourself.
Model conversion (`.onnx`/`.pt` → `.rknn`) has always run on PC, not on box.

### 6c. `could not find sram resource!` is expected here; do not "fix" it

NPU logs this at boot and it is **correct behaviour on this board**. RK3588 system SRAM
is already allocated in full to two video decoders, with no gap:

| region                | offset    | size                  |
|-----------------------|-----------|-----------------------|
| `sram@ff001000` total |           | `0xEF000` (978,944 B) |
| `rkvdec-sram@0`       | `0x00`    | `0x78000` (491,520 B) |
| `rkvdec-sram@78000`   | `0x78000` | `0x77000` (487,424 B) |

`0x78000 + 0x77000 = 0xEF000` exactly; zero bytes free. Giving NPU SRAM region means
taking it from hardware video decode, which is whole point of TV box. Rockchip's own
in-tree RK3588 device trees do not wire NPU SRAM either. NPU runs from DRAM and works.

Malformed `rockchip,sram` phandle here would be worse than warning: overlapping
rkvdec allocation hands same physical SRAM to two drivers, which is data corruption
with no error reported, rather than immediate failure.

### 6d. Hardware video encode, exposed

Encode was enabled entire time and never surfaced: `RKVENC`/`RKVENC2`/`JPGENC` in
kernel, both `rkvenc-core` nodes `status = "okay"` in device tree, `/dev/mpp_service`
present, and bundled ffmpeg already carrying `h264_rkmpp`, `hevc_rkmpp` and
`mjpeg_rkmpp`.

This matters more than it sounds: **bundled ffmpeg has no `libx264`**, so before now
box had no working encode path at all despite shipping silicon for it.

New command **`h96-encode`**. Measured on H96 Max V58: 1080p encoded **faster than
180 fps** on both H.264 and HEVC, faster than test's one-second timing granularity
could resolve.

```
h96-encode clip.mkv out.mp4                 # H.264, 8 Mb/s
h96-encode clip.mkv out.mp4 -c hevc -b 6M   # HEVC
h96-encode clip.mkv small.mp4 -s 1280x720   # hardware scale, then encode
h96-encode --list                           # what this build can encode
```

### 6e. GPU upscaling

New `h96-upscale` enables **ravu-lite-ar-r4** (bjin/mpv-prescalers, LGPL-3.0) as mpv user
shader on Mali-G610 through Panfrost.

Measured on this board, 720p clip, `--untimed`: **3.81 s → 4.31 s, about 10-13% more GPU
time**, compiling clean with zero GLSL errors. `on`/`off` edit marked block in
`/etc/mpv/mpv.conf` and restore it byte-for-byte.

Two findings worth recording, because both contradict obvious guess:

- **`gather/` variant does not work here.** It needs `textureGatherOffset`, which this
  GLES context does not provide (`error: no function with name 'textureGatherOffset'`).
  *root* variant is one that compiles, even though this context also reports
  `compute shaders=0`, which would normally point other way.
- **FSRCNNX and nnedi3 are not viable on this GPU.** G610 measures around 470 GFLOPS,
  roughly 9-19× below cards those shaders are usually demonstrated on.

It needs desktop or compositor session; image boots headless. `h96-upscale test` falls
back to `cage` when no session exists, but **cage does not engage rkmpp hardware decode**, so
that path measures shader cost only, not playback; hardware-decode coexistence with
shader is therefore still unverified under desktop session.

### 6f. Subtitles: `h96-subtitles`

Offline speech-to-subtitles, producing timed `.srt` from any media file.

**Measured here:** RTF **0.130** (7.7× realtime) on film audio using **one** A76 core,
2-hour film in ~15 minutes with seven cores left free. **WER 1.09%** on LibriSpeech test-clean
against human transcripts; coherent and usable on 1936 film dialogue with music.

**It was built for NPU, and NPU lost.** Measured on same audio: NPU (3 cores)
RTF **0.271** against **0.124** for single A76 core; CPU is **2.2× faster than whole
NPU**, and four threads (0.147) are slower than one. Limit is memory bandwidth, exactly as
with overclock and NPU LLM work. `--engine npu` remains available for comparison.

Engine and model are fetched by `sudo h96-subtitles-setup`, not bundled: both are
Apache-2.0, but they total ~340 MB. **Prebuilt** binary is used, so no compiler is required.
Downloads are SHA-256 recorded and re-verified.

`h96-subtitles live` exists but is **experimental and unfinished**. Streaming ASR measured
2.5× realtime and mpv overlay renderer is protocol-verified, but live capture needs
desktop session (no PipeWire on headless image) and display. It refuses with actionable
errors rather than pretending.

### 7. CPU tuning, measured

`h96-undervolt oc` adds 2400 MHz operating point (vendor tree stops at 2208). It is
offered because it works and is safe to try, **not** because it is worth keeping.

**Measured on this board**, on correct 12 V supply, `sysbench cpu` with 4 threads pinned to
big cores, 3 alternating reps, 3 s settle, clock verified *mid-run*:

| rep      | 2208 MHz   | 2400 MHz   |
|----------|------------|------------|
| 1        | 3729.50    | 3750.15    |
| 2        | 3731.47    | 3749.88    |
| 3        | 3730.63    | 3750.58    |
| **mean** | **3730.5** | **3750.2** |

**+8.7% clock produced +0.53% work**, and peak temperature rose 82 °C → 85 °C. 2400 MHz was
stable at **975 mV** and clock was sustained, confirmed by live sampling and by
`time_in_state` (13442 ticks at 2400 against 812 at 2208). It does not help:
compute-bound workload that ought to scale with clock doesn't, because limit on this SoC
is memory bandwidth (~21 GB/s), not core frequency.

**Two measurement traps, both of which produced wrong answers first:**

1. **Pin to big cores.** 8-thread run shows ~0% because this SoC is 4× A76 + 4× A55,
   A55s are unchanged at 1800 MHz, and they gate total. Topology is **not
   contiguous**: `policy0` is cpus **0,5,6,7** (A55s), and big cores are **1,2,3,4**:
   ```
   taskset -c 1,2,3,4 sysbench cpu --threads=4 --time=15 run
   ```
2. **Let it settle, and verify clock during run.** First attempt gave 2829 vs 3724
   for *same* 2208 setting: 32% variance from thermal and residual load, far larger than
   effect being measured.

**Useful direction is opposite one.** 2400 MHz ran stable at 975 mV while vendor
assigns 962.5 mV at 2208 for this chip, so there functions voltage headroom at stock speed.
Undervolting buys lower heat and power at identical performance, which on fanless box is
worth more than any clock increase.

Both `set` and `oc` edit same device tree, so only one can be active at time, and each
arms trial that self-reverts on next boot unless you `confirm`.

**Undervolting: also tested.**

Sweep was run on correct 12 V supply, at stock 2208 MHz, each offset applied fresh from
stock and rebooted before testing. **Every offset was stable, up to tool's −50 mV cap**
(cluster1 is bin L4 at 962500 µV against 912500 µV vendor floor).

Stability was not useful question. Thermally-matched comparison (both runs cooled to
55 °C first, clock pinned and verified at 2208 MHz under load) says this:

|         | voltage      | clock    | start | end   | events/s    |
|---------|--------------|----------|-------|-------|-------------|
| stock   | 962 / 975 mV | 2208 MHz | 56 °C | 64 °C | **3758.40** |
| −50 mV | 912 / 925 mV | 2208 MHz | 56 °C | 63 °C | **3594.62** |

**−50 mV costs 4.4% performance to save 1 °C.** Sweep's own trend corroborates it
independently (−10 mV → 3741, −50 mV → 3587), and gap is far outside ±0.03%
repeatability measured elsewhere. *Why* same verified clock does less work at lower voltage
is unexplained; it is recorded as observation, not theory.

**Taken together, stock is right setting.**

| change                         | performance | thermal |
|--------------------------------|-------------|---------|
| overclock to 2400 MHz @ 975 mV | **+0.53%**  | +3 °C   |
| undervolt −50 mV @ 2208 MHz   | **−4.4%**  | −1 °C  |

Both directions are net-negative on this hardware. Tools exist so you can verify that for
yourself on your own chip (silicon varies), but on this one vendor's settings win.

**If you repeat this, four traps.**

1. **`revert` does not take effect until you reboot.** Running kernel keeps device tree
   it booted with, so "stock" reading taken straight after `revert` is still *old* tree.
   This made stock and −50 mV look identical during testing and nearly produced opposite
   conclusion.
2. **In `regulator_summary`, field 5 is `opmode` and field 6 is voltage.** Reading field 5
   yields useless string `normal`.
3. **Read voltage under load with clock pinned.** It tracks current operating point,
   so at idle it reads low no matter what you set.
4. **Cool to matched temperature between runs.** Consecutive runs heat-soak, and drift is
   larger than effect being measured.

### Appendix: branding

Block-letter header is now single shared library on box
(`/usr/local/lib/h96/banner.sh` and `.py`) rather than pasted into each script, with two
distinct wordmarks: **Scrumpper's Firmware Suite** for flashers and installer, and
**Scrumpper's Unofficial Armbian** for on-device tools. It stays TTY-gated, so
scripts that also run from systemd units print nothing into journal.

### Appendix: HDMI DDC, investigated, controller still unfixed

Intended headline for this release was making board read display's EDID,
which would have removed forced mode, substitute EDID and their boot cost. **It did
not work, and record is worth more than quiet omission.**

Every layer of DDC path was verified *correct*: VO1_GRF routing
(`VO1_CON3 = 0x00002e00`), pin mux (`hdmim0`, GPIO4_B7/C0, identical pins all three
stock Android device trees use, on box where Android reads EDID fine), absence of any
pin conflict, SCL timing (`clk_hdmitx0_ref` 428.57 MHz → exactly 100 kHz), slave
address, and interrupt unmasking. Yet i2c read never completes and returns neither
DONE nor NACK.

One plausible fix was tested and **refuted cleanly**: raising DDC completion timeout from
`HZ/10` to `HZ` scaled wait from 102 ms to 1.013 s, proving patch was live, and
changed nothing: EDID still read 0 bytes, timeouts unchanged. Giveaway was that i2c
interrupt still arrived ~109 µs *after* timeout at **both** deadlines: constant offset
from deadline rather than from transfer start means that interrupt is generated by
timeout handler's own controller reset, not by late completion. Do not ship `HZ`: 54
timeouts at 1.013 s each add roughly 55 seconds to boot.

So v3.4's approach stands: forced mode, and HDMI audio works. But measuring **fresh
flash** of v4.0 corrected *why* it works, and earlier explanation was wrong.

### Appendix: correction, substitute EDID never loads

On freshly flashed box kernel reports:

```
platform HDMI-A-1: Direct firmware load for edid/h96-1080p-audio.bin failed with error -2
[drm:edid_load] *ERROR* Requesting EDID firmware "edid/h96-1080p-audio.bin" failed (err=-2)
```

Blob is present in rootfs (256 bytes, CTA block intact), but DRM probe runs at
about 4.1 s, while system is still on initramfs, and that initramfs contains **zero**
`lib/firmware` entries. `request_firmware()` therefore cannot find it, on v3.4 or v4.0.

`drm_edid_load.c` explains difference from v3.3 exactly. It matches requested name
against in-kernel table before ever touching filesystem:

```c
/* drivers/gpu/drm/drm_edid_load.c:180 */
builtin = match_string(generic_edid_name, GENERIC_EDIDS, name);
if (builtin >= 0) { fwdata = generic_edid[builtin]; ... }   /* no filesystem needed */
```

- v3.3 used `edid/1920x1080.bin`, which **is** in that table, so it loaded, as 128-byte
  blob with no CTA block, giving `OPMODE_DVI` and no sound.
- v4.0's `h96-1080p-audio.bin` is **not** in that table, so it needs file, and file
  is unreachable that early. Result is **no EDID at all**, which takes driver's
  permissive fallback (`support_hdmi = true`, `sink_has_audio = true`).

So audio works because there is **no** EDID, not because there is better one. Verified on
fresh v4.0 flash: `PHY: enabled  Mode: HDMI`, HDMI PCM present, 0 failed units.

**Consequence:** `drm.edid_firmware=` argument is currently no-op and could be dropped
with identical behaviour, minus two error lines in `dmesg`. It has deliberately **not** been
changed in v4.0: audio works today, and altering working boot path to tidy up log noise is
not worth risk. Noted here so next person does not "fix" it by shipping built-in
EDID name, which is precisely what broke audio in v3.3.

### 8. Widevine L3 setup, opt-in (browser DRM)

Google ships no Widevine CDM for generic ARM64 Linux, so browser DRM streams
(Discovery+, Netflix, Prime, Disney+) cannot play on this image by default.
`sudo h96-widevine-setup` fetches AsahiLinux `widevine-installer` (MIT), which
downloads Chrome (LaCrOS) image from Google (about 150 MB), extracts ARM64
L3 CDM, applies its glibc ELF fixups, and installs to `/var/lib/widevine`; tool
then wires Chromium (system-wide bundle dir, all users) and Firefox
(`MOZ_GMP_PATH`). CDM is proprietary and never bundled in this GPL-2.0 image;
it is fetched on request, same policy as `h96-npu-setup`. LIMIT: this box is
Widevine L3 on every firmware, Android included; DRM streams cap at SD
(~480p) and no firmware changes that. `status` and `remove` subcommands
included. Verified on hardware: Chromium registers bundled CDM 4.10.2662.3 system-wide, Discovery+ plays at SD. Check other services at https://bitmovin.com/demos/drm.

## v3.4 (released as pre-built image; EDID below IS reproducible here)

**⚠️ If you followed v3.3 instructions below, HDMI audio is disabled on your build.
Apply this instead.**

v3.3 told you to add `drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin` to stop HDMI EDID
retry storm. It does stop storm, and it also **disables HDMI audio without any log message**. Video is
unaffected, so it does not look like display problem at all.

**Why.** Every EDID blob compiled into kernel (`drivers/gpu/drm/drm_edid_load.c`,
`generic_edid[]`) is 128 bytes with **no CTA/CEA extension block**. HDMI audio capability is
declared in that block. With no CTA block, `drm_detect_hdmi_monitor()` returns false,
driver sets `sink_is_hdmi = false`, and `dw_hdmi_qp_setup()` then programs `OPMODE_DVI`,
which drops every data island: audio sample packets and infoframes alike.

Note consequence: **having no EDID at all is better than having one that declares no
audio.** With no EDID driver takes explicit fallback that sets `support_hdmi = true`
and `sink_has_audio = true`. V3.3 argument moved board out of that fallback.

Measured on hardware, same board and display, changing only this argument:

|                                     | kernel built-in `1920x1080.bin` | no argument                | `h96-1080p-audio.bin`   |
|-------------------------------------|---------------------------------|----------------------------|-------------------------|
| dmesg                               | `dw_hdmi_qp_setup DVI mode`     | tmds mode                  | tmds mode               |
| `/sys/kernel/debug/dw-hdmi0/status` | `PHY: disabled`                 | `PHY: enabled  Mode: HDMI` | `Mode: HDMI`            |
| ELD                                 | `SAD_Count=0`                   | zeros                      | `SAD_Count=1`, LPCM 2ch |
| HDMI audio                          | **none**                        | works                      | works                   |

**Fix.** This repo now ships 256-byte EDID that declares 1080p60 plus HDMI VSDB and
LPCM audio descriptor:

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
before it succeeds). Earlier version of this project tried exactly that and **box
would not boot**: this U-Boot and kernel will not boot uImage `uInitrd` with prepended
early cpio, and connector probe fails before root filesystem is mounted. Leave
`uInitrd` alone and accept startup cost.

**Why not drop argument.** Retry storm is not only startup cost. DRM
connector hotplug poll keeps retrying for as long as board is powered. Measured: with no
argument, 108 timeouts by 99 seconds and still climbing at roughly one per second; with this
EDID, 19 timeouts, and it stays at 19.

## v3.3 (superseded by v3.4: boot argument below disables HDMI audio, see above)

Efficiency pass on top of v3.2. Most of it is root filesystem configuration and so is
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
  internal DDC controller. This is boot argument, not device tree change.

  Setting resolution still works exactly as before. `video=HDMI-A-1:...` overrides
  forced EDID: verified by booting `video=HDMI-A-1:1280x720@60` alongside it, which set
  display controller clock to 74440000 and advertised 1280x720.

Remaining v3.3 changes are root filesystem only and are not reproducible from this
repo: CPU governor and frequency floor defaults, moving package retry service off
startup path, and desktop package selection. See pre-built image's own CHANGELOG.md.

## v3.2 (released as pre-built image; not yet reproducible from this repo)

Pass over faults that appear once desktop environment is installed and
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
- **WiFi works on fresh install.** Radio came up rfkill soft-blocked with nothing
  in image clearing it, so `wpa_supplicant` could never associate and dhcpcd refused
  to start. `systemd-rfkill` persists unblocked state across reboots, so only
  freshly flashed boxes were affected. WiFi unit now runs
  `rfkill unblock wifi` before starting.
- **WiFi** uses standalone `wpa_supplicant` with tray applet, because
  NetworkManager cannot complete this chip's multi-AKM association.
- **Hardware video** completes its first-boot setup headless, with no desktop
  installed.
- **Desktop installs keep tier** (`minimal` / `mid` / `full`) chosen in
  `armbian-config`, instead of upgrading every install to `kde-full`.
- **Mesa/Panthor userspace stack is pinned**, so `apt upgrade` cannot move it
  to version that breaks GPU acceleration.

**Scope.** All of above is userspace: systemd units, package selection and
first-boot scripts. None of it touches kernel, device tree or BSP package
published here, so building from these sources reproduces v3.1 feature set
(open GPU, WiFi 6, hardware video, front panel), not v3.2.

## v3.1
- **Working front-panel VFD.** Added `h96-vfd` daemon (`packages/bsp/.../src/h96-vfd.c`
  + `h96-vfd.service`): shows clock (HH:MM + blinking colon) and lights
  Ethernet / WiFi / USB / play status icons from live system state. Panel is
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
- **IR** as userspace-learnable `gpio-ir-receiver` overlay (see `patch/overlays/`).

Earlier revisions (v1/v2) were vendor-blob GPU builds and are superseded by v3.
