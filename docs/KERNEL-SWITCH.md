# Kernel switch and rollback

`h96-kernel-switch` boots kernel staged by `h96-kernel-<krel>` package as guarded trial, then keeps it on
confirm or falls back to previous kernel. Planning document for 8.0; tool is tested in stub root only and has
not booted on hardware.

## Contents

1. [Why](#why)
2. [Boot file layout](#boot-file-layout)
3. [Commands](#commands)
4. [Trial boot sequence](#trial-boot-sequence)
5. [Files written](#files-written)
6. [Refusals](#refusals)
7. [Power loss](#power-loss)
8. [DTB handling: owner decision](#dtb-handling-owner-decision)
9. [h96-undervolt](#h96-undervolt)
10. [Limits](#limits)
11. [Tests](#tests)

## Why

Kernel packages stage files under `/usr/lib/h96-kernel/<krel>/` and modules under `/usr/lib/modules/<krel>/`;
they never write `/boot`. Vendor U-Boot 2017.09 on H96 MAX V58 has no try-once slot, no boot counter and no
alternative boot command. `boot.scr` loads `/boot/Image`, `/boot/uInitrd` and `/boot/dtb/<fdtfile>`, with
`fdtfile` from `armbianEnv.txt`. Kernel selection is therefore link layout in `/boot`. Tool adds Linux side
guard on top of those links, as v7.1 test kernel guard did.

## Boot file layout

Three separate links cannot change together: power loss between two renames leaves mixed set (new DTB with old
Image, old Image with new initramfs), and that boot happens before any guard runs. Tool therefore keeps each
kernel set in one generation directory and points every boot name through one link:

```
/boot/Image                      -> h96ks/cur/Image
/boot/uInitrd                    -> h96ks/cur/uInitrd
/boot/dtb/<fdtfile>              -> ../../h96ks/cur/fdt      (only once DTB differs between kernels)
/boot/h96ks/cur                  -> <new krel>.g1
/boot/h96ks/<new krel>.g1/{Image,uInitrd,fdt}
/boot/h96ks/<previous krel>.g1/{Image,uInitrd,fdt}
```

Switching kernel is one rename of `h96ks/cur`, so U-Boot reads either complete old set or complete new set.
Generation directory is written under hidden temporary name, read back, then renamed into place; it never
changes afterwards. Retry of same release writes new generation (`.g2`) and removes earlier unused attempt.

8.0 beta image has `Image -> Image-<krel>` and `uInitrd -> uInitrd-<krel>` with plain DTB file. First `try`
converts this layout in steps that each keep content every boot name resolves to: previous generation holds hard
links to current `Image-<krel>` and `uInitrd-<krel>` plus DTB copy, `h96ks/cur` points at it, then `uInitrd`,
`Image` and (when needed) DTB path move onto `h96ks/cur`.

U-Boot side: `ext4fs_find_file1` in U-Boot 2017.09 (`fs/ext4/ext4_common.c`) resolves relative link targets from
directory holding link, walks directory parts and `..` entries, and allows 8 nested links per lookup (counter
reset per file). Layout above needs 2 per file, 3 for DTB when `dtb` itself links to `dtb-<krel>`. Plain-name
`Image` and `uInitrd` links boot on hardware every day; links with directory parts have not booted yet (owner
bench).

## Commands

| Command | Action |
|---------|--------|
| `h96-kernel-switch list` | Staged kernels, flagged `running`, `default`, `in-boot`, `trial` |
| `h96-kernel-switch status` | Default release, link targets, recorded trial, last results |
| `h96-kernel-switch default` | Release that boot files start |
| `h96-kernel-switch try <krel>` | Writes new generation, records trial, moves `h96ks/cur`, arms boot guard |
| `h96-kernel-switch try <krel> --auto-confirm` | Same; trial confirms itself 180 s after boot when `multi-user.target` is active |
| `h96-kernel-switch try <krel> --keep-dtb` | Same; board DTB stays as is |
| `h96-kernel-switch confirm` | During trial boot: keeps trial kernel as default |
| `h96-kernel-switch rollback` | Cancels recorded trial, or returns to kernel that was default before last confirm |
| `h96-kernel-switch rollback --keep-dtb` | Same; accepted when plain DTB differs from DTB of previous generation |
| `h96-kernel-switch prune <krel>` | Removes generations and plain-name files of one kernel unless links or records name them |
| `h96-kernel-switch in-use <krel>` | Roles of kernel in boot files: `default`, `trial`, `trial-previous`, `rollback-target` |
| `h96-kernel-switch dtb` | Board DTB `path`, `layout` (`plain`, `managed`, `link`), resolved `file`, recorded `trial` phase; read only |
| `h96-kernel-switch dtb-plain` | Turns managed DTB link back into plain file with content of `h96ks/cur/fdt` |

Package `h96-kernel-switch` installs command, man page and three systemd units. Units stay disabled until first
`try` enables `h96-kernel-switch-guard.service` and `h96-kernel-switch-confirm.timer`; both do nothing while no
trial is recorded. Preset file `90-h96-kernel-switch.preset` keeps guard, timer and confirm service disabled under
`systemctl preset-all`.

Kernel package maintainer scripts ask `h96-kernel-switch in-use` (read only) when command is installed:

- postinst prints two hint lines naming `try`, except when release is already default or on trial; without
  `h96-kernel-switch`, hint is skipped when release is running;
- prerm refuses removal of running release and of release that is default, on trial or rollback target
  (`H96_KERNEL_FORCE_REMOVE=1` overrides), since its modules would be missing at next boot.

```
sudo apt install ./h96-kernel-6.1.172-h96v58-8.0_*.deb ./h96-dtb-6.1.172-h96v58-8.0_*.deb
sudo h96-kernel-switch try 6.1.172-h96v58-8.0
sudo reboot
# trial boot, after checks:
sudo h96-kernel-switch confirm
```

## Trial boot sequence

1. `try` checks staged `SHA256SUMS.kernel` and `SHA256SUMS.dtb`, `modules.dep` and release string embedded in
   staged Image, builds initramfs with `mkinitramfs` and `mkimage` in `/var/tmp`, checks free space, converts
   layout if needed, writes generation, records trial (`armed`) in `/var/lib/h96-kernel-switch/trial`, then moves
   `h96ks/cur`.
2. Reboot. U-Boot follows links and starts trial kernel.
3. Boot guard runs before `sysinit.target`, once `/boot` and `/var/lib` are mounted. On trial kernel it records
   boot ID and points `h96ks/cur` back at previous generation at once. Hang, panic or watchdog reset from here on
   lands on previous kernel.
4. `confirm` in same boot records `commit`, points `h96ks/cur` at trial generation, writes last-confirm record
   and clears trial. With `--auto-confirm` timer does this 180 s after boot when `multi-user.target` is active.
5. Reboot without confirm: `h96ks/cur` already names previous generation; guard records `reverted` and clears
   trial. Trial generation stays for retry or `prune`.

`rollback` after confirm returns `h96ks/cur` to previous generation through same `commit` record; second
`rollback` returns to confirmed generation. Previous generation is not guarded, since it booted and was default
before.

## Files written

Only `try`, `confirm`, `rollback`, `prune`, `dtb-plain` and boot guard write `/boot`, and only these names:

| Name | Written by |
|------|------------|
| `h96ks/<krel>.g<n>/Image`, `uInitrd`, `fdt` | `try` (hidden temporary directory, read-back, rename) |
| `h96ks/<previous krel>.g<n>/` | `try`, on layout conversion: hard links to current Image and uInitrd, DTB copy |
| `h96ks/cur` | `try`, guard, `confirm`, `rollback` (atomic link swap) |
| `Image`, `uInitrd` | `try`, once: plain-name link becomes `h96ks/cur/...` link, content unchanged |
| `dtb/<fdtfile>` | `try`, once, only when DTB differs: plain file becomes link to `h96ks/cur/fdt`, content unchanged |
| `dtb/<fdtfile>` | `dtb-plain`: link becomes plain file (temporary name, read-back, rename), content unchanged |

Plain-name files (`Image-<krel>`, `uInitrd-<krel>`) are never replaced; only `prune` removes them or
generations. `extlinux`, `boot.scr`, `boot.cmd` and `armbianEnv.txt` are never written. Tool never runs
`update-initramfs`, `u-boot-update` or `flash-kernel`. Each step syncs file and directory.

## Refusals

`try` stops before any `/boot` write when:

- trial or unfinished confirm is already recorded;
- `h96-undervolt` trial is recorded (`/var/lib/h96-undervolt-trial`);
- DTB would change while `h96-undervolt` change is active (`/var/lib/h96-undervolt-state`), unless `--keep-dtb`;
- kernel is not staged, staged sums fail, or `modules.dep` is missing;
- staged Image embeds other release than requested;
- kernel is running or already default, or current Image embeds requested release;
- `/boot/Image` or `/boot/uInitrd` is not link to plain name or `h96ks/cur`, or names missing file;
- `/boot/extlinux`, `/boot/boot/extlinux` or `/extlinux` exists (U-Boot reads it before `boot.scr`);
- `/boot` is not mounted or is read-only;
- staged DTB is missing (unless `--keep-dtb`);
- `/boot` free space is below size of files to write plus 16 MiB reserve.

`rollback` after confirm refuses while board DTB is plain file that differs from DTB of previous generation
(after `dtb-plain`), unless `--keep-dtb`: rollback switches Image and uInitrd only, so old kernel would boot
newer DTB. `dtb-plain` refuses while trial is recorded and when DTB is not managed link.

`prune` refuses running kernel and any generation or file named by `h96ks/cur`, boot links, trial record or last
confirm. Package removal is refused while trial is recorded.

## Power loss

Record comes before every link move; one rename decides boot set; guard finishes or reverts on next boot:

| Interrupted in | Next boot |
|----------------|-----------|
| layout conversion | Each boot name still resolves to previous content; next `try` continues conversion |
| generation write | Previous set; hidden temporary directory removed |
| after `armed` record, before `h96ks/cur` moves | Previous kernel; guard records `not-booted`, clears record |
| guard, before fallback | Trial kernel boots second time; guard reverts as unconfirmed |
| confirm or rollback (`commit` record) | Guard completes switch; record cleared, last-confirm written |
| `dtb-plain` | DTB link or plain copy, same content; hidden temporary file removed by next `dtb-plain` or `try` |

Unfinished `commit` found by `rollback` in running system (killed process): `rollback` refuses and names
`h96-kernel-switch guard`, which completes it.

## DTB handling: owner decision

Current behaviour: DTB joins generation switch when staged DTB differs from board DTB; first such `try` turns
`dtb/<fdtfile>` into link to `h96ks/cur/fdt`. Kernel and DTB then always change together. Cost: link inside
`dtb/rockchip/` (relative path with `..` parts) relies on U-Boot link handling not yet booted on this board.

Alternative: `--keep-dtb` on every `try`. `dtb/<fdtfile>` stays plain file and is never written; only Image and
uInitrd switch. Cost: new kernel boots with old DTB, so DTB changes (8.0 overlay result, for example) need
separate step outside tool.

Both paths are in tool now; default stays first one until owner bench decides. Identical DTB needs no link in
either case. `dtb-plain` returns managed layout to plain DTB file; later `try` with `--keep-dtb` keeps it plain.

## h96-undervolt

`h96-undervolt` (package `h96-tools`) edits CPU voltage tables in
`/boot/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb` and keeps vendor copy as `<dtb>.stock-backup`;
`h96-undervolt-trial.service` copies stock backup back after unconfirmed trial boot. Once that DTB name links to
`h96ks/cur/fdt`, in-place write would land inside generation (generations never change) and stock backup would hold
DTB of earlier kernel.

Rules, enforced by both tools:

| Situation | `h96-undervolt` | `h96-kernel-switch` |
|-----------|-----------------|---------------------|
| DTB is managed link (`dtb` prints `layout=managed`) | `set`, `oc`, `revert` refuse; trial guard writes nothing | normal |
| Kernel trial recorded | `set`, `oc` refuse; `revert` allowed (plain DTB only) | normal |
| Undervolt trial recorded | normal | `try` refuses |
| Undervolt or overclock active | normal | `try` refuses DTB change; `--keep-dtb` accepted |
| DTB differs from stock backup, no undervolt change recorded | `set`, `oc` refuse; `revert` needs `--force` | normal |

`h96-undervolt` asks `h96-kernel-switch dtb` (read only) and also refuses any DTB that is link. It writes DTB and
stock backup through temporary name and rename; trial guard does same and is ordered after
`h96-kernel-switch-guard.service`. Path back for undervolt on managed layout: `h96-kernel-switch dtb-plain`, remove
stale `.stock-backup` once current DTB is vendor tree, then `h96-undervolt set`.

Design choice. Three designs were compared:

1. Kernel switch writes undervolt DTB as new generation: undervolt trial and kernel trial would share `h96ks/cur`,
   records and boot guard; undervolt revert after kernel switch would need DTB per generation. Boot-critical tool
   grows second trial type with its own power-loss cases. Rejected.
2. `--keep-dtb` as default: DTB stays plain file and undervolt works unchanged, but kernel and DTB no longer change
   together by default; new kernel boots earlier DTB, and stale stock backup after separate DTB update is not
   caught. Changes owner DTB decision. Rejected.
3. Each tool writes only own names; mutual refusal allows single boot trial; `dtb-plain` gives plain layout
   back on request. No generation is ever written by `h96-undervolt`, and no undervolt file by kernel switch.
   Chosen: smallest change to both tools, every conflicting state ends in refusal with next step named.

## Limits

- Failure before boot guard runs (early panic, initramfs failure, root not mounted) repeats trial boot, because
  `h96ks/cur` still names trial generation at that point. Watchdog reset then loops on trial kernel; recovery
  needs rescue media or reflash. Bench test with owner present is required before release.
- Trial and previous kernel need different release strings; `try` refuses running release and Image that embeds
  requested release.
- Links with directory parts in `/boot` have not booted on hardware yet.
- `systemctl preset-all` between `try` and reboot disables guard; trial then boots without fallback. Run `try`
  again after `rollback`, or `systemctl enable h96-kernel-switch-guard.service`, before rebooting.
- Purge of `h96-kernel-switch` leaves `h96ks` layout in place; links stay valid.

## Tests

`tools/kernel-switch/test-kernel-switch.sh` runs tool in stub root with stub `mkinitramfs` and `mkimage`.
Boot result comes from all three files read through links (Image, uInitrd, DTB): old set, new set, or mixed,
and mixed fails. Cases: listing, `default`, `in-use`, refusals including embedded release, low space, healthy
trial and confirm, unconfirmed revert, generation reuse and cleanup, auto-confirm with and without health,
rollback in each state, `--keep-dtb`, identical DTB, DTB changed outside tool, `dtb` as directory link, prune,
unreadable record, `dtb` output, `dtb-plain` (refusals, generations unchanged, rollback with plain DTB),
refusals on `h96-undervolt` trial and change files. Power loss runs at every cut point that `try`,
`try --keep-dtb`, guard, `confirm`, `rollback` and `dtb-plain` reach (list collected from tool trace), then boots until no record is left. Each case checks
`boot.scr`, `boot.cmd` and `armbianEnv.txt` sums, absence of `extlinux` and absence of temporary files.

```
tools/kernel-switch/test-kernel-switch.sh
build/build-kernel-switch-deb.sh out
```
