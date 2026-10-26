# Docs index

Docs for H96 Max V58 Unofficial Armbian sources. Release booklet (`README.md`, `FLASHING.md`,
`COMMANDS.md`, `CHANGELOG-v8.0.md`, `KERNEL-COMPARISON.md`) comes inside release zip on
[Releases page](https://github.com/Scrumpper/H96_MAX_V58_Unofficial-Armbian/releases).

## Build and verify

| Doc | Covers |
|---|---|
| [REPRODUCE.md](REPRODUCE.md) | Rebuild Ubuntu image, kernels and userland packages from pinned inputs; compare sha256 |
| [REPRODUCE-DEBIAN.md](REPRODUCE-DEBIAN.md) | Rebuild Debian Edition image |
| [DEBIAN-EDITION.md](DEBIAN-EDITION.md) | Debian Edition base, packages, offline repository, differences from Ubuntu image |
| [CI.md](CI.md) | CI jobs, gates, local run |

## Platform

| Doc | Covers |
|---|---|
| [KERNEL-SWITCH.md](KERNEL-SWITCH.md) | `h96-kernel-switch`: boot file layout, trial boot, rollback, refusals, power loss |
| [DEVICE-TREE-CHANGES.md](DEVICE-TREE-CHANGES.md) | Every device tree change against stock vendor DTB, overlay source and tree-diff gate |
| [ARMBIAN-8.0-PLAN.md](ARMBIAN-8.0-PLAN.md) | 8.0 planning document: scope, work packages, milestones (dated, not release note) |

## Features

| Doc | Covers |
|---|---|
| [BLUETOOTH-AUDIO.md](BLUETOOTH-AUDIO.md) | Bluetooth audio, headset microphone, codecs, manual install |
| [MEDIA-FEATURES.md](MEDIA-FEATURES.md) | Opt-in media suite and USB controllers |

Change history: [CHANGELOG.md](../CHANGELOG.md). Front page: [README.md](../README.md).
