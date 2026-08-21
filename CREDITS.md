# Credits

This board support builds on the work of others.

- **Armbian**: the build framework and Debian/Ubuntu-based OS this port targets.
  <https://github.com/armbian/build>
- **The Linux kernel** and the **Rockchip** RK3588 BSP: the base device tree in
  this repo is derived from Rockchip's vendor sources.
- **Panthor** kernel DRM driver authors (Collabora / ARM): the open Mali "Valhall"
  driver that replaces the closed vendor blob.
- **Mesa**: **Panfrost** (OpenGL/GLES) and **PanVK** (Vulkan) on Mali-G610.
- **Rockchip MPP (`rockchip-mpp`)** and the **mpv** project: the hardware video
  decode path.
- **rc-core / `gpio-ir-receiver`** kernel maintainers: the IR receiver path used
  by the overlay.
- The **Armbian community forums**: RK3588 TV-box bring-up discussions that made
  this possible.

The front-panel driver (`h96-vfd.c`) was reverse-engineered from the stock Android
kernel's front-display driver (TM1650 protocol).

Development was done conversationally with **Claude Code**. Every device-tree edit,
script, and workaround was written and tested interactively. Treat everything here
as community work offered in good faith, with no warranty.
