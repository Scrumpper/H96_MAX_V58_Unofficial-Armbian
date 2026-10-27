# Reproduce v8.0 Debian Edition

Steps below rebuild Unofficial Armbian v8.0 Debian Edition image and its release zip from this repository. Edition facts: [DEBIAN-EDITION.md](DEBIAN-EDITION.md). Kernel debs, kernel switch deb, Ubuntu userland tree and zip tooling are shared with Ubuntu-based image: [REPRODUCE.md](REPRODUCE.md).

## Published artefacts

| File | sha256 | Size (bytes) |
|---|---|---|
| `Unofficial.Armbian.v8.0.Debian.Edition.zip` (release asset) | `0f41cf00d1c457b48fa7851eddc42086bf29c5ecf710079ebebb2d23b4d41e2d` | 653490372 |
| `H96-MAX-V58_Unofficial-Armbian_v8.0-debian.img.xz` (in zip) | `029ed5699d37dac93a9cbee1844df9ff588feeedc82efb3885c75ae9cae9f0b0` | 652500288 |
| `H96-MAX-V58_Unofficial-Armbian_v8.0-debian.img` (`xz -dc`) | `84ce3d58fd25cc89354a0a244df075b628faa2c4e0d2e66ebf3b1584aeab79ef` | 3699376128 |
| `MiniLoaderAll.bin` (in zip) | `95325cba73b2de46f160da2df970199c7ecf1bb1d47d6584936ec4cd1e88140e` | 448960 |
| `flash.py` (in zip) | `f51730d3a614c3bf55a2e1f2e10915069b34090acc0a6706389016967c97d778` | 67381 |

## Files

- `build/pins/debian-inputs.tsv`: every input, one row each (columns `name`, `url`, `sha256`, `size`, `role`). `name` is path below input folder `$H96_DEB_IN`. `url` is download address, or states `release asset`, `derived: <command>`, `built: <script>` or `not public as file`.
- `build/debian/env.sh`: paths, all settable from environment (`H96_DEB_WORK`, `H96_DEB_IN`, `H96_DEB_EV`, `H96_DEB_OUT`, `H96_REPO_KEYRING`, `H96_DEB_NAME`).
- `build/debian/check.sh`: light dry-run from checkout (without inputs, network or root).
- `build/debian/fetch-inputs.sh`: downloads rows with https URL, checks every sha256, lists rows still needed.
- `build/debian/pipeline/`: image stages (`base.sh`, `prep.sh`, `repo.sh` or `repo-pinned.sh`, `dryrun.sh`, `build.sh`, `assemble.sh`, `loader-pack.sh`), chroot steps (`chroot/`), laptop tests (`tests.sh`, `t11.sh`), `run-all.sh` (stages under `systemd-run` scope and lock).
- `build/debian/userland/`: Debian userland debs from Ubuntu pkgs tree of `build/userland` (`pkgs-debian.patch`, `overlay/`, `build-userland.sh`); `generator/` holds Debian override sources of package generator (`edition_debian.py`, `userland-edition.patch`) that produced `pkgs-debian.patch`. Their `armbian-firstlogin` input (Armbian BSP 26.8.3 file plus H96 bounded wait line) equals `h96-base/root/usr/lib/armbian/armbian-firstlogin` after `pkgs-debian.patch`; separate copy left out (upstream file trips privacy grep and shellcheck gates of CI).
- `build/debian/video/`, `build/debian/wp/`: container rebuilds of video stack, MPRIS plugin and WirePlumber for Debian 13.
- `build/debian/repo-sig/`: published offline repository signatures (`InRelease`, `Release.gpg`).
- `build/debian/tools/`: `seal-release.sh` (public file names), `compare-image.sh` with `e2sums.py` (file level comparison of two images).

## Host

Linux amd64, rootless: `podman` (with `podman unshare`), `qemu-user-static` with arm64 binfmt, `e2fsprogs` (`mke2fs -d`, `debugfs`, `e2fsck`), `dpkg-dev`, `zstd`, `xz-utils`, `gpgv`, `python3`, `curl`, `patch`, `fdisk` (`sfdisk`); `shellcheck` optional. Disk: 15 GB free in `$H96_DEB_WORK`. Heavy stages: `build/debian/pipeline/run-all.sh` runs each under `systemd-run --user --scope -p MemoryMax=20G -p CPUQuota=600%` with `nice -n10` and `flock`.

## Steps

### 1. Dry-run from checkout

```
bash build/debian/check.sh
```

Expected tail: `PASS no host paths, LAN addresses or private key blocks`, `check fail=0`. Signature lines need `keys/offline-repo-public.gpg`.

### 2. Inputs

```
export H96_DEB_WORK=$HOME/work/h96-debian      # default: ${XDG_CACHE_HOME:-~/.cache}/h96-debian-repro
bash build/debian/fetch-inputs.sh               # downloads, checks, prints NEED rows
```

Debian pool files gone from `deb.debian.org` come from `snapshot.debian.org` at `H96_DEB_SNAPSHOT` (default `20261023T060000Z`). Rows printed as `NEED`, by `url` column:

| Row | Source |
|---|---|
| `H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz` | v7.2 release zip |
| `v72-rootfs.tar.zst` | `bash build/debian/pipeline/v72-rootfs.sh`, then `export H96_DEB_V72_SHA=<printed sha>` (see Not byte-reproducible) |
| `v72-opt-h96-pkgs.Packages` | `tar --zstd -xOf $H96_DEB_IN/v72-rootfs.tar.zst ./opt/h96-pkgs/Packages` |
| `keys/*.gpg` | command in `url` column |
| `debs/h96-kernel-*`, `debs/h96-dtb-*` | `build/kernel` ([REPRODUCE.md](REPRODUCE.md)); same debs as Ubuntu-based image |
| `debs/h96-kernel-switch_*` | `build/build-kernel-switch-deb.sh` |
| `debs/h96-{base,boot,net,audio,desktop,media,tools,gaming}_*+deb13.1_*` | `bash build/debian/userland/build-userland.sh` (needs Ubuntu pkgs tree with blobs: `build/userland/prepare-pkgs.py --blobs-from`), output `$H96_DEB_WORK/userland-debs` |
| `video/h96-video-stack.tar.gz`, `video/mpris.so` | `bash build/debian/video/run.sh stack`, `... run.sh mpris` |
| `video/ubuntu-stack.tar.gz` | `usr/lib/h96/video/h96-video-stack.tar.gz` of Ubuntu `h96-media` 8.0 deb |
| `debs/wireplumber_*`, `debs/libwireplumber-*` | `bash build/debian/wp/run.sh` |
| `debs/steam-arm-setup_3.1_arm64.deb` | Steam ARM 3.1 release asset |
| `debs/steam-arm-setup_3.0_arm64.deb` | Steam ARM 3.0 release asset (closure input of `repo.sh` only) |
| `repo/box64-*`, `repo/box86-*`, `repo/librga2_*`, `repo/librockchip-*`, `repo/libv4l-rkmpp_*`, `repo/rockchip-mpp-demos_*` | `./opt/h96-pkgs/<file>` of `v72-rootfs.tar.zst` |
| `repo/wireplumber_*`, `repo/libwireplumber-*` | copy of `debs/` rows |
| `loader/*` | `dd` command in `url` column, from published v8.0 Debian image or v7.2 image |

Run `bash build/debian/fetch-inputs.sh --check` until it prints `need=0 bad=0`.

### 3. Image stages

```
P=build/debian/pipeline
bash $P/run-all.sh base.sh prep.sh             # base tarball; prep needs network (Debian and Armbian mirrors)
bash $P/repo-pinned.sh                         # offline repo from pins (light)
bash $P/dryrun.sh                              # gates, writes $H96_DEB_WORK/stage
bash $P/run-all.sh build.sh assemble.sh loader-pack.sh
bash $P/run-all.sh tests.sh t11.sh             # optional: laptop chroot tests
```

`repo.sh` is alternative to `repo-pinned.sh`: it resolves closure against live mirrors (network) and gives same index only while mirrors hold same versions. Expected gate lines: `repo-pinned.sh` `PASS repo/<file> = pins` for all five index files; `dryrun.sh` `dryrun fail=0`; `build.sh` `build rc=0`, `final-check` 101 `PASS` lines and 0 `FAIL`; `assemble.sh` `PASS e2fsck -fn p1`, `PASS e2fsck -fn p2`, `PASS sectors 0..32767 = v7.2`; `loader-pack.sh` `PASS bytes past sector 32767 unchanged`, `PASS xz round trip`. Box tests (flash, boot) are optional and not part of reproduction: release zip `FLASHING.md`.

### 4. Seal and zip

```
bash build/debian/tools/seal-release.sh "$REL" "$FLASHER"    # FLASHER: flash.py, MiniLoaderAll.bin, FLASHER-SHA256SUMS.txt from published zip
```

Zip docs (`README.md`, `CHANGELOG.md`, `CHANGELOG-v8.0.md`, `COMMANDS.md`, `DEBIAN-EDITION.md`, `FLASHING.md`, `KERNEL-COMPARISON.md`, `ON-DEMAND-LIBRARIES.md`, `UNDERVOLT_README.md`) come from published zip. Member times and zip tool: `build/ubuntu/zip-times.py` and `build/ubuntu/stage-and-zip.py 8.0 --edition=debian` with `H96_EDITION_ROOT` (or `H96_RELEASE_DIR`, `H96_UPLOAD_ROOT`), as in [REPRODUCE.md](REPRODUCE.md).

### 5. Compare

```
xz -dc H96-MAX-V58_Unofficial-Armbian_v8.0-debian.img.xz > published.img
bash build/debian/tools/compare-image.sh published.img "$H96_DEB_WORK/H96-MAX-V58_Unofficial-Armbian_v8.0-debian.img" cmp/
```

Raw areas compared byte for byte; partitions compared as inventories (path, type, mode, owner, link target, xattrs) and file sha256 lists (slow: one `debugfs` call per file).

## Expected sha256 per artefact

| Artefact | sha256 | Byte-reproducible |
|---|---|---|
| `trixie-rootfs.tar.zst` (`base.sh`) | `44bb41f28584360f82c45fec36e5acdd2c3c615e2f90218c0259800c3e4ee92d` | expected (pinned image, fixed mtime, sorted), not checked |
| `prep-rootfs.tar.zst` (`prep.sh`) | `44c469e413a8a9dff22b19451b8b38a6cecdfd87563035242fcd7f70668f1d54` | no |
| offline repo `Packages` | `56f0f6d3bc00e58ff36d9f8e33dcf076119208d63a2ab061657948ff48627455` | yes (checked against pinned debs) |
| offline repo `Packages.gz` | `39f004b292f3f1e191f4424b54b98ff07debbc00af9862144a9e084070770946` | yes (checked against pinned debs) |
| offline repo `Release` | `b213edf7c1e77a17fc8015abb0741d303e873fb2f11525e0773743639c8005db` | yes (checked against pinned debs) |
| offline repo `InRelease` | `02790cd75a0ea5824bfae5524cc1abcf22510a9b7231864ecf752ec1055dd760` | published file reused |
| offline repo `Release.gpg` | `fcc5462a08fe8d422aad74dd4ab3a3ad164432bc3d03dc02149d2eba657cc3f9` | published file reused |
| `stage/` (`dryrun.sh`) | file by file equal to production stage of same inputs (checked) | yes, given pinned inputs |
| `built-rootfs.tar.zst` (`build.sh`) | `aa6de0ef3ed68f6648ca62e2b70af71b4b5dc3b453b3f00f004c43f228254001` | no |
| assembled image (before loader step) | `822c5309b46475f4565c5b3db039a1eccb2f169694f1bdc2cf236b5ddae80ac2` | no |
| bytes past sector 32767 of final image | `40831fee929d129eb4c6b0b18b7ba4580ad532541337e53c2d20aaa36cd898df` | no |
| final image | `84ce3d58fd25cc89354a0a244df075b628faa2c4e0d2e66ebf3b1584aeab79ef` | no |
| image `.xz` | `029ed5699d37dac93a9cbee1844df9ff588feeedc82efb3885c75ae9cae9f0b0` | no (follows image) |
| release zip | `0f41cf00d1c457b48fa7851eddc42086bf29c5ecf710079ebebb2d23b4d41e2d` | no (follows image) |
| userland debs, kernel debs, kernel switch deb | sha256 in pins file | userland: two builds equal; kernel: [REPRODUCE.md](REPRODUCE.md) |

## Not byte-reproducible

- Offline repository signature: `InRelease` and `Release.gpg` need owner private key, which is not in this repository. Rebuild signs nothing: `repo-pinned.sh` and `repo-index.sh` write `Release` and copy published signatures from `build/debian/repo-sig/`. `Release` is deterministic (fixed `Date`), so published signatures verify against rebuilt `Release` with `keys/offline-repo-public.gpg` (`check.sh`, `repo-pinned.sh` `PASS InRelease gpgv`). With owner key: `H96_REPO_GNUPG=<key dir>`.
- Prep stage (`prep.sh`): `apt-get update`, purge, BSP swap, base packages and point release upgrade run against live Debian and Armbian mirrors at build time (released build: 2026-10-23 around 06:00 UTC). Package versions follow mirror state; dpkg and apt logs, `/var/lib/apt/lists` and file mtimes carry build time. Pin mirror state with `snapshot.debian.org` sources for closest result.
- Chroot stages (`prep.sh`, `build.sh`): file mtimes, dpkg and apt logs, generated caches and maintainer script output carry build time. `mke2fs -d` copies mtimes into both partitions, so partition bytes and image sha differ. `E2FSPROGS_FAKE_TIME` fixes superblock and `lost+found` times only. Compare with `compare-image.sh` (inventory and file sha256 level).
- `v72-rootfs.tar.zst`: released build packed v7.2 image tree under fakeroot without sorted member order; `v72-rootfs.sh` packs same tree sorted inside `podman unshare`, so tarball sha differs from pins row while member content matches. Set `H96_DEB_V72_SHA` to new sha.
- Video stack, MPRIS plugin and WirePlumber debs: container builds install toolchains and `-dev` packages from live Debian mirrors; output sha matches pins only while mirrors hold same versions. Source tarballs from GitHub archive URLs can differ in bytes from pinned files (tree content stays).
- Release zip: follows image `.xz`; zip member times come from `build/ubuntu/zip-times.py` and published zip.
- Steam ARM 3.1 deb: release asset of Steam ARM 3.1; not available as file until that release is public.
