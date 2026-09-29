# Device-tree changes for H96 Max V58 (RK3588)

`patch/kernel/rk3588-h96-max-v58-panthor.dts` is board device tree. It began as
**decompile of stock Android vendor DTB** (`dtc -I dtb -O dts`), which is why it carries
`rockchip,rk3588-nvr-demo-v10-android` compatible and numeric phandles. It
was then edited for open-GPU Armbian build. File in this repo is decompile of
`rk3588-h96-max-v58-panthor.dtb`, DTB v6.0 image boots (`fdtfile=` in
`/boot/armbianEnv.txt`); it recompiles to same tree. Changes below are what
differ from stock DTB.

If you prefer mainline-style DTS, same nodes can be applied on top of
mainline `rk3588.dtsi`; values here are reference.

## 1. Open Mali GPU (Panthor)
- **`gpu-supply`** wired to GPU power domain / regulator so GPU rail is
  powered at bind (without it first GL job hangs with TF-A SError).
- GPU clocked from **`&cru CLK_GPU`**.
- **1000 MHz** operating point: NPLL set to 4 GHz (`0xee6b2800`) with
  `opp-1000000000` entry added to GPU OPP table.
- Node uses **`arm,mali-valhall`/Panthor** binding (open driver), not
  vendor `mali` blob binding.

## 2. Hardware cursor plane (no flicker)
- **`cursor-win-id = <0>`** on video-port `vp0` so compositor gets
  hardware cursor plane instead of software cursor.

## 3. Onboard WiFi 6: PCIe, not SDIO
Onboard wireless is **BCM43752 / AP6275P (802.11ax)** on **PCIe**, sharing
nothing with Ethernet (they run simultaneously):
- **`pcie2x1l0`** enabled: 3-region `reg`, `reset-gpio`, `vpcie` kept always-on,
  and `gpio0`-line-20 hog to hold enable line.
- Vestigial **`&sdio`** node (`ap6255` SDIO template that this board does
  not use) is **disabled** so it can't grab pins.
- Pair with vendor **`bcmdhd` PCIe** module + stock PCIe firmware, or with
  mainline `brcmfmac` + matching BCM43752 firmware/nvram.

## 4. Reduced boot output
- **`es8311@18`** codec node and **`i2s0` sound** card disabled: board
  has no analog audio out; leaving them enabled prints codec errors at boot.
- **`serial@febc0000`**: `dmas` dropped (Bluetooth UART stays functional;
  DMA channel reference produced noise).
- Kernel log level pinned low: `loglevel=3`, `printk = 3 4 1 7`.

## 5. IR receiver (overlay, not baked)
IR is shipped as **separate overlay** (`patch/overlays/h96-max-v58-gpio-ir.dts`)
rather than in base DTS, so remotes can be learned in userspace with
`ir-keytable` and no per-remote DTB rebuild. It switches pin from vendor
`remotectl`/PWM3 driver to mainline `gpio-ir-receiver` on **GPIO0_D4**.

## 6. HDMI EDID: why this is NOT device-tree change

Worth recording as negative result, because it looks like device-tree problem and is not.

HDMI EDID read on this board never succeeds. `/sys/class/drm/card*-HDMI-A-1/edid` reads
back zero bytes and kernel logs `i2c read time out!` 18 times on every boot before
giving up, costing about 1.8 seconds of 7.99 second startup.

Obvious fix would be to point HDMI node at right i2c bus with `ddc-i2c-bus`
property. **That property does not exist on this node.** `dw-hdmi-qp` uses internal DDC
controller, which appears as its own bus (`i2c-9`, named `ddc`) with no child devices, so
there is nothing to re-point. Failure is below device tree.

So fix is kernel boot argument instead, added to `extraargs` in
`/boot/armbianEnv.txt`:

```
drm.edid_firmware=HDMI-A-1:edid/h96-1080p-audio.bin
```

**Use 256-byte EDID shipped in this repo at
`packages/bsp/h96-max-v58/edid/h96-1080p-audio.bin`, not one of kernel's
built-in blobs.** All of those are 128 bytes with no CTA/CEA extension block, and
sink presenting no CTA block is treated as DVI, which disables HDMI audio entirely
while leaving video working. See CHANGELOG.md under v3.4.

`edid/1920x1080.bin` is one of EDID blobs compiled into kernel
(`drivers/gpu/drm/drm_edid_load.c`), so nothing is loaded from disk and there is no root
filesystem or initramfs dependency. Kernel confirms which path it took by logging
`Got built-in EDID` rather than `external`. Retries drop from 18 to 1 and kernel startup
time drops from 4.26s to 2.58s.

Setting different resolution still works: `video=HDMI-A-1:...` overrides forced EDID.
Verified by booting `video=HDMI-A-1:1280x720@60` alongside it, which set display
controller clock to 74440000 (720p) and advertised `1280x720`.

## 7. DDC pins reassigned by overlay: two pinctrl warnings at boot

`packages/bsp/h96-max-v58/overlays/h96-ddc-i2c-gpio.dts` exposes two HDMI DDC pins as
kernel `i2c-gpio` bus (`i2c-ddc`, 100 kHz) so `h96-brightness` can drive DDC/CI. HDMI
node already holds those pins, so overlay pinctrl group is refused at boot; overlay
carries no pinctrl group and i2c-gpio driver's gpiod request re-muxes pins itself.
Pinctrl driver logs that re-mux as two `WARNING` traces from `pinctrl-rockchip.c`
(`rockchip_pmx_gpio_set_direction`, `pin 143 already requested by fde80000.hdmi` and
`pin 144 already requested by fde80000.hdmi`). They are harmless; kernel sets its `W`
taint flag and bus works.

## 8. Watchdog enabled (v6.1)
- **`watchdog@feaf0000`** (RK3588 DesignWare watchdog, compatible `snps,dw-wdt`) changes
  from **`status = "disabled"`** to **`status = "okay"`**, so `/dev/watchdog0` exists. systemd
  opens it and pets it for hang-recovery feature described in CHANGELOG.md under v6.1.

## 9. HDMI CEC, HDMI I2S path and DDC bus in device tree (v6.2)
- **`hdmi@fde80000`** gains **`cec-enable`**: HDMI0 CEC adapter registers, `/dev/cec0` exists.
- **`i2s@fddf0000`** gains **`rockchip,hdmi-path`**: I2S driver sends one zero frame before DMA
  start on HDMI audio path.
- New node **`/i2c-ddc`** (`compatible = "i2c-gpio"`, SDA GPIO4 pin 16, SCL GPIO4 pin 15,
  `i2c-gpio,delay-us = <5>`), alias **`i2c10`** so bus number stays 10. HDMI node gets
  **`ddc-i2c-bus`** pointing at it, and its **`pinctrl-0`** drops two DDC pin groups so gpiod owns
  those pins. On-chip DDC controller never completes transfer on this board; with this node
  kernel reads EDID and drives HDMI 2.0 SCDC over GPIO bus. Overlay in section 7 is no longer
  loaded on v6.2 (kept for stock-DTB fallback), so its two pinctrl warnings are gone.

## Building DTB
```
# base board DTB (from .dts in patch/kernel/)
dtc -@ -I dts -O dtb -o rk3588-h96-max-v58-panthor.dtb rk3588-h96-max-v58-panthor.dts

# IR overlay (from patch/overlays/)
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo h96-max-v58-gpio-ir.dts
```
