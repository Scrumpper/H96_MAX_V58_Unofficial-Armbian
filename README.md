# *H96 Max V58 — Unofficial Armbian 

> ***Device:*** *H96 Max V58 (Rockchip RK3588, 8 GB RAM, 64 GB eMMC)*
> ***Base OS:*** *Armbian 26.x / Ubuntu 26.04 Resolute*
> ***Status:*** *Unofficial / community-built — not affiliated with the Armbian project*

---

## *What is this*

A ready-to-flash Armbian image for the H96 Max V58 Android TV box. Boots headless with SSH on first power-on. Installs a full performance/emulation stack and auto-configures all 7 supported desktops during first boot — no manual steps required after flashing.

Built on top of the official **Armbian Rock 5B image** (same RK3588 SoC family, same BSP kernel). All H96 Max V58 hardware-specific customisation is applied by the build scripts on top.

---

## *Hardware*

| | |
|---|---|
| SoC | Rockchip RK3588 |
| CPU | 4× Cortex-A76 @ 2208 MHz + 4× Cortex-A55 @ 1800 MHz |
| GPU | ARM Mali-G610 MP4 (Valhall) — Vulkan 1.3, OpenGL ES 3.2 |
| RAM | 8 GB LPDDR4X |
| Storage | 64 GB eMMC |
| HDMI | HDMI 2.1 (DW-HDMI-QP) — 4K@60 confirmed |
| Network | Gigabit Ethernet |
| Kernel | BSP 6.1.x-rk3588-ophub |

---

## *What's included*

**Boots headless by default** — `multi-user.target`, SSH open on first power-on

| Feature | Detail |
|---|---|
| Mali G610 GPU blobs | EGL · GBM · GLES · Vulkan 1.3 (g13p0 + g24p0) |
| Hardware video decode | Rockchip MPP — H.264, H.265, VP9, AV1 up to 8K |
| HDMI resolutions | 480p → 576p → 720p → 1080p → 2K → 4K@60 via firmware EDID |
| x86_64 emulation | box64 (bundled offline) |
| x86 32-bit emulation | box86 (bundled offline) |
| Power profiles | Performance · Balanced · Power Saver — D-Bus daemon, GNOME/KDE quick-settings |
| Desktop support | 7 desktops auto-configure on install via `armbian-config` |
| Audio | PipeWire + PulseAudio bridge (pipewire-pulse) — HDMI audio out |
| Monitoring | `h96-bench` — live CPU/GPU/thermal snapshot + stress test |
| SSH | `root` / `1234` |

**Wine not included** — install after first boot: `apt install wine wine64`

---

## *Desktops*

*None installed by default. Install via `armbian-config → System → Desktop`.*

| Desktop | Display manager | Session | Video playback |
|---|---|---|---|
| GNOME | GDM | Wayland | Good |
| KDE Plasma | SDDM | Wayland | Jerky — KWin software compositor is CPU-heavy |
| Cinnamon | LightDM | X11 + ShadowFB | **Best** |
| XFCE | LightDM | X11 + ShadowFB | **Best** |
| MATE | LightDM | X11 + ShadowFB | **Best** |
| i3 | LightDM | X11 + ShadowFB | **Best** |
| Enlightenment | LightDM | X11 + ShadowFB | **Best** |

*X11 desktops use ShadowFB — the lightest compositing path on this BSP kernel. YouTube and video play smoothly. KDE's KWin compositor runs entirely in software (llvmpipe) and is noticeably heavier.*

*Each desktop auto-configures (display manager, session files, groups, accessibility, lpadmin) the moment its package lands — no manual steps.*

---

## *First-boot pipeline*

> ***Ethernet required*** — Ubuntu packages download during first-boot setup (~150–250 MB). box64 and box86 are bundled in the image and install offline. After first boot the box runs fully standalone.

Everything runs automatically — no console, no interaction needed:

1. Root filesystem expanded to full eMMC
2. SSH host keys regenerated (unique per device)
3. H96 branding written, immutable flag set
4. EDID firmware rebuilt into initramfs
5. box64 + box86 installed from bundled offline debs
6. Ubuntu packages from repos: gamemode, irqbalance, vulkan-tools, xserver-xorg-core, slick-greeter, pipewire-pulse, pavucontrol, DXVK
7. Mali G610 GPU blobs linked, Vulkan ICD configured, Rockchip MPP installed
8. `--ignore-gpu-blocklist` baked into Chromium config
9. *On GNOME install:* at-spi2-core, lpadmin group, GDM settings auto-applied

*First boot takes ~10–15 minutes. Box reboots itself. SSH available within ~30 seconds of first power-on.*

---

## *Flashing*

**Requires:** Linux host · `rkdeveloptool` · USB-A to USB-A cable (male both ends)

```bash
# First-time: put box in Maskrom mode
# Power off → hold Maskrom pinhole (underside) → plug USB-A into box USB2 port → release

# Reflashing from Armbian — SSH in and run:
# reboot loader

# Verify device is detected:
rkdeveloptool ld
# Expected: DevNo=1  Vid=0x2207,Pid=0x350b  Maskrom  (or Loader)

# Decompress and flash:
xz -d H96-MAX-V58_Unofficial-Armbian_v001.img.xz
rkdeveloptool wl 0 H96-MAX-V58_Unofficial-Armbian_v001.img
rkdeveloptool rd
```

> ⚠️ **DO NOT unplug the box during first boot.** First boot runs apt installs — pulling power mid-install can corrupt the package state. Wait for the **automatic reboot** (the box reboots itself when done, ~10–15 min). That reboot is your signal that first boot is complete and it is safe to power cycle.
>
> ***After the automatic reboot:*** *if HDMI has no signal, hard power cycle (unplug/replug). The BSP HDMI PHY requires a cold start to re-sync with the TV after a soft reboot.*

*See [FLASHING.md](FLASHING.md) for full step-by-step guide including Maskrom mode, troubleshooting, and SHA256 verification.*

---

## *HDMI — why a firmware EDID is used*

The BSP `dwhdmi-rockchip` driver collapses the DDC I²C bus at boot — the kernel can never read a real EDID from the TV. Without an EDID the display is black.

Fix: `drm.edid_firmware=HDMI-A-1:edid/h96-hdmi-multi.bin` in armbianEnv.txt. The kernel serves a hand-crafted 256-byte EDID from the initramfs, bypassing all I²C reads. The EDID covers 480p → 4K@60 and declares RGB-only output — YCbCr flags cause the BSP encoder to switch colour space, which produces a black screen on most TVs.

---

## *Known limitations*

| | |
|---|---|
| **WiFi** | BCM43455 chip present, not supported. Ethernet only. |
| **Bluetooth** | Not configured. |
| **Desktop compositing** | Software only. BSP Mali blobs — no Panfrost/Panthor. GNOME (Mutter/Cairo) and KDE (KWin) run llvmpipe; X11 desktops use ShadowFB. |
| **KDE / KWin performance** | KWin's software compositor is CPU-heavy without GPU acceleration — video playback and window animations are noticeably slower than on X11 desktops. Use Cinnamon, XFCE, or MATE for smoother video. |
| **CPU max clock** | DTB caps Cortex-A76 at 2208 MHz. Physical max 2.4 GHz unavailable. |
| **Night light** | BSP DRM doesn't expose `gamma_lut_size`. Toggle shows a brightness shift but no warm colour shift. |
| **HDMI after soft reboot** | BSP HDMI PHY doesn't drop the HPD line on `reboot` — TV may not re-sync. Hard power cycle (unplug/replug) always works. |
| **Browser video** | `--ignore-gpu-blocklist` baked in — WebGL initialises. VLC plays everything via Rockchip MPP. |
| **Front panel / IR** | No driver in BSP kernel. |

---

## *Credits*

| Component | Credit |
|---|---|
| Base image | [Armbian for Rock 5B](https://www.armbian.com/rock-5b/) — Armbian Project |
| BSP kernel | [ophub/kernel](https://github.com/ophub/kernel) |
| Desktop tooling | [armbian-config](https://github.com/armbian/configng) |
| x86_64 emulation | [box64](https://github.com/ptitSeb/box64) — ptitSeb · debs by [ryanfortner](https://github.com/ryanfortner/box64-debs) |
| x86 32-bit emulation | [box86](https://github.com/ptitSeb/box86) — ptitSeb · debs by [ryanfortner](https://github.com/ryanfortner/box86-debs) |
| LightDM greeter | [slick-greeter](https://github.com/linuxmint/slick-greeter) — Linux Mint team |
| Windows layer | [Wine](https://www.winehq.org) + [DXVK](https://github.com/doitsujin/dxvk) |
| Hardware decode | [Rockchip MPP](https://github.com/rockchip-linux/mpp) |
| Mali blobs | ARM Ltd. (g13p0 EGL/GBM/GLES, g24p0 Vulkan) |
| Build tooling | [Claude Code](https://claude.ai/code) — Anthropic |

---

*Unofficial build — use at your own risk. Tested on real hardware.*
