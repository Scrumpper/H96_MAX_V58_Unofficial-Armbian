# H96 Max V58 Armbian board support (RK3588)

Board bring-up **sources** for running Armbian on the **H96 Max V58** TV box
(Rockchip **RK3588**, Mali-G610) with an **open GPU** stack: the Panthor kernel
driver + Mesa (Panfrost/PanVK), hardware video, onboard WiFi 6, and a working
front-panel display.

This repository exists so anyone can **inspect the source and build a matching
image themselves** with the official Armbian build framework, rather than
downloading a pre-built image. Everything here (device tree, overlays, the
front-panel driver, board config, BSP scripts) is provided as source under
GPL-2.0. See [`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md).

> **Unofficial.** Not affiliated with, endorsed by, or supported by Armbian,
> Rockchip, or the H96 manufacturer. It has been tested only on our own unit and
> comes with **no warranty**. Always keep a recovery plan before overwriting your device.

> **Scope: this repo covers hardware bring-up (kernel, device tree, front-panel
> daemon) up through v3.1.** It does not include the desktop-completeness and
> reliability fixes from v3.2 and later (except the v3.3 HDMI boot argument, which is
> documented in CHANGELOG.md and does apply here): WiFi connection tooling, Bluetooth
> audio quality, Discover/software-install authentication, the gaming stack, and
> related first-boot automation. Compiling from these sources today reproduces
> the v3/v3.1 feature set: open GPU, onboard WiFi 6, hardware video, and the
> front-panel display. For the current v3.3 feature set, use the pre-built
> release images until that userspace layer is published here as well.

---

## Hardware status

| Component | Status | Notes |
|---|:---:|---|
| CPU (8-core RK3588) | ✅ | |
| Mali-G610 GPU | ✅ | Open **Panthor** + Mesa (Panfrost GLES / PanVK Vulkan 1.4); GPU-composited desktop |
| Hardware video decode | ✅ | Rockchip MPP + mpv (VPU) |
| Ethernet | ✅ | |
| WiFi 6 (BCM43752 / AP6275P) | ✅ | **PCIe**, runs simultaneously with Ethernet |
| Bluetooth | ✅ | BCM UART |
| HDMI + audio | ✅ | |
| Front-panel VFD | ✅ | TM1650, clock + status icons (`h96-vfd`) |
| IR remote | ✅ | `gpio-ir-receiver` overlay, learn with `ir-keytable` |
| eMMC storage | ✅ | |

> **Note on Ethernet.** The onboard RTL8211F PHY may spend an extended time attempting
> Gigabit auto-negotiation before downshifting to 100Mbps, so the link can take minutes
> to become usable after boot while the system itself reaches multi-user in about 7
> seconds. The kernel logs `Downshift occurred from negotiated speed 1Gbps to actual
> speed 100Mbps, check cabling!`. Measured at 26 s, 128 s and 190 s across boots on one
> unit. Try a different cable or switch port first; `ethtool -s eth0 speed 100 duplex
> full autoneg off` skips Gigabit negotiation at the cost of capping the port.

---

## Repository layout

```
config/
  boards/h96-max-v58.tvb          Armbian board file (TV-box class)
  kernel-h96-max-v58.config       kernel .config fragment (Panthor, VPU, IR, PCIe)
patch/
  kernel/rk3588-h96-max-v58.dts   board device tree (the core hardware source)
  overlays/h96-max-v58-gpio-ir.dts  IR receiver overlay (gpio-ir-receiver)
packages/
  bsp/h96-max-v58/
    src/h96-vfd.c                 front-panel VFD daemon source (+ Makefile)
    systemd/h96-vfd.service       unit for the daemon
    environment.d-h96-gpu.conf    GLES/EGL env so the desktop composites on the GPU
    brcm4362a2_firmware/          BCM4362A2.hcd - vendor Bluetooth firmware blob
docs/
  DEVICE-TREE-CHANGES.md          every DT change vs the stock vendor DTB, explained
CHANGELOG.md  CREDITS.md  LICENSE
```

---

## Building an image with the Armbian framework

These sources plug into the standard [Armbian build system](https://github.com/armbian/build).
The device tree carries the hardware enablement; the rest is board config + BSP.

Following the steps below produces a v3.1-equivalent image: open GPU, onboard
WiFi 6, hardware video, and the front-panel display, all working. It does not
include most v3.2-and-later fixes, since apart from the v3.3 HDMI boot argument
(see CHANGELOG.md) none of those touch the kernel, device
tree, or BSP package this repo publishes.

```bash
# 1. Get the Armbian build framework
git clone --depth=1 https://github.com/armbian/build armbian-build
cd armbian-build

# 2. Add this board
cp  /path/to/this-repo/config/boards/h96-max-v58.tvb   config/boards/

# 3. Add the device tree to the RK3588 kernel dts dir (edge/mainline kernel).
#    Also add it to that dir's Makefile (dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-h96-max-v58.dtb).
#    The Armbian way to do this reproducibly is a userpatch that drops the .dts in:
mkdir -p userpatches
cp  /path/to/this-repo/patch/kernel/rk3588-h96-max-v58.dts   userpatches/

# 4. (optional) merge the kernel config fragment for Panthor/VPU/IR/PCIe
cat /path/to/this-repo/config/kernel-h96-max-v58.config >> userpatches/linux-rockchip-rk3588-edge.config  # or use KERNELCONFIG

# 5. Build (desktop image, edge kernel)
./compile.sh  BOARD=h96-max-v58  BRANCH=edge  RELEASE=noble \
              BUILD_DESKTOP=yes  BUILD_MINIMAL=no  KERNEL_CONFIGURE=no
```

The output image lands in `output/images/`. Flash it (see **Flashing** below).

> **Note on the device tree.** `patch/kernel/rk3588-h96-max-v58.dts` is a
> **decompile of the stock Android vendor DTB** that was then edited for an
> open-GPU Armbian (hence the `rockchip,rk3588-nvr-demo-v10-android` compatible and
> numeric phandles). It is included exactly as it is used, and is the source the
> released images are built from. `docs/DEVICE-TREE-CHANGES.md` documents every change so it can be re-applied
> onto a mainline `rk3588.dtsi` if you prefer a from-scratch DTS.

---

## Device-tree changes

Full detail in [`docs/DEVICE-TREE-CHANGES.md`](docs/DEVICE-TREE-CHANGES.md). In short:

- **Open GPU:** `gpu-supply` + `&cru CLK_GPU` + a 1000 MHz OPP; Panthor binding.
- **HW cursor plane:** `cursor-win-id = <0>` on `vp0`.
- **WiFi 6 on PCIe:** enable `pcie2x1l0`, disable the vestigial `&sdio` template.
- **Reduced boot output:** disable unused `es8311`/`i2s0`, drop the serial `dmas`
  that emitted repeated errors.

Build the DTBs standalone if you just want those:

```bash
dtc -@ -I dts -O dtb -o rk3588-h96-max-v58.dtb   patch/kernel/rk3588-h96-max-v58.dts
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo patch/overlays/h96-max-v58-gpio-ir.dts
```

---

## Front-panel VFD (`h96-vfd`)

The front panel is a **TM1650** bit-banged over GPIO3. The daemon shows the clock
and lights the Ethernet / WiFi / USB / play icons from live state.

```bash
cd packages/bsp/h96-max-v58/src
make                              # native (on the board), or:  make CROSS=aarch64-linux-gnu-
sudo install -m0755 h96-vfd /usr/local/sbin/h96-vfd
sudo install -m0644 ../systemd/h96-vfd.service /etc/systemd/system/
sudo systemctl enable --now h96-vfd
```

## IR remote

```bash
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo patch/overlays/h96-max-v58-gpio-ir.dts
sudo cp h96-max-v58-gpio-ir.dtbo /boot/overlay-user/
# add to /boot/armbianEnv.txt:   user_overlays=h96-max-v58-gpio-ir
sudo reboot
# then learn your remote:
ir-keytable            # shows the gpio_ir_recv device
ir-keytable -p nec -t  # press buttons -> scancodes
```

## Open-GPU desktop

For KDE/GNOME to composite on the GPU (not fall back to software `llvmpipe`),
append `packages/bsp/h96-max-v58/environment.d-h96-gpu.conf` to `/etc/environment`.
Do **not** install the `libmali` blob packages: they shadow Mesa's EGL/Vulkan.

---

## Flashing

The RK3588 flashes over USB with **`rkdeveloptool`** in Maskrom mode (hold the
recessed reset pin while connecting USB), or with Rockchip's RKDevTool GUI on
Windows. Write the Armbian image (`.img`) to the eMMC. This is standard RK3588
procedure and is not specific to this repo.

---

## License & credits

GPL-2.0-only. See [`LICENSE`](LICENSE) and [`CREDITS.md`](CREDITS.md). Built on
Armbian, the Linux kernel, Rockchip's BSP, Panthor, and Mesa.
