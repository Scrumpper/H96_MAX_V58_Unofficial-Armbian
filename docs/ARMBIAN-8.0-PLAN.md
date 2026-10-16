# Armbian 8.0 plan and status

Status of 8.0 work for H96 MAX V58 (RK3588). Planning document, not release note.
Dated 2026-10-16. Nothing here is published as image yet; current release stays v7.2.

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

- Kernel, DTB and h96-* userland become dpkg packages built from pinned inputs and installed into rootfs at image build time.
- Updates arrive as owner-signed bundles. Kernels stage into try-once boot slot with hardware watchdog fallback.
- `h96-selftest` runs same checks on every release candidate that owner and users can run.
- Workarounds whose root cause is fixed are retired, each with one evidence line.
- Backups from v5.0.1 onward keep restoring.

Docs say "built from pinned inputs" until two independent builds of same inputs produce byte-identical image.

## Feature set

| ID | Feature | Tier |
|----|---------|------|
| F1 | Kernel and DTB as dpkg packages (`h96-kernel-<krel>`, `h96-dtb-<krel>`) | core |
| F2 | Try-once kernel slot with watchdog fallback | core |
| F3 | Signed update channel (`h96 update`) | core |
| F4 | h96-* userland as dpkg packages | core |
| F5 | Build-time install, foreign boot package purge, BSP successor | core |
| F6 | DTB from overlay source with tree-diff gate | core |
| F7 | `h96-selftest` | core |
| F8 | Backup and restore 2.6 (schema 4) | core |
| F9 | CI on GitHub-hosted arm64 runners | core |
| F10 | Release staging tool, emit-only by default | core |
| F11 | Workaround retirements with evidence | core |
| F12 | Uniform `h96 status` and `on`, `off`, `status` exit codes | core |
| F13 | Bluetooth attach on first boot | core |
| F14 | External game library mount unit | stretch |
| F15 | Frame-time bench harness | stretch |
| F16 | NetworkManager WiFi opt-in | stretch, held for 8.1 |
| F17 | rk-6.12 scouting kernel | stretch, findings only |

Kernel stays on Rockchip BSP line rk-6.1-rkr7.2 with H96 patch series. Vendor U-Boot, loader blobs and
`armbianEnv.txt` keys stay as on v7.2. Every path that writes `/boot` goes through boot-guard checks.

## Files on this branch

| Path | Contents | Feature |
|------|----------|---------|
| `build/build-kernel-debs.sh` | Builds `h96-kernel-<krel>` and `h96-dtb-<krel>` from kernel build outputs | F1 |
| `patch/dt/h96-max-v58.dtso` | H96 board changes as one device-tree overlay | F6 |
| `patch/dt/h96-max-v58.delete` | Four property deletions overlay cannot express | F6 |
| `tools/dtb/build-dtb.sh` | Applies delete list and overlay to vendor base DTB | F6 |
| `tools/dtb/dt-tree-diff.sh`, `tools/dtb/gate/` | Tree-diff gate against reference DTB | F6 |
| `tools/h96-selftest.py` | Read-only health checks: `boot`, `hw`, `invariants`, `report`, `self-test` | F7 |

### Kernel packages

Payload stages into `/usr/lib/h96-kernel/<krel>/` (Image, System.map, config, DTB) and `/lib/modules/<krel>/`.
Packages contain nothing under `/boot`. Postinst runs `depmod` for its release only; no `/etc/kernel` hooks,
no initramfs tools. Prerm refuses removal of running kernel's package. Separate boot staging tool (F2) copies
files into `/boot`; that tool is not written yet.

```
IMAGE=Image SYSMAP=System.map CONFIG=config MODTAR=modules.tar.gz DTB=board.dtb \
    build/build-kernel-debs.sh out
```

Default inputs are pinned by sha256 to published v7.1 kernel (`6.1.172-h96v58-7.1`) and v7.2 DTB. `PIN=0`
skips pins for other inputs. `Installed-Size` follows file sizes, so output does not depend on filesystem.
`HEAVY=0` runs `dpkg-deb` without shared job lock.

### DTB overlay

```
tools/dtb/build-dtb.sh rk3588-h96-max-v58.dtb out/candidate.dtb
tools/dtb/dt-tree-diff.sh rk3588-h96-max-v58-panthor.dtb out/candidate.dtb out/gate
```

Base is vendor DTB from image (`rk3588-h96-max-v58.dtb`). Gate passes when only phandle numbers differ
(each checked to resolve to same node path) plus lines in `tools/dtb/gate/allowed-residual.txt`. Vendor DTB
binaries are not in repo. Overlay uses vendor labels and full vendor arrays, so it applies to vendor base only.
Board DTB is outside kernel tree; kernel patch series covers kernel sources only.

### h96-selftest

Python standard library only, syntax kept to Python 3.11. Writes nothing except optional report directly under
`/tmp`. `self-test` runs built-in test vectors. `media`, `menus` and `soak` are stubs in this version.

## Work package status

Each package keeps internal evidence (commands, output, sha256) outside repo. "Verified" below means command
output exists for claim; nothing in this list has been booted on hardware unless stated.

| Package | Feature | Status | Verified | Open |
|---------|---------|--------|----------|------|
| Kernel patch series | F1 | Done | Rockchip rk-6.1-rkr7.2 plus 20 commits reproduces v7.1 kernel tree file for file; each commit compiles | Intermediate commits not built into Image or booted; series stays internal until commit messages are cleaned |
| Kernel packages | F1 | Done | Payload sha-identical to v7.1 build outputs; 35 of 35 package checks pass in scratch dpkg root; no `/boot` path; two builds byte-identical on ext4 and tmpfs | Module path `/lib/modules` or `/usr/lib/modules`; install on v7.2 box; boot test; overlay `.dtbo` set not in DTB package |
| DTB overlay | F6 | Done | Overlay build reproduces v7.2 DTB; gate passes; negative tests fail as designed | Boot test under test `fdtfile` name |
| Userland packages | F4 | Open, not on branch | 8 packages build twice identically; scratch dpkg install, remove and purge clean | Blocking issue: first-boot GPU setup unit can point `/boot/Image` at missing file on 8.0 kernel; conffile and diversion issues; lintian not clean; chroot install not done |
| h96-selftest | F7 | Done for `boot`, `hw`, `invariants`, `report` | Runs on Python 3.11 (amd64, arm64); read-only run on v7.2 box with no file changes | `media`, `menus`, `soak` stubs; runs after reboots and upgrade |
| CI workflow | F9 | Open, not on branch | Jobs dry-run in containers; DTB gate job passes with overlay files | Lint and docs jobs fail on current repo; lintian gate not run against userland packages; arm64 runner not confirmed |
| U-Boot bench | F2 | Read-only part done | Boot-mode register, watchdog register decode, load addresses read from image | Live bench runs need owner present; elapsed-time readout needs redesign |
| Backup and restore 2.6 | F8 | Done on laptop | Published restore 2.5 handles schema 4 archive with one warning; proposed 2.6 matches 2.5 on all schema 1 to 3 archives | Run on v7.2 box; Python 3.7 compile check; GUI category gap |

## Milestones

**M0, decisions and bench.** Owner answers on kernel build host, libmali, repo scope, update signing, try-slot
bench, image build path, BSP successor and update check timer. U-Boot bench checks recorded. Kernel series
reconstructed (done). State parity manifest from v7.2 box (done in userland package).

**8.0-alpha.** Platform proven piece by piece on v7.2 box, no image yet. Kernel package installed staging-only
and booted under its own name; overlay DTB booted under test name; userland packages lintian clean and installed in
chroot; selftest runs on box; first green CI run on pull request; backup matrix green in CI. Every alpha boot of
new kernel or DTB needs owner present and Maskrom cable ready.

**8.0-beta.** First chroot-built image, try slot live, one fresh flash. Live boot script test passed
(broken-initramfs fallback, forced-panic fallback, forced watchdog expiry, promote).

**8.0 release candidate.** Feature freeze, signed bundle path exercised, docs through every gate, draft prepared
for owner.

## Owner decisions pending

- Kernel build host and toolchain, or repack of v7.1 kernel unchanged.
- Module install path for kernel package (`/lib/modules` or `/usr/lib/modules`).
- Package version scheme and Maintainer field.
- Whether vendor base DTB and v7.2 reference DTB may be committed as pinned CI inputs.
- Userland paths under `/usr/local` and `/opt` with lintian overrides, or moved paths.
- Update signing key and its location.
- Dates for live U-Boot bench, kernel and DTB test boots, and fresh flash.

## Rules for this work

- No feature enabled by default unless stock Armbian enables it; fixes keep v7.2 enablement.
- Packages never write `/boot`; only boot staging tool does, with guard checks and snapshot diff.
- No release, tag or merge from automation; owner publishes.
- Repo files carry no usernames, host names, home paths or LAN addresses.
