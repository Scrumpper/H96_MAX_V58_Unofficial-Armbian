# Reproduce Unofficial Armbian v8.0 (Ubuntu)

Steps to rebuild each published v8.0 Ubuntu artefact from this repository and compare it with published sha256 values.
Debian Edition: see `docs/REPRODUCE-DEBIAN.md` (same userland and kernel recipe, own image pipeline).

Pin table for every input and output: `build/pins/ubuntu-inputs.tsv` (columns name, url, sha256, size, role).
Rows marked "not public as file" are build outputs or blobs with no standalone download; each row names where to take it from (published image, published zip, or recipe in this repository).

## Requirements

Host: Linux x86_64 or arm64, user namespaces (`unshare --map-auto`), qemu-user-static with binfmt for arm64, e2fsprogs (debugfs, mke2fs, tune2fs, e2fsck), dpkg-dev, gpg, xz-utils, zstd, python3, shellcheck, systemd-run (user scope). No root, no writes to host `/boot`.
Kernel builds: aarch64-linux-gnu-gcc 16.1.0, binutils 2.47, pahole 1.32 (Arch Linux container used for published build).
Disk: about 20 GB free for image build work folder.

## Light check (no inputs, no build)

```
bash build/ubuntu/check-recipe.sh        # expect: check-recipe fail=0
```

Recipe pins `tools/h96-selftest.py` as of commit `081117c`; later selftest commits change its sha256, so check out commit that carries this recipe before rebuild.
Checks syntax of every recipe script, pin table format, stage pins against pin table, repo copies of `f5-rows.sh`, `h96-selftest.py` and `preflight_check.py` against their pins, public keyring fingerprint, and `build/userland/pkgs` tree against `pkgs.manifest`.

## 1. Kernel debs

Recipe: `build/kernel/` (source fetch, compile, deb calls), patch series `patch/kernel-6.12/` and `patch/kernel-6.1/` (each with `SHA256SUMS`), configs `config/kernel-6.12.69-h96v58-8.0.config` and `config/kernel-6.1.172-h96v58-8.0.config`, deb builder `build/build-kernel-debs.sh`.

| Kernel | Vendor base (github.com/armbian/linux-rockchip) | Tree after series |
|---|---|---|
| 6.12.69-h96v58-8.0 (default) | `fa8a79f7d8f35ee81b8e52d9d2d7902213449a1f` | `a2338c0b7acdd6adb29b3c8b365de15675bce311` |
| 6.1.172-h96v58-8.0 (fallback) | `44bbd021d7808cab93d1f2d64c1f092038257576` | `0da5b96600efd935cad572f63d1b9baf7133dc2d` |

```
build/kernel/source.sh 6.12 /work/ksrc612            # prints: tree ok a2338c0b...
JOBS=12 build/kernel/build-6.12.sh /work/ksrc612 /work/out612
build/kernel/source.sh 6.1 /work/ksrc61              # prints: tree ok 0da5b966...
JOBS=12 build/kernel/build-6.1.sh /work/ksrc61 /work/out61
H96_DT_SRC=build/kernel/dt-6.1 tools/dtb/build-dtb.sh dtb/pinned/rk3588-h96-max-v58.dtb /work/dtb61/rk3588-h96-max-v58-panthor.dtb
K612=/work/out612 K61=/work/out61 DTB61=/work/dtb61/rk3588-h96-max-v58-panthor.dtb build/kernel/debs.sh /work/debs
```

`debs.sh` ends with `sha256sum -c` against published debs. Builder pins (`PIN=1`) refuse any Image, System.map, config, modules tarball, DTB or DTBO whose sha256 differs from build outputs of published kernels.

| Build output | sha256 |
|---|---|
| 6.12 Image | `95a659abd83d813b30b72a2358ac5102b603e257487f48d843def6d6b3a98533` |
| 6.12 System.map | `6fa8a2db3dd8c141929f5eae3f58129d9623b150218724f5c78efea058214a98` |
| 6.12 modules tar | `063b6f057855f52b313389d66454daba6dc5ae8fc39b10c4e4d2f0721de51ed6` |
| 6.12 DTB | `601c18fb00d3d24f0cd487131cc6422fafe6edc5f0767a125c81b29773ab1c92` |
| 6.12 USB OTG DTBO | `d13d6ba63e4b2faf2df07aa0fda6bf16872adb0e68e37065a9154e7116066f68` |
| 6.1 Image | `6fbe2fee96d1dbc920d7957877ccb2b140c32a927d647615d877a840af64e8bc` |
| 6.1 System.map | `6d8e615f4e8376088bd9145a59c9ae3f48f3715a287826ae8ff19c7ce430f976` |
| 6.1 modules tar | `a9c2f2c972697937d23a160daff70b021cc7e22c154ddd1a407d351babce3e49` |
| 6.1 DTB | `c907578e168b8c85d7acab4922fc888a85c2b950801d619a5eb5c9d18bcc3234` |

Kernel switch deb:

```
build/build-kernel-switch-deb.sh /work/debs           # h96-kernel-switch_8.0.0~r17_all.deb 64d30837...
```

## 2. Userland debs

Recipe: `build/userland/build-userland-debs.sh` over `build/userland/pkgs/<name>/{root,debian}`. Fixed `SOURCE_DATE_EPOCH=1792152000`.
Binary files (94 blobs: firmware, DXVK DLLs, helper binaries, video stack tarball, man pages) are listed in `build/userland/pkgs.manifest` (type `b`) with sha256 and mode but are not in git. Each blob is installed unchanged in published v8.0 image at path below `pkgs/<name>/root/`.

```
# v8.0 image partition 2 as ext4 file (section 4, "Published image files")
python3 -I build/userland/prepare-pkgs.py --blobs-from /work/v80-p2.img    # text 336 blobs 94 (missing 0) symlinks 4 fail 0
build/userland/build-userland-debs.sh --out /work/debs
```

`prepare-pkgs.py` checks every text file and blob against its sha256 and sets file modes from manifest (git keeps only executable bit).

## 3. Offline repo index

Built by `build/ubuntu/stage.sh dryrun` (`repo-build.py`, `repo-sign.py`): v7.2 image index (`/opt/h96-pkgs/Packages`, sha256 `639fe1c8...`) minus libmali, plus add debs (pin table role "offline-repo add"). Ubuntu adds download from ports.ubuntu.com (URL per row); `h96-vulkan-wsi_8.0.0~r25_arm64.deb` and all adds except `libxss1` and `x11-common` (already in base index) are present in published image under `/opt/h96-pkgs/`.

Values marked `PENDING-8.0-FINAL` follow final v8.0 build (Steam ARM 3.1 deb `1fe5be36...` changes image, image xz, zip and release docs). Offline repo files do not depend on Steam ARM deb (base index plus adds; final build stage holds same five files).

| File | sha256 |
|---|---|
| Packages | `d544313e9c0c3d368a0384e599de0ab1abccc3e5517cb6089c2b61e0c6cae43f` |
| Packages.gz | `0be5ce66adebdb3359dd010b4b18ec090d4fc82bdfa446e9056f08d66dd99595` |
| Release | `bc15f0f0a203a2c97d93b7591086b8c4016ae1fa3b0c5a7d16ad0e0307377fcb` |
| InRelease | `cd24d3c7af75a6aefd26c50fc9862306799602f9d4e1d79cdb9b78077ac8a8e1` |
| Release.gpg | `14a573c83d68fafa44cacf2d0b7805848890b5e5ee0de74934192c199a3c1e3c` |

Signing key: public keyring `keys/offline-repo-public.gpg`, fingerprint `97E5DA90A046ECDC7CE5637131869ED166A6D9EC` (`keys/offline-repo-public.fingerprint`). Image carries same keyring as `/usr/share/keyrings/h96-local-archive-keyring.gpg`.
Without private key, set `H96_REPO_SIG_FROM` to folder with published `Release`, `InRelease` and `Release.gpg` (copied from published image `/opt/h96-pkgs/`). `repo-sign.py` then requires rebuilt Release byte-equal to published Release, requires InRelease body equal to it, verifies both signatures with public keyring, and reuses published signature files. Owner signs with `H96_REPO_KEYDIR`.

## 4. Image

Recipe: `build/ubuntu/` (copied from v8.0 build, paths through environment variables). Pipeline: v7.2 image partitions to trees (debugfs rdump in user namespace), chroot steps under qemu-user (`repo-apply.sh`, `f5-chroot.sh`, `stage-kernel.sh`, `image-brand.sh`, `final-check.sh`, `image-clean.sh`), trees back to ext4 with v7.2 geometry, UUID, label and hash seed, splice into copy of v7.2 image, loader set A1, xz.

Inputs:

| Variable | Content |
|---|---|
| `H96_V72_XZ` | `H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz` (v7.2 release), `.sha256` beside it |
| `H96_INPUTS` | flat folder: 8 userland debs, 4 kernel debs, kernel switch deb, `steam-arm-setup_3.1_arm64.deb` (Steam ARM 3.1 release); pins in `build/ubuntu/inputs.sha256` |
| `H96_BASE_PACKAGES` | `/opt/h96-pkgs/Packages` from v7.2 image |
| `H96_REPO_ADDS` | add debs (pin table rows "offline-repo add") plus `SHA256SUMS` = copy of `build/ubuntu/offline-repo-adds.sha256` |
| `H96_REPO_SIG_FROM` or `H96_REPO_KEYDIR` | published signatures or signing key (section 3) |
| `H96_LOADER_DIR` | folder with `runbook-files/` (`build/ubuntu/loader-blobs.sh`) |
| `H96_V72_ROOTFS_TAR` (optional) | v7.2 rootfs `.tar.zst` for Depends closure checks; skipped with WARN when unset |
| `H96_UBUNTU_IDX` (optional) | Ubuntu resolute index files (pin table) for adds provenance; skipped with WARN when unset |
| `H96_WORK`, `H96_RC_OUT` | work and output folders (default under `$XDG_CACHE_HOME`) |

Published image files: after `build.sh base`, partitions sit at `$H96_WORK/p1.base` and `p2.base`. Published v8.0 image partition 2 starts at byte 553648128, size 3144679424 bytes:

```
dd if=H96-MAX-V58_Unofficial-Armbian_v8.0.img of=/work/v80-p2.img bs=4M skip=553648128 count=3144679424 iflag=skip_bytes,count_bytes
mkdir -p /work/sig && for f in Release InRelease Release.gpg; do debugfs -R "cat /opt/h96-pkgs/$f" /work/v80-p2.img > /work/sig/$f; done
build/ubuntu/loader-blobs.sh H96-MAX-V58_Unofficial-Armbian_v8.0.img /work/loader    # three OK lines
```

Run order:

```
export H96_V72_XZ=/work/v7.2/H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz H96_INPUTS=/work/debs
export H96_REPO_ADDS=/work/adds H96_REPO_SIG_FROM=/work/sig H96_LOADER_DIR=/work/loader
build/ubuntu/build.sh base                                        # v7.2 base img sha 9f366f09, GPT, listings
debugfs -R 'cat /opt/h96-pkgs/Packages' "${H96_WORK:-$HOME/.cache/h96-v80-work}/p2.base" > /work/base-Packages
export H96_BASE_PACKAGES=/work/base-Packages
build/ubuntu/stage.sh dryrun                                      # dryrun fail=0; writes stage/ and DRYRUN-OK
build/ubuntu/build.sh all                                         # base extract chroot mkfs splice; final-check 91 PASS 0 FAIL
build/ubuntu/stage.sh loader                                      # loader A1 rc=0
build/ubuntu/stage.sh pack                                        # PASS xz round trip; OUT/release
```

`build.sh all` refuses stage not written by passing dryrun of current pins. `build.sh null` runs extract and mkfs without chroot steps and must reproduce v7.2 listing (pipeline self test).
Not part of recipe (hardware tests): `box-run.sh`, `ns-up.sh`, `ns-down.sh`, `host-snap.sh` (staged unchanged for on-device build path, no network access).

## 5. Release zip

Zip members: sealed image files, `flash.py`, `MiniLoaderAll.bin`, `FLASHER-SHA256SUMS.txt`, `SHA256SUMS` and release docs. Release docs are authored outside this repository; take them from published zip (member sha256 below).

```
mkdir -p /work/zip/PRODUCTION "/work/zip/Upload v8.0" /work/zip/rel
# PRODUCTION/Unofficial Armbian v8.0/: docs + image files; rel/: 7 sealed files (img.xz, both .sha256, flash.py, MiniLoaderAll.bin, FLASHER-SHA256SUMS.txt, SHA256SUMS)
cp "/work/zip/PRODUCTION/Unofficial Armbian v8.0/CHANGELOG-v8.0.md" "/work/zip/Upload v8.0/"
python3 -I build/ubuntu/zip-times.py Unofficial.Armbian.v8.0.zip "/work/zip/PRODUCTION/Unofficial Armbian v8.0"
python3 -I build/ubuntu/zip-times.py Unofficial.Armbian.v8.0.zip /work/zip/rel --partial
H96_UPLOAD_ROOT=/work/zip/PRODUCTION H96_RELEASE_DIR=/work/zip/rel python3 -I build/ubuntu/stage-and-zip.py 8.0
sha256sum "/work/zip/PRODUCTION/Unofficial Armbian v8.0.zip"      # PENDING-8.0-FINAL
```

`zip-times.py` copies member mtimes and modes from published zip; run it and `stage-and-zip.py` under one TZ. `stage-and-zip.py` gates docs (clinical style, version strings), zips sorted members with ZIP_STORED and reads image back out of finished zip.

Values marked `PENDING-8.0-FINAL` follow final v8.0 build (Steam ARM 3.1 deb `1fe5be36...` changes image, image xz, zip and release docs).

| Zip member | sha256 |
|---|---|
| CHANGELOG-v8.0.md | `PENDING-8.0-FINAL` |
| CHANGELOG.md | `PENDING-8.0-FINAL` |
| COMMANDS.md | `PENDING-8.0-FINAL` |
| FLASHER-SHA256SUMS.txt | `d4d03439d0e9ac4e1d4b6f48f0598d693f6ead34c415637100cd8f704c7a1043` |
| FLASHING.md | `PENDING-8.0-FINAL` |
| KERNEL-COMPARISON.md | `PENDING-8.0-FINAL` |
| MiniLoaderAll.bin | `95325cba73b2de46f160da2df970199c7ecf1bb1d47d6584936ec4cd1e88140e` |
| ON-DEMAND-LIBRARIES.md | `PENDING-8.0-FINAL` |
| README.md | `PENDING-8.0-FINAL` |
| UNDERVOLT_README.md | `PENDING-8.0-FINAL` |
| flash.py | `f51730d3a614c3bf55a2e1f2e10915069b34090acc0a6706389016967c97d778` |

## Expected sha256

Values marked `PENDING-8.0-FINAL` follow final v8.0 build (Steam ARM 3.1 deb `1fe5be36...` changes image, image xz, zip and release docs).

| Artefact | sha256 | Size (B) |
|---|---|---|
| h96-kernel-6.12.69-h96v58-8.0_8.0.0~r23_arm64.deb | `b1469c6501b71c1100b558bb82fdb2a7c8d7a52f6772c96390d8ef578f115894` | 29055896 |
| h96-dtb-6.12.69-h96v58-8.0_8.0.0~r23_arm64.deb | `b42bca1ce3b65b058172633c0cca4facc39baa0d199ceaac4376212db9965e26` | 35132 |
| h96-kernel-6.1.172-h96v58-8.0_8.0.0~r11_arm64.deb | `cd620587d47a675232d260891d719e02afd5d8e7adecda1fbcf4f04e31947746` | 37796860 |
| h96-dtb-6.1.172-h96v58-8.0_8.0.0~r12_arm64.deb | `a62b4d0d5cd10ec2b305fbd5e167d6aa0e4dd5cd751cf5d9ff842a3a6bb6ba50` | 31280 |
| h96-kernel-switch_8.0.0~r17_all.deb | `64d308377692df6f63064f24dca6883a682121d75e0032c2d29829bcd0d5027e` | |
| h96-audio_8.0.0~r39_all.deb | `f3a4f96db71394b00219dfc2d6d434dfd3c2bf596bcb5e1de568177ac821a277` | |
| h96-base_8.0.0~r39_all.deb | `0a793bcbff0fc4a68acf4393eb6c1defe534c26c3c048a262236d01edb1f82a9` | |
| h96-boot_8.0.0~r39_all.deb | `8f8902d3c3218e410aa2fea5e10c2808935694d0bce1d6f2722c9636a4140f18` | |
| h96-desktop_8.0.0~r39_arm64.deb | `37df5a442de668e267902b9d481590b0c06b4bb1bdbcfde867a9e02c91188f43` | |
| h96-gaming_8.0.0~r39_all.deb | `8ec64c70bc99ec425affc95458f8177474e9b69abcdebe68fce235bfe81c8634` | |
| h96-media_8.0.0~r39_arm64.deb | `ff5982c7da7ab68b65e7bedce957d76c274fda0c849b9d02a38c51426e4de64e` | |
| h96-net_8.0.0~r39_all.deb | `7446d68962dab0f735539588d01b80ce4a485af6ac7d6dec6e6432e38912a122` | |
| h96-tools_8.0.0~r39_arm64.deb | `fad05c113654021b1a0b7bb542ed936a53f10f221a52400d829ec5b51062209c` | |
| H96-MAX-V58_Unofficial-Armbian_v8.0.img | `PENDING-8.0-FINAL` | |
| H96-MAX-V58_Unofficial-Armbian_v8.0.img.xz | `PENDING-8.0-FINAL` | |
| Unofficial.Armbian.v8.0.zip | `PENDING-8.0-FINAL` | |

Deb version strings (`8.0.0~rN`) are Debian package versions of published files, not release names.

## Not byte-reproducible

1. Offline repo signature. `InRelease` and `Release.gpg` need owner's private key. Rebuild unsigned content (Packages, Packages.gz, Release must match sha256 above), then verify published signature: `gpgv --keyring keys/offline-repo-public.gpg InRelease` and `gpgv --keyring keys/offline-repo-public.gpg Release.gpg Release`, and compare key fingerprint with `keys/offline-repo-public.fingerprint`. With `H96_REPO_SIG_FROM` image build reuses published signatures; signature from any other key fails `repo-apply.sh` (image keyring check).
2. Image filesystems. `mke2fs` parameters (UUID, label, hash seed, geometry, creation time) are pinned from v7.2 superblocks and file times come from tree listing, but files written during chroot steps (dpkg database, logs, initramfs and uInitrd, ldconfig and font caches, generated units) carry build-time mtimes and content, and inode and block placement follows host directory order in `mke2fs -d`. Expect `.img` and `.img.xz` sha256 to differ. Compare instead: loader area, GPT, gaps and tail (`cmp` of bytes 0 to 16777216 and outside both partitions), then file trees: `python3 -I build/ubuntu/ext4list.py img p2.img listing.tsv --content` for rebuilt and published partition 2, then `ext4list.py cmp published.tsv rebuilt.tsv`; differences limited to mtime and files listed above. Package list: `debugfs -R 'cat /var/lib/dpkg/status'` on both partitions, compare `Package`/`Version` pairs.
3. Kernel compile. Image and modules match published sha256 only with GCC 16.1.0, binutils 2.47 and pahole 1.32. Build timestamp, user and host are fixed in build scripts. 6.12 maps source path in debug info (path independent). 6.1 does not: GNU build-id notes in Image, vDSO and each module depend on source folder path; rebuild elsewhere differs in those notes only (`cmp -l`).
4. Binary inputs without recipe in this repository: v7.2 base image (v7.2 release), loader set A1 blobs (extracted from published image by `loader-blobs.sh`), 94 userland blobs (from published image), `h96-vulkan-wsi` add deb (from published image `/opt/h96-pkgs/`), `steam-arm-setup_3.1_arm64.deb` (Steam ARM 3.1 release).
5. Release zip. Byte-equal only with member mtimes and modes from published zip (`zip-times.py`) and docs taken from published zip.
6. Ubuntu index snapshot. Optional adds provenance check uses index files of fixed date (`Date:` line of each InRelease); live mirror indexes change daily, so use snapshot.ubuntu.com at that date.
