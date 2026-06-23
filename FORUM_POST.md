# *[UNOFFICIAL] H96 Max V58 — Armbian Ubuntu 26.04 · RK3588 · Performance stack · 7 desktops · v_08.4*

> ***Device:*** *H96 Max V58 (Rockchip RK3588, 8GB RAM, 64GB eMMC)*
> ***Status:*** *Unofficial / community-built — not affiliated with the Armbian project*

---

## *What is this*

A ready-to-flash Armbian image for the H96 Max V58 Android TV box. Boots headless with SSH on first power-on. Installs a full performance/emulation stack and configures all 7 desktops during first boot — no manual steps required after flashing.

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
| Base OS | Armbian 26.x / Ubuntu 26.04 Resolute |
| Kernel | BSP 6.1.x-rk3588-ophub |

---

## *What's included*

**Boots headless by default** (`multi-user.target`, SSH on first boot)

| Feature | Notes |
|---|---|
| Mali G610 GPU blobs | EGL · GBM · GLES · Vulkan 1.3 (g13p0 + g24p0) |
| Hardware video decode | Rockchip MPP — H.264, H.265, VP9, AV1 up to 8K |
| HDMI resolutions | 480p → 576p → 720p → 1080p → 2K → 4K@60 via firmware EDID |
| x86_64 emulation | box64 |
| x86 32-bit emulation | box86 |
| Power profiles | Performance · Balanced · Power Saver — D-Bus daemon, desktop quick-settings |
| Desktop support | 7 desktops auto-configure on install via `armbian-config` |
| Monitoring tool | `h96-bench` — live CPU/GPU/thermal snapshot + stress |
| SSH | Open — `root` / `1234` |

**Wine not included** — install after flashing: `apt install wine wine64`

**Desktops (none installed by default — install via `armbian-config → System → Desktop`):**

| Desktop | Display manager | Notes |
|---|---|---|
| GNOME | GDM | Wayland |
| KDE Plasma | SDDM | Wayland |
| Cinnamon | LightDM | X11 + ShadowFB |
| XFCE | LightDM | X11 + ShadowFB |
| MATE | LightDM | X11 + ShadowFB |
| i3 | LightDM | X11 + ShadowFB |
| Enlightenment | LightDM | X11 + ShadowFB |

*Each desktop auto-configures (display manager, session files, groups) the moment the package lands — no manual steps.*

---

## *Known limitations*

- **WiFi** — BCM43455 chip is present but not supported. Ethernet only.
- **Bluetooth** — Not configured.
- **Desktop hardware compositing** — All desktops run software compositing (llvmpipe/ShadowFB). The BSP 6.1.x kernel uses proprietary Mali blobs — no Panfrost/Panthor. GNOME suppresses the warning; KDE shows a tray notice.
- **BIG core max frequency** — Vendor DTB caps Cortex-A76 at 2208 MHz. Physical max is 2.4 GHz but the OPP table doesn't include it.
- **8K HDMI output** — Not tested. 4K@60 is the confirmed maximum.
- **Night light / gamma** — BSP DRM driver does not expose `gamma_lut_size` on the CRTC. GNOME's night light toggle engages Mutter's software color pipeline — you'll see a slight brightness shift but the warm colour shift won't apply.
- **Browser video (YouTube etc.)** — Chromium ships with `--ignore-gpu-blocklist` baked in so WebGL initialises. VLC plays everything fine via Rockchip MPP directly.
- **Front panel LEDs / IR remote** — No driver in BSP kernel.
- **Chromium: use `apt install chromium`** — `apt install chromium-browser` on Ubuntu 26.04 installs a snap wrapper. Use `apt install chromium` (no `-browser`).

---

## *HDMI note — why a firmware EDID is used*

The BSP `dwhdmi-rockchip` driver collapses the DDC I²C bus at boot, so the kernel can never read a real EDID from the TV. Without an EDID the display is black.

Fix: `drm.edid_firmware=HDMI-A-1:edid/h96-hdmi-multi.bin` — the kernel serves a hand-crafted 256-byte EDID from the initramfs, bypassing all I²C reads entirely. The EDID covers all common resolutions from 480p to 4K@60 and declares RGB-only output (critical — if YCbCr flags are set, the BSP encoder switches colour space and the TV gets a black screen).

`video=HDMI-A-1:e` is also set to keep the DRM connector forced-on through the PHY re-probe that fires ~12s after boot.

---

## *Flashing*

**Requires:** Linux host, `rkdeveloptool`, USB-A to USB-A cable (male both ends).

```bash
# 1a. First-time flash — Maskrom mode:
#     Power off → hold Maskrom pinhole (underside) → plug USB-A into box USB2 port → release

# 1b. Reflash from Armbian — SSH in and run:
#     reboot loader

# 2. Verify:
rkdeveloptool ld
# Expected: DevNo=1  Vid=0x2207,Pid=0x350b  Maskrom  (or Loader)

# 3. Flash:
xz -d H96-MAX-V58_Unofficial-Armbian_v_08.4.img.xz
rkdeveloptool wl 0 H96-MAX-V58_Unofficial-Armbian_v_08.4.img
rkdeveloptool rd
```

*Takes ~3–5 minutes. First boot runs setup (~10–15 min). Box reboots once automatically.*

> ***Ethernet required on first boot*** — `xserver-xorg-core`, gamemode, vulkan-tools, and other Ubuntu packages download during first-boot setup (~150–250 MB). box64 and box86 are bundled in the image. After first boot the box runs fully standalone.

```bash
ssh root@h96max   # or ssh root@<ip>
# password: 1234
```

*Full flashing guide: [FLASHING.md](FLASHING.md)*

---

## *First-boot pipeline*

*Everything runs automatically — no console, no interaction needed. Ethernet required.*

1. Root filesystem expanded to full eMMC
2. SSH host keys regenerated (unique per device)
3. Branding written, immutable flag set
4. EDID firmware rebuilt into initramfs (`mkinitramfs + mkimage`)
5. box64 + box86 installed from bundled offline debs
6. Ubuntu packages installed from repos: gamemode, irqbalance, vulkan-tools, xserver-xorg-core, DXVK
7. Mali G610 GPU blobs linked, Vulkan ICD configured, Rockchip MPP installed
8. `--ignore-gpu-blocklist` baked into Chromium config
9. GNOME auto-configures on `gdm3` install: at-spi2-core, lpadmin group, GDM settings

*First boot takes ~10–15 minutes. Box reboots itself. SSH available within ~30 seconds of first power-on.*

---

## *Changelog*

| Version | Key change |
|---|---|
| ***v_08.4*** | at-spi2-core on GNOME setup (fixes polkit unlock dialogs + accessibility); lpadmin auto-assigned; `--ignore-gpu-blocklist` for Chromium; service units explicitly written |
| **v_08.3** | Wine removed from auto-install; performance stack branding |
| **v_08.2** | `xserver-xorg-core` apt-lock race fixed |
| **v_08.1** | EDID firmware into initramfs; gaming packages unpacked state fix |
| **v_08** | Boot parameters now actually apply — wrong partition in all prior versions |
| **v_07** | Branding race fix (`chattr +i`) |
| **v_06** | SSH available on first boot |
| **v_05** | Sparse-write-proof firstboot sentinel |
| **v_04** | Runtime branding write |
| **v_03** | HDMI 2.1 EDID; all 5 X11 desktops |
| **v_02** | HDMI firmware EDID; DDC I²C fix; all 7 desktops |
| **v_01** | *Alpha* |

---

## *Credits*

| Component | Credit |
|---|---|
| Base image | [Armbian for Rock 5B](https://www.armbian.com/rock-5b/) — Armbian Project |
| BSP kernel (6.1.x RK3588) | [ophub/kernel](https://github.com/ophub/kernel) |
| Desktop tooling | [armbian-config](https://github.com/armbian/configng) |
| x86_64 emulation | [box64](https://github.com/ptitSeb/box64) — ptitSeb |
| x86 32-bit emulation | [box86](https://github.com/ptitSeb/box86) — ptitSeb |
| Windows layer | [Wine](https://www.winehq.org) + [DXVK](https://github.com/doitsujin/dxvk) |
| Hardware decode | [Rockchip MPP](https://github.com/rockchip-linux/mpp) |
| Mali blobs | ARM Ltd. (g13p0 EGL/GBM/GLES, g24p0 Vulkan) |
| Build tooling | [Claude Code](https://claude.ai/code) — Anthropic |

---

*Unofficial build — use at your own risk. Tested on real hardware. Report issues in this thread.*
