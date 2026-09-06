# Forced EDID for H96 Max V58 HDMI output

`h96-1080p-audio.bin` is a 256-byte EDID: a base block declaring 1920x1080p60, plus a
CTA-861 extension block carrying an HDMI VSDB and an LPCM audio descriptor.

## Why this file exists

This board does not route HDMI DDC lines through to display controller, so
kernel can never read connected display's device EDID. `/sys/class/drm/card*-HDMI-A-1/edid`
returns 0 bytes and driver logs `i2c read time out` repeatedly. That is not only a
startup cost: connector hotplug poll keeps retrying for as long as board is powered,
roughly once per second.

Supplying a substitute EDID stops that. **But substitute must contain a CTA/CEA
extension block.** Every EDID compiled into kernel
(`drivers/gpu/drm/drm_edid_load.c`, `generic_edid[]`) is 128 bytes with no extension block.
Using one of those makes `drm_detect_hdmi_monitor()` return false, so driver sets
`sink_is_hdmi = false` and `dw_hdmi_qp_setup()` programs `OPMODE_DVI`, which drops every
data island: audio sample packets and infoframes alike. **Video keeps working, so it does
not look like a display problem, but HDMI audio is gone.**

Note that having no EDID at all is better than having one that declares no audio: with no
EDID driver takes an explicit fallback that sets `support_hdmi = true` and
`sink_has_audio = true`.

## Installing

Copy to `/lib/firmware/edid/h96-1080p-audio.bin`, mode 0644, then add to `extraargs` in
`/boot/armbianEnv.txt`, keeping existing `video=` argument:

```
drm.edid_firmware=HDMI-A-1:edid/h96-1080p-audio.bin
```

## Do not put this in initramfs

Loading it earlier would also recover about 1.85 seconds of startup, because from root
filesystem it only loads on post-rootfs connector reprobe (you will see two
`Direct firmware load ... error -2` lines first). **An earlier version of this project tried
that and box would not boot:** this U-Boot and kernel will not boot a uImage `uInitrd`
with a prepended early cpio, and connector probe fails before root filesystem is
mounted. Leave `uInitrd` untouched.

## Verifying

```
md5sum    0b1a07cc7bc1963537ba07eeef4717c8
sha256sum 11fc27cafc6b622329d326978f15f5edce8aa5cc9444edb2ee493e6386c59102
```

Decode it with `edid-decode < h96-1080p-audio.bin`. Expect: 256 bytes, 1 extension block,
both checksums valid, a CTA-861 revision 3 block containing an HDMI VSDB (IEEE OUI
00-0C-03) and an Audio Data Block declaring LPCM 2 channel at 32 / 44.1 / 48 kHz.

## Why 1080p only

A richer EDID advertising 4K modes was built and rejected. Attached display can never be
probed on this board, so anything advertised is a guess. Advertising 4K60 to a desktop
attached to a 1080p television offers modes that produce no picture, with no way back
without editing boot partition from another machine.
