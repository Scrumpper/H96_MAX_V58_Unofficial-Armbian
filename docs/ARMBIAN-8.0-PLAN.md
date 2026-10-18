# Armbian 8.0 plan and status

Status of 8.0 work for H96 MAX V58 (RK3588). Planning document, not release note.
Dated 2026-10-18. 8.0 is in beta: beta images are built and flashed on test hardware, none
is published, and current release stays v7.2.

## Contents

1. [Scope](#scope)
2. [Feature set](#feature-set)
3. [Files on this branch](#files-on-this-branch)
4. [Work package status](#work-package-status)
5. [Milestones](#milestones)
6. [Owner decisions pending](#owner-decisions-pending)
7. [Rules for this work](#rules-for-this-work)

## Scope

8.0 is platform release. It adds no new media or gaming features.

- Kernel, DTB and h96-* userland become dpkg packages built from pinned inputs and installed into rootfs at image
  build time.
- Updates arrive as owner-signed bundles. Kernels stage into try-once boot slot with hardware watchdog fallback.
- `h96-selftest` runs same checks on every release candidate that owner and users can run.
- Workarounds whose root cause is fixed are retired, each with one evidence line.
- Backups from v5.0.1 onward keep restoring.

Docs say "built from pinned inputs" until two independent builds of same inputs produce byte-identical image.

## Feature set

| Feature | Tier |
|---------|------|
| Kernel and DTB as dpkg packages (`h96-kernel-<krel>`, `h96-dtb-<krel>`) | core |
| Try-once kernel slot with watchdog fallback | core |
| Signed update channel (`h96 update`) | core |
| h96-* userland as dpkg packages | core |
| Build-time install, foreign boot package purge, BSP successor | core |
| DTB from overlay source with tree-diff gate | core |
| `h96-selftest` | core |
| Backup and restore 2.6 (schema 4) | core |
| CI on GitHub-hosted arm64 runners | core |
| Release staging tool, emit-only by default | core |
| Workaround retirements with evidence | core |
| Uniform `h96 status` and `on`, `off`, `status` exit codes | core |
| Bluetooth attach on first boot | core |
| External game library mount unit | stretch |
| Frame-time bench harness | stretch |
| NetworkManager WiFi opt-in | stretch, held for 8.1 |
| rk-6.12 scouting kernel | stretch, findings only |

Kernel stays on Rockchip BSP line rk-6.1-rkr7.2 with H96 patch series. Vendor U-Boot, loader blobs and
`armbianEnv.txt` keys stay as on v7.2. Every path that writes `/boot` goes through boot-guard checks.

## Files on this branch

| Path | Contents | Area |
|------|----------|------|
| `build/build-kernel-debs.sh` | Builds `h96-kernel-<krel>` and `h96-dtb-<krel>` from kernel build outputs | Kernel packages |
| `patch/dt/h96-max-v58.dtso` | H96 board changes as one device-tree overlay | DTB overlay |
| `patch/dt/h96-max-v58.delete` | Four property deletions overlay cannot express | DTB overlay |
| `tools/dtb/build-dtb.sh` | Applies delete list and overlay to vendor base DTB | DTB overlay |
| `tools/dtb/dt-tree-diff.sh`, `tools/dtb/gate/` | Tree-diff gate against reference DTB | DTB overlay |
| `dtb/pinned/` | Vendor base DTB, published v7.2 reference DTB, `SHA256SUMS` | DTB overlay, CI |
| `tools/h96-selftest.py` | Read-only health checks: `boot`, `hw`, `invariants`, `report`, `self-test` | h96-selftest |

### Kernel packages

Payload stages into `/usr/lib/h96-kernel/<krel>/` (Image, System.map, config, DTB) and `/usr/lib/modules/<krel>/`.
Packages contain nothing under `/boot`. Postinst runs `depmod` for its release only; no `/etc/kernel` hooks,
no initramfs tools. Prerm refuses removal of running kernel's package. Separate boot staging tool, part of
try-once kernel slot, copies files into `/boot`; that tool is not written yet.

```
MAINT='Name <email>' IMAGE=Image SYSMAP=System.map CONFIG=config MODTAR=modules.tar.gz DTB=board.dtb \
    build/build-kernel-debs.sh out
```

Inputs have no defaults; every input path and `MAINT` must be set, or script stops. Default `KREL` is
`6.1.172-h96v58-8.0`; default `MODPREFIX` is `/usr/lib/modules` (merged `/usr` path, lintian clean). With `PIN=1`
(default) script checks each input against sha256 of 8.0 kernel build outputs and overlay DTB; `PIN=0` skips that
check for other inputs. Default `PKGVER` belongs to pinned inputs. Version carries build round after `~`, so every
pre-release sorts below `8.0.0`; version is never reused for different content, so new inputs take new version.
`Installed-Size` follows file sizes, so output does not depend on filesystem. `dpkg-deb` runs directly by default;
`HEAVY=1` with `HEAVY_LOCK=<lock file>` and `HEAVY_MEM=<size>` runs it under `flock` and `systemd-run` memory cap. CI
smoke debs use version `0~ci`, never release version.

### DTB overlay

```
tools/dtb/build-dtb.sh rk3588-h96-max-v58.dtb out/candidate.dtb
tools/dtb/dt-tree-diff.sh rk3588-h96-max-v58-panthor.dtb out/candidate.dtb out/gate
```

Base is vendor DTB from image (`rk3588-h96-max-v58.dtb`). Gate passes when residual lines equal
`tools/dtb/gate/allowed-residual.txt` after phandle renumbering is removed. Renumbering check covers changed lines
only: each changed phandle value must resolve to same node path in both trees. Unchanged lines are not resolved
again. Vendor base DTB and v7.2 reference DTB sit in `dtb/pinned/`, checked by `SHA256SUMS`; CI runs tree diff on
them with `H96_CI_STRICT` set, so missing or changed inputs fail job. Overlay uses vendor labels and full vendor
arrays, so it applies to vendor base only.
Board DTB is outside kernel tree; kernel patch series covers kernel sources only.

### h96-selftest

Python standard library only, syntax kept to Python 3.11. Writes nothing except optional report directly under
`/tmp`. `self-test` runs built-in test vectors. `media`, `menus` and `soak` are stubs in this version.

## Work package status

Each package keeps internal evidence (commands, output, sha256) outside repo. "Verified" below means command
output exists for claim; nothing in this list has been booted on hardware unless stated.

| Package | Status | Verified | Open |
|---------|--------|----------|------|
| Kernel patch series | Done | Rockchip rk-6.1-rkr7.2 plus 20 commits reproduces v7.1 kernel tree file for file; each commit compiles; commit messages carry no internal labels; kernel `6.1.172-h96v58-8.0` built from series with pinned GCC 16.1.0 toolchain, symbol map equal to v7.1 apart from embedded config size; boots in beta image | Intermediate commits not built into Image or booted; series not in public repo |
| Kernel packages | Done | 8.0 payload sha-identical to 8.0 build outputs and overlay DTB; modules under `/usr/lib/modules`; 37 of 37 package checks pass in scratch dpkg root; no `/boot` path; lintian clean with no suppressed tags; two builds byte-identical on ext4 and tmpfs; installed in beta image, which boots it | Boot staging tool for installed systems; overlay `.dtbo` set not in DTB package |
| DTB overlay | Done | Overlay build matches v7.2 DTB tree apart from 2 renumbered phandles and 2 new labels; gate passes; `/boot` output guard refuses `/boot` and paths below it; negative tests fail as designed; beta image boots overlay DTB | None for beta |
| Userland packages | Done for beta, sources not on branch | 8 packages (`h96-base`, `h96-boot`, `h96-net`, `h96-audio`, `h96-desktop`, `h96-media`, `h96-tools`, `h96-gaming`) build twice identically; files moved out of `/usr/local` and `/opt`; lintian clean, overrides only where tag cannot be fixed; chroot install on v7.2 image passes every parity gate; `dpkg -V` and `dpkg --audit` empty | Boot 1 journal volatile; runtime-rewritten files listed by `dpkg -V`; branding conffiles on upgrade |
| Beta image | Built, flashed on test hardware | Chroot install of kernel, DTB, userland and `steam-arm-setup` packages on v7.2 image; first boot completes with one planned reboot; `h96-selftest` hw checks pass (Panthor, Mesa 26.1.4, PanVK, MPP, RGA, CEC, NPU, HDMI, audio, Bluetooth, WiFi, Ethernet) | Steam ARM 3.0 in next beta build; try-once slot not in beta (rollback is v7.2 reflash) |
| h96-selftest | Done for `boot`, `hw`, `invariants`, `report` | Runs on Python 3.11 (amd64, arm64); read-only run on v7.2 box with no file changes | `media`, `menus`, `soak` stubs; runs after reboots and upgrade |
| CI workflow | Open, not on branch | Jobs dry-run in containers; DTB gate job passes with overlay files | Lint and docs jobs fail on current repo; lintian gate not run against userland packages; arm64 runner not confirmed |
| U-Boot bench | Read-only part done | Boot-mode register, watchdog register decode, load addresses read from image | Live bench runs need owner present; elapsed-time readout needs redesign |
| Backup and restore 2.6 | Done off box | Published restore 2.5 handles schema 4 archive with one warning; proposed 2.6 matches 2.5 on all schema 1 to 3 archives | Run on v7.2 box; Python 3.7 compile check; GUI category gap |

## Milestones

**M0, decisions and bench.** Owner answers on kernel build host, libmali, repo scope, update signing, try-slot
bench, image build path, BSP successor and update check timer. U-Boot bench checks recorded. Kernel series
reconstructed (done). State parity manifest from v7.2 box (done in userland package).

**8.0-alpha.** Platform proven piece by piece on v7.2 box, no image yet. Kernel package installed staging-only
and booted under its own name; overlay DTB booted under test name; userland packages lintian clean and installed in
chroot; selftest runs on box; first green CI run on pull request; backup matrix green in CI. Every alpha boot of
new kernel or DTB needs owner present and Maskrom cable ready.

**8.0-beta.** First chroot-built image, try slot live, one fresh flash. Live boot script test passed
(broken-initramfs fallback, forced-panic fallback, forced watchdog expiry, promote). Current state: chroot-built
image and fresh flash done; try slot and live boot script tests still open.

**8.0 release candidate.** Feature freeze, signed bundle path exercised, docs through every gate, draft prepared
for owner.

## Owner decisions pending

Decided 2026-10-17: kernel rebuilt in container with pinned GCC 16.1.0 as `6.1.172-h96v58-8.0`; modules under
`/usr/lib/modules`; package version carries build round after `~` and is never reused; Maintainer
`Scrumpper <190908034+Scrumpper@users.noreply.github.com>`; vendor base DTB and v7.2 reference DTB committed as pinned
CI inputs; `libmali` dropped, Mesa only; packaged files moved out of `/usr/local` and `/opt`. Still open:

- Update signing key and its location.
- Dates for live U-Boot bench, kernel and DTB test boots, and fresh flash.

## Rules for this work

- No feature enabled by default unless stock Armbian enables it; fixes keep v7.2 enablement.
- Packages never write `/boot`; only boot staging tool does, with guard checks and snapshot diff.
- No release, tag or merge from automation; owner publishes.
- Repo files carry no usernames, host names, home paths or LAN addresses.
