# Kernel switch and rollback

`h96-kernel-switch` boots kernel staged by `h96-kernel-<krel>` package as guarded trial, then keeps it on
confirm or falls back to previous kernel. Planning document for 8.0; tool is tested in stub root only and has
not booted on hardware.

## Contents

1. [Why](#why)
2. [Commands](#commands)
3. [Trial boot sequence](#trial-boot-sequence)
4. [Files written](#files-written)
5. [Refusals](#refusals)
6. [Power loss](#power-loss)
7. [Limits](#limits)
8. [Tests](#tests)

## Why

Kernel packages stage files under `/usr/lib/h96-kernel/<krel>/` and modules under `/usr/lib/modules/<krel>/`;
they never write `/boot`. Vendor U-Boot 2017.09 on H96 MAX V58 has no try-once slot, no boot counter and no
alternative boot command. `boot.scr` loads `/boot/Image`, `/boot/uInitrd` and `/boot/dtb/<fdtfile>`, with
`fdtfile` from `armbianEnv.txt`. Kernel selection is therefore Image and uInitrd links in `/boot`. Tool adds
Linux side guard on top of those links, as v7.1 test kernel guard did.

## Commands

| Command | Action |
|---------|--------|
| `h96-kernel-switch list` | Staged kernels, flagged `running`, `default`, `in-boot`, `trial` |
| `h96-kernel-switch status` | Link targets, recorded trial, last results |
| `h96-kernel-switch try <krel>` | Copies staged kernel into `/boot`, switches links, arms boot guard |
| `h96-kernel-switch try <krel> --auto-confirm` | Same; trial confirms itself 180 s after boot when `multi-user.target` is active |
| `h96-kernel-switch try <krel> --keep-dtb` | Same; board DTB stays as is |
| `h96-kernel-switch confirm` | During trial boot: keeps trial kernel as default |
| `h96-kernel-switch rollback` | Cancels recorded trial, or returns to kernel that was default before last confirm |
| `h96-kernel-switch prune <krel>` | Removes versioned files of one kernel from `/boot` unless links or records name them |

Package `h96-kernel-switch` installs command, man page and three systemd units. Units stay disabled until first
`try` enables `h96-kernel-switch-guard.service` and `h96-kernel-switch-confirm.timer`; both do nothing while no
trial is recorded. Kernel package postinst prints one hint line naming `try`; it switches nothing.

```
sudo apt install ./h96-kernel-6.1.172-h96v58-8.0_*.deb ./h96-dtb-6.1.172-h96v58-8.0_*.deb
sudo h96-kernel-switch try 6.1.172-h96v58-8.0
sudo reboot
# trial boot, after checks:
sudo h96-kernel-switch confirm
```

## Trial boot sequence

1. `try` checks staged `SHA256SUMS.kernel` and `SHA256SUMS.dtb`, checks `modules.dep`, builds initramfs with
   `mkinitramfs` and `mkimage` in `/var/tmp`, checks free space, copies files, records previous link targets in
   `/var/lib/h96-kernel-switch/trial`, then switches links.
2. Reboot. U-Boot follows links and starts trial kernel.
3. Boot guard runs before `sysinit.target`, once `/boot` and `/var/lib` are mounted. On trial kernel it records
   boot ID and points links back at previous set at once. Hang, panic or watchdog reset from here on lands on
   previous kernel.
4. `confirm` in same boot points links at trial set again and clears record. With `--auto-confirm` timer does
   this 180 s after boot when `multi-user.target` is active.
5. Reboot without confirm: links already name previous set; guard records `reverted` and clears trial. Trial
   files stay in `/boot` for retry or `prune`.

`rollback` after confirm returns links to previous set; second `rollback` returns to confirmed set. Previous set
is not guarded, since it booted and was default before.

## Files written

Only `try`, `confirm`, `rollback`, `prune` and boot guard write `/boot`, and only these names:

| Name | Written by |
|------|------------|
| `Image-<krel>`, `uInitrd-<krel>` | `try` (copy through hidden temporary name, then rename) |
| `dtb/<fdtfile>-<krel>` | `try`, when staged DTB differs from current board DTB |
| `dtb/<fdtfile>-<previous krel>` | `try`, once: plain board DTB copied byte for byte before it becomes link |
| `Image`, `uInitrd` | `try`, guard, `confirm`, `rollback` (atomic link swap) |
| `dtb/<fdtfile>` | same, only when DTB differs between sets |

Previous files are never replaced or deleted except by `prune`. `extlinux`, `boot.scr`, `boot.cmd` and
`armbianEnv.txt` are never written. Tool never runs `update-initramfs`, `u-boot-update` or `flash-kernel`.
Link switch order is DTB, uInitrd, Image; each step syncs file and directory.

## Refusals

`try` stops before any `/boot` write when:

- trial is already recorded;
- kernel is not staged, staged sums fail, or `modules.dep` is missing;
- kernel is running or already default;
- `/boot/Image` or `/boot/uInitrd` is not link, or names missing file;
- `/boot/extlinux`, `/boot/boot/extlinux` or `/extlinux` exists (U-Boot reads it before `boot.scr`);
- `/boot` is not mounted or is read-only;
- staged DTB is missing (unless `--keep-dtb`);
- `/boot` free space is below size of files to write plus 16 MiB reserve.

`prune` refuses running kernel and any file named by links, trial record or last confirm. Package removal is
refused while trial is recorded.

## Power loss

Every step writes record first, then files, then links. Boot guard resolves interrupted state on next boot:

| Interrupted in | Next boot |
|----------------|-----------|
| copy (`copying` record) | Links never moved; temporary files removed; record cleared |
| link switch (`switching` record) | Links back on previous set; record cleared |
| guard, before fallback links | Trial kernel boots second time; guard reverts as unconfirmed |
| confirm | Links back on previous set; confirm lost, run trial again |
| rollback | Links back on confirmed set |

## Limits

- Failure before boot guard runs (early panic, initramfs failure, root not mounted) repeats trial boot, because
  links still name trial kernel at that point. Watchdog reset then loops on trial kernel; recovery needs rescue
  media or reflash. Bench test with owner present is required before release.
- Power loss between two link renames gives one boot with mixed set; guard reverts once userspace starts.
- Trial and previous kernel need different release strings; `try` refuses running release.
- DTB link in `dtb/rockchip/` relies on U-Boot following symlinks there, as it does for Image and uInitrd in
  `/boot`; not yet booted.

## Tests

`tools/kernel-switch/test-kernel-switch.sh` runs tool in stub root with stub `mkinitramfs` and `mkimage`:
listing, refusals, low space, healthy trial and confirm, unconfirmed revert, auto-confirm with and without
health, rollback in each state, `--keep-dtb`, identical DTB, prune, unreadable record, and power loss at each
copy, adopt, link, guard, confirm and rollback step. Each case checks `boot.scr`, `boot.cmd` and
`armbianEnv.txt` sums, absence of `extlinux` and absence of temporary files.

```
tools/kernel-switch/test-kernel-switch.sh
build/build-kernel-switch-deb.sh out
```
