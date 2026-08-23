# Device-tree changes for the H96 Max V58 (RK3588)

`patch/kernel/rk3588-h96-max-v58.dts` is the board device tree. It began as a
**decompile of the stock Android vendor DTB** (`dtc -I dtb -O dts`), which is why it carries the
`rockchip,rk3588-nvr-demo-v10-android` compatible and the numeric phandles. It
was then edited for an open-GPU Armbian build. It is included as-is because it is
the exact, working source; the changes below are what differ from the stock DTB.

If you prefer a mainline-style DTS, the same nodes can be applied on top of a
mainline `rk3588.dtsi`; the values here are the reference.

## 1. Open Mali GPU (Panthor)
- **`gpu-supply`** wired to the GPU power domain / regulator so the GPU rail is
  powered at bind (without it the first GL job hangs with a TF-A SError).
- GPU clocked from **`&cru CLK_GPU`**.
- **1000 MHz** operating point: NPLL set to 4 GHz (`0xee6b2800`) with an
  `opp-1000000000` entry added to the GPU OPP table.
- The node uses the **`arm,mali-valhall`/Panthor** binding (open driver), not the
  vendor `mali` blob binding.

## 2. Hardware cursor plane (no flicker)
- **`cursor-win-id = <0>`** on video-port `vp0` so the compositor gets a
  hardware cursor plane instead of a software cursor.

## 3. Onboard WiFi 6: PCIe, not SDIO
The onboard wireless is a **BCM43752 / AP6275P (802.11ax)** on **PCIe**, sharing
nothing with Ethernet (they run simultaneously):
- **`pcie2x1l0`** enabled: 3-region `reg`, `reset-gpio`, `vpcie` kept always-on,
  and a `gpio0`-line-20 hog to hold the enable line.
- The vestigial **`&sdio`** node (an `ap6255` SDIO template that this board does
  not use) is **disabled** so it can't grab pins.
- Pair with the vendor **`bcmdhd` PCIe** module + the stock PCIe firmware, or with
  mainline `brcmfmac` + the matching BCM43752 firmware/nvram.

## 4. Reduced boot output
- **`es8311@18`** codec node and the **`i2s0` sound** card disabled: the board
  has no analog audio out; leaving them enabled prints codec errors at boot.
- **`serial@febc0000`**: `dmas` dropped (the Bluetooth UART stays functional; the
  DMA channel reference produced noise).
- Kernel log level pinned low: `loglevel=3`, `printk = 3 4 1 7`.

## 5. IR receiver (overlay, not baked)
IR is shipped as a **separate overlay** (`patch/overlays/h96-max-v58-gpio-ir.dts`)
rather than in the base DTS, so remotes can be learned in userspace with
`ir-keytable` and no per-remote DTB rebuild. It switches the pin from the vendor
`remotectl`/PWM3 driver to the mainline `gpio-ir-receiver` on **GPIO0_D4**.

## 6. HDMI EDID: why this is NOT a device-tree change

Worth recording as a negative result, because it looks like a device-tree problem and is not.

The HDMI EDID read on this board never succeeds. `/sys/class/drm/card*-HDMI-A-1/edid` reads
back zero bytes and the kernel logs `i2c read time out!` 18 times on every boot before
giving up, costing about 1.8 seconds of a 7.99 second startup.

The obvious fix would be to point the HDMI node at the right i2c bus with a `ddc-i2c-bus`
property. **That property does not exist on this node.** `dw-hdmi-qp` uses an internal DDC
controller, which appears as its own bus (`i2c-9`, named `ddc`) with no child devices, so
there is nothing to re-point. The failure is below the device tree.

So the fix is a kernel boot argument instead, added to `extraargs` in
`/boot/armbianEnv.txt`:

```
drm.edid_firmware=HDMI-A-1:edid/1920x1080.bin
```

`edid/1920x1080.bin` is one of the EDID blobs compiled into the kernel
(`drivers/gpu/drm/drm_edid_load.c`), so nothing is loaded from disk and there is no root
filesystem or initramfs dependency. The kernel confirms which path it took by logging
`Got built-in EDID` rather than `external`. Retries drop from 18 to 1 and kernel startup
time drops from 4.26s to 2.58s.

Setting a different resolution still works: `video=HDMI-A-1:...` overrides the forced EDID.
Verified by booting `video=HDMI-A-1:1280x720@60` alongside it, which set the display
controller clock to 74440000 (720p) and advertised `1280x720`.

## Building the DTB
```
# base board DTB (from the .dts in patch/kernel/)
dtc -@ -I dts -O dtb -o rk3588-h96-max-v58.dtb rk3588-h96-max-v58.dts

# IR overlay (from patch/overlays/)
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo h96-max-v58-gpio-ir.dts
```
