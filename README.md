```
██╗  ██╗ █████╗  ██████╗    ███╗   ███╗ █████╗ ██╗  ██╗    ██╗   ██╗███████╗ █████╗
██║  ██║██╔══██╗██╔═════╝    ████╗ ████║██╔══██╗╚██╗██╔╝    ██║   ██║██╔════╝██╔══██╗
███████║╚██████║███████╗     ██╔████╔██║███████║ ╚███╔╝     ██║   ██║███████╗╚█████╔╝
██╔══██║ ╚═══██║██╔═══██╗    ██║╚██╔╝██║██╔══██║ ██╔██╗     ╚██╗ ██╔╝╚════██║██╔══██╗
██║  ██║ █████╔╝╚██████╔╝    ██║ ╚═╝ ██║██║  ██║██╔╝ ██╗     ╚████╔╝ ███████║╚█████╔╝
╚═╝  ╚═╝ ╚════╝  ╚═════╝     ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝      ╚═══╝  ╚══════╝ ╚════╝

     U N O F F I C I A L   A R M B I A N   ·   v3   ·   OPEN GPU  +  WiFi 6
     ────────────────────────────────────────────────────────────────────────
      Rockchip RK3588  ·  Mali-G610  ·  open Panthor + Mesa  ·  PCIe WiFi 6
```

<div align="center">

`RK3588` · `Mali-G610` · `Panthor DRM` · `Mesa 26.1.4` · `PanVK Vulkan 1.4` · `WiFi 6 + Ethernet` · `~5s boot`

</div>

## **WIFI WORKS**


## ⚡ Before → After

| | Old vendor-blob builds | **v3 — open Panthor** |
|---|---|---|
| **Desktop compositing** | ❌ llvmpipe (software), CPU-bound | ✅ **Mali-G610 Panfrost — real GPU** |
| **Cursor** | flickery software cursor | ✅ **hardware cursor plane** |
| **Night light** | ❌ unavailable | ✅ **works** (needs compositing) |
| **Vulkan** | closed blob, DXVK hard-fails | ✅ **PanVK, open, Vulkan 1.4** |
| **GPU clock** | 800 MHz | ✅ **1000 MHz** (+22%, thermally safe) |
| **Boot** | 12–22 s, dirty `--failed` | ✅ **~5 s, `--failed` empty** |
| **Boot log** | ~370 noise lines | ✅ **phantom-codec spam silenced** |

---

## 🎬 Hardware video — YouTube at ~1.5% CPU


- **YouTube & in-browser video are hardware-decoded** through the RK3588 VPU — **not** the browser's CPU decoder. It "works""... with a pre-installed chromium extension/player stream:  https://github.com/woodruffw/ff2mpv
- Hit **"play in mpv"** (the **ff2mpv** button) in chromium add-ons:
  **mpv** with **Rockchip MPP** hardware decode: **H.264 / HEVC / VP9**, up to 1080p, at **~1.5% CPU**.


```
┌────────────────────────────────────────────────────────────┐
│  browser video (software decode) ........ ~20%+ CPU, hot    │
│  ▶ "play in mpv"  (rkmpp / RK3588 VPU) ... ~1.5% CPU, cool  │
└────────────────────────────────────────────────────────────┘
```

---

## 🖥️ Open-GPU composited desktop

- **KDE Plasma & GNOME composite on the GPU** — renderer reports **`Mali-G610 MC4 (Panfrost)`**, OpenGL ES, Mesa **26.1.4**. No more `llvmpipe` software fallback.
- **Hardware cursor plane** — smooth pointer, flicker gone.
- **Night light / blue-light filter works** (it depends on compositing — now that the GPU composites, it lights up).
- Fully **open source**: Panthor DRM kernel driver + Mesa Panfrost userspace. No closed Mali blob shadowing the loader.

---

## 🎮 GPU gaming — open Vulkan, no blob

- **PanVK** — the **open-source Vulkan** driver on Mali-G610, **Vulkan 1.4** (Mesa 26.1.4). `vulkaninfo` enumerates `Mali-G610 (panvk)`.
- **`h96-game-mode`** launcher: **box64 + wine (wow64) + stripped-DXVK** in a nested compositor — the community-standard RK3588 gaming pattern. Desktop stays on Panfrost/X11; the game gets PanVK per-process.
- **GPU runs at 1000 MHz** under load (validated ~57 °C peak).
- **Steam** ships as an **opt-in, experimental** one-command installer (`h96-install-steam`, box86/box64 recipe) — nothing Steam-related is pre-baked.

> 🔎 Steam **snap** can't see this GPU (pressure-vessel breaks the driver mmap) — Canonical-layer limitation, not the image. Get steam with: `h96-game-mode` (native arm64 PanVK).


---

## 🛜 Onboard WiFi — WiFi 6, and Ethernet at the same time

- The radio is a **Broadcom BCM43752 / AP6275P — 802.11ax "WiFi 6", dual-band — on PCIe** 
```
Internets: lspci → Broadcom BCM43752 802.11ax [14e4:449d]   ·   wlan0 up   ·   eth0 up   ·  
```

---

## 💾 Flash it

```bash
# grab the compressed image (~1.4 GB), decompress, then flash over USB-USB CABLE
xz -dk H96-MAX-V58_Unofficial-Armbian_v3.img.xz
rkdeveloptool wl 0 H96-MAX-V58_Unofficial-Armbian_v3.img
```


