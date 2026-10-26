# Debian Edition

Unofficial Armbian v8.0 Debian Edition is published in v8.0 release as `Unofficial.Armbian.v8.0.Debian.Edition.zip` (image `H96-MAX-V58_Unofficial-Armbian_v8.0-debian.img.xz`). This file describes its build method and differences from Ubuntu-based 8.0 image. Rebuild steps, input pins and expected sha256 values: [REPRODUCE-DEBIAN.md](REPRODUCE-DEBIAN.md).

## Base

- Root filesystem from Armbian 26.8.3 Rock 5B trixie `vendor` minimal image (sha256 and Armbian signature checked), brought to current Debian 13 point release and security updates at build time. Only its root filesystem is used: its partition layout, boot script, `/boot` files and U-Boot are discarded.
- Boot chain equals Ubuntu-based 8.0 image: same raw loader area and GPT geometry, same `boot.scr`, `armbianEnv.txt` keys, device tree directory and `overlay-user` on partition 1, `/boot/Image` and `/boot/uInitrd` links, `h96-kernel-switch` generations.
- Vendor kernel, DTB and U-Boot packages of download are purged. Board support package `armbian-bsp-cli-odroidn2-current` 26.8.3 replaces `armbian-bsp-cli-rock-5b-vendor` (same package lineage as Ubuntu-based image); `/etc/armbian-release` names H96 Max V58 board, `INITRD_ARCH=arm64`, boot script update off.
- NetworkManager renders network (netplan file as Ubuntu-based image), `dhcpcd-base`, `irqbalance`, `rfkill`, `python3-tk`, `python3-dbus`, `python3-gi`, `qrencode`, `stress` and AP6275P Wi-Fi firmware files installed. Apt package lists kept in image. Console login as Ubuntu-based image: no automatic root login; `systemd-networkd` off. `systemd-gpt-auto-generator` masked and Ubuntu `55-*` sysctl defaults carried, as v7.2.

## Packages

- Same kernel packages as Ubuntu-based 8.0 image: 6.12 default, 6.1 fallback, `h96-kernel-switch`, `steam-arm-setup`.
- Eight H96 userland packages built from same sources with Debian overrides; Debian build version sorts above Ubuntu build of same release. Changelog distribution `trixie`.
- Overrides read `ID` from `/etc/os-release`, so one script form serves both distributions: Mesa pin names Debian trixie-backports build (every Mesa binary package of that build), Mesa target in gaming setup, WirePlumber offline version, online extras host and package list, Steam FEX source (Ubuntu noble FEX build with pinned key when `add-apt-repository` is absent), KDE X11 package set installed package by package, video setup runtime package list.
- `h96-media` carries video stack rebuilt against Debian 13 libraries: mpv 0.41.0 with PipeWire and PulseAudio audio outputs and ffmpeg-rockchip `40c412d` with same patches and feature list, highest glibc symbol 2.38; package depends on `libc6 (>= 2.38)`. Video setup installs `libpipewire-0.3-0t64` and `libpulse0` from offline repository. mpv MPRIS plugin (mpv-mpris 1.2 without libavformat, same patch) built against Debian 13 glib.
- `COMMANDS.md`: ophub update guard text states Debian Edition carries no ophub scripts (no `armbian-sync`); `h96-vulkan-wsi` section states package is not provided; line count equal to Ubuntu text.
- `armbian-firstlogin` copy rebased on Armbian BSP 26.8.3 file; H96 change kept (bounded wait for system start).
- Console banner and os-release `VARIANT` name Debian Edition; `/etc/h96-release` carries `H96_EDITION=debian`.

## Offline repository

`/opt/h96-pkgs`, signed with offline repository key, holds what first-boot units install without network: Mesa 26.1.6 from trixie-backports, PipeWire 1.6.9 from trixie-backports, BlueZ, WirePlumber 0.5.18 rebuilt for trixie, cage, Vulkan and Mesa tools, video stack runtime libraries, Rockchip MPP and RGA packages, box64 fallback, with dependency closure against image state. Every Debian package matches signed Debian index (package, version, sha256).

## Differences from Ubuntu-based 8.0 image

| Area | Ubuntu-based image | Debian Edition |
|---|---|---|
| Distribution | Ubuntu 26.04, Armbian 26.05 | Debian 13 trixie, Armbian 26.8.3 |
| KDE Plasma | 6.6 | 6.3 (Debian 13) |
| Mesa | 26.1.4 (kisak PPA build) | 26.1.6 (trixie-backports), pinned exact |
| PipeWire, WirePlumber | 1.6.2, 0.5.18 | 1.6.9 (trixie-backports), 0.5.18 rebuilt |
| Chromium | xtradeb PPA build | Debian package |
| gamescope, `libspa-0.2-modules-extra` | installed online | not in Debian 13, skipped |
| ophub tools (`armbian-sync`, `armbian-ddbr`, ...) | present | absent |
| `h96-vulkan-wsi` (patched PanVK Wayland presentation, opt-in) | in offline repository | not provided: package depends on kisak Mesa 26.1.4 exactly; `h96-game-mode` uses stock Vulkan driver |
| UI font in KDE baseline | `fonts-ubuntu` | `fonts-noto-core` |
| Python | 3.14 | 3.13 |
| Time sync | chrony | `systemd-timesyncd` |
| Security updates | Ubuntu archive | Debian security for main; backports builds pinned exact, without security team support |

## Build

Laptop only, rootless: root filesystem edited in arm64 chroot through qemu inside `podman unshare`; partitions built with `mke2fs -d` (feature set of Ubuntu-based image); raw loader area and backup GPT copied from v7.2 image; loader set written by same pinned loader step as Ubuntu-based image. Box tests: `CHANGELOG.md` in release zip, entry v8.0 Debian Edition. Pipeline scripts: `build/debian/` (see [REPRODUCE-DEBIAN.md](REPRODUCE-DEBIAN.md)).
