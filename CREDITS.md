# Credits

This board support builds on work of others.

- **Armbian**: build framework and Debian/Ubuntu-based OS this port targets.
  <https://github.com/armbian/build>
- **Linux kernel** and **Rockchip** RK3588 BSP: base device tree in
  this repo is derived from Rockchip's vendor sources.
- **Panthor** kernel DRM driver authors (Collabora / ARM): open Mali "Valhall"
  driver that replaces closed vendor blob.
- **Mesa**: **Panfrost** (OpenGL/GLES) and **PanVK** (Vulkan) on Mali-G610.
- **Rockchip MPP (`rockchip-mpp`)** and **mpv** project: hardware video
  decode path.
- **rc-core / `gpio-ir-receiver`** kernel maintainers: IR receiver path used
  by overlay.
- **Rockchip MPP** `RKVENC`/`RKVENC2`/`JPGENC`: hardware video *encode* path
  exposed by `h96-encode`.
- **bjin/mpv-prescalers**: `ravu-lite-ar-r4` shader used by `h96-upscale`, by
  Bin Jin. Shipped unmodified under **GNU LGPL v3**, licence header intact.
  <https://github.com/bjin/mpv-prescalers>
- **Rockchip RKNPU / RKNN**: NPU driver and `librknnrt` inference runtime.
  Runtime is proprietary and is therefore **not** distributed with this image --
  `h96-npu-setup` fetches it from Rockchip, showing their licence first.
- **Waydroid**: LXC-based Android-in-a-container runtime driven by `h96-waydroid`.
  Not bundled; installed on demand from upstream. <https://waydro.id>
- **LineageOS**: Android system images Waydroid runs, both the official
  Waydroid LineageOS 20 (Android 13) build and the Panthor-in-image Android 11
  build used by `h96-waydroid init gpu`. <https://lineageos.org>
- **Weston** (freedesktop.org reference Wayland compositor): nested compositor
  `h96-waydroid start` runs inside X11 so Waydroid has a Wayland output.
- **RetroArch / libretro**, **Dolphin**, **PPSSPP**, **Flycast**, **melonDS**,
  **Rosalie's Mupen GUI**, **Azahar** and **Cemu**: emulator projects installed by
  `h96-emulators`. All fetched from upstream on demand; no emulator and no game
  code is bundled. Bring your own dumps and BIOS.
- **box64** by ptitSeb: x86-64 to ARM64 translation layer that runs Cemu, which
  has no ARM build. <https://github.com/ptitSeb/box64>
- **Flathub** and **Flatpak**: distribution path for the seven native ARM64
  emulator builds. <https://flathub.org>
- **mGBA** and **ScummVM**: named in `h96-emulators` as the CPU-rendered systems
  it deliberately does not install, since both are already packaged for this box.
- **Armbian community forums**: RK3588 TV-box bring-up discussions that made
  this possible.

Front-panel driver (`h96-vfd.c`) was reverse-engineered from stock Android
kernel's front-display driver (TM1650 protocol).

Development was done conversationally with **Claude Code**. Every device-tree edit,
script, and workaround was written and tested interactively. Treat everything here
as community work offered in good faith, with no warranty.
