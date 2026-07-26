# Device-tree changes — H96 Max V58 (RK3588)

`patch/kernel/rk3588-h96-max-v58.dts` is the board device tree. It began as a
**decompile of the stock Android vendor DTB** (`dtc -I dtb -O dts`) — hence the
`rockchip,rk3588-nvr-demo-v10-android` compatible and the numeric phandles — and
was then edited for a clean, open-GPU Armbian. It is included as-is because it is
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
- **`cursor-win-id = <0>`** on video-port `vp0` so the compositor gets a real
  hardware cursor plane instead of a flickering software cursor.

## 3. Onboard WiFi 6 — PCIe, not SDIO
The onboard wireless is a **BCM43752 / AP6275P (802.11ax)** on **PCIe**, sharing
nothing with Ethernet (they run simultaneously):
- **`pcie2x1l0`** enabled — 3-region `reg`, `reset-gpio`, `vpcie` kept always-on,
  and a `gpio0`-line-20 hog to hold the enable line.
- The vestigial **`&sdio`** node (an `ap6255` SDIO template that this board does
  not use) is **disabled** so it can't grab pins.
- Pair with the vendor **`bcmdhd` PCIe** module + the stock PCIe firmware, or with
  mainline `brcmfmac` + the matching BCM43752 firmware/nvram.

## 4. Quiet / tidy boot
- **`es8311@18`** codec node and the **`i2s0` sound** card disabled — the board
  has no analog audio out; leaving them enabled prints codec errors at boot.
- **`serial@febc0000`**: `dmas` dropped (the Bluetooth UART stays functional; the
  DMA channel reference produced noise).
- Kernel log level pinned low: `loglevel=3`, `printk = 3 4 1 7`.

## 5. IR receiver (overlay, not baked)
IR is shipped as a **separate overlay** (`patch/overlays/h96-max-v58-gpio-ir.dts`)
rather than in the base DTS, so remotes can be learned in userspace with
`ir-keytable` and no per-remote DTB rebuild. It switches the pin from the vendor
`remotectl`/PWM3 driver to the mainline `gpio-ir-receiver` on **GPIO0_D4**.

## Building the DTB
```
# base board DTB (from the .dts in patch/kernel/)
dtc -@ -I dts -O dtb -o rk3588-h96-max-v58.dtb rk3588-h96-max-v58.dts

# IR overlay (from patch/overlays/)
dtc -@ -I dts -O dtb -o h96-max-v58-gpio-ir.dtbo h96-max-v58-gpio-ir.dts
```
