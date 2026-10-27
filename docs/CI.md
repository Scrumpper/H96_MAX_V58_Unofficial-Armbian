# CI workflow

Workflow file: `.github/workflows/ci.yml`. Runs on push to `main` and `armbian-*` branches, on every pull request and on manual dispatch. All jobs use GitHub-hosted arm64 runners (`ubuntu-24.04-arm`). Workflow token is read-only (`contents: read`). It holds no secrets and runs no release step, push or tag. Outputs go to workflow run artifacts only.

## Jobs

| Job | Gate | Script it calls | Fails when |
|-----|------|-----------------|------------|
| `docs` | Style rules | `tools/docs/check-docs.py` | Any style issue in tracked `*.md`; build round label `~rN` passes only in package `Version:` field |
| `docs` | Article pass | `tools/docs/strip-articles.py --check` | Any article left in prose, or dangling internal link |
| `docs` | Alliteration | `tools/docs/check-alliteration.py` | Three words sharing initial letter inside four-word window of one sentence, outside code and tables; names listed in `tools/docs/alliteration-allow.txt` pass. Same script flags repeated openers (same first word on neighbouring bullets, sentences or clauses) and determiner slogans such as "one" or "nothing" plus noun; names in `tools/docs/openers-allow.txt` pass |
| `docs` | Privacy grep | Built-in generic regex, allowlist `.github/privacy-allow.txt` | LAN address, home path or webmail address in tracked text, other than allowlisted test vectors |
| `lint` | Shell lint | `shellcheck -S error` over `*.sh` and files with sh/bash shebang | Any error-level finding (warnings printed, not gating) |
| `lint` | Python syntax | `python3 -m py_compile` over `*.py` and files with python shebang | Any syntax error |
| `lint` | Self-tests | `tools/h96-selftest.py self-test`, plus `tests/` (unit test of `check-alliteration.py`) | Any failed check |
| `kit-oldest-python` | Backup kit syntax | `compile()` under Python 3.7 over `h96-backup*`, `h96-restore*` and `h96-migrate-kit/` Python files | Any syntax error on oldest supported interpreter, or no kit files present |
| `debs` | Packaging PII | Generic regex over `build/` and `tools/ci/` | LAN address or home path |
| `debs` | Deb build | `tools/ci/kernel-debs-smoke.sh` driving `build/build-kernel-debs.sh` | Builder exit status nonzero |
| `debs` | Lintian | `lintian --fail-on error,warning` over both built debs, no suppressed tags | Any error or warning tag |
| `dtb` | Overlay compile | `dtc -@` over `patch/dt/h96-max-v58.dtso` and every overlay `.dts` | Any compile error, or malformed `h96-max-v58.delete` line |
| `dtb` | Tree diff | `tools/dtb/build-dtb.sh` on pinned base DTB, then `tools/dtb/dt-tree-diff.sh` against pinned reference DTB | Pinned checksum mismatch, or residual difference beyond phandle renumbering and allowed lines |

Jobs `docs`, `lint`, `debs` and `dtb` run inside `ubuntu:26.04` container on arm64 runner, so Python, shellcheck, dtc, dpkg and lintian match image userland (Ubuntu 26.04). Job `kit-oldest-python` runs inside `python:3.7-slim`: backups from v5.0.1 onward must restore, and 3.7 is kit interpreter floor.

## Deb packaging smoke test

Kernel binaries are pinned build outputs, not CI products, and are not in this repository. `tools/ci/kernel-debs-smoke.sh` feeds `build/build-kernel-debs.sh` placeholder inputs (text Image, one-line System.map, config whose `CONFIG_LOCALVERSION` agrees, modules tarball with one placeholder file, board overlay compiled as DTB stand-in) with `PIN=0` and version `0~ci`, so placeholder debs never carry release version. Resulting `h96-kernel-*` and `h96-dtb-*` debs exercise package layout, control fields, maintainer scripts and lintian; they are not installable kernels. Builder declines root, so job runs it as `nobody`.

Lintian runs with no suppressed tags and no override files. Modules install under `/usr/lib/modules` (`MODPREFIX` default), so `aliased-location` does not fire. Package version is native (no Debian revision), so changelog is `changelog.gz` and `initial-upload-closes-no-bugs` does not fire.

## DTB tree diff

Tree diff reads `dtb/pinned/rk3588-h96-max-v58.dtb` (vendor base), `dtb/pinned/rk3588-h96-max-v58-panthor.dtb` (published v7.2 reference) and `dtb/pinned/SHA256SUMS`, all committed. Workflow `env` sets `H96_CI_STRICT: "1"`, so absent pinned inputs or checksum mismatch fail job. With `H96_CI_STRICT: "0"`, absent inputs print `::notice::` and skip tree diff; overlay compile step runs either way.

## Artifacts

| Name | Content | Retention |
|------|---------|-----------|
| `kernel-debs-smoke` | Placeholder-input debs and `SHA256SUMS` from `out/debs/` | 14 days |
| `dtb-tree-diff` | Compiled overlays, and with pinned inputs present, built DTB, decompiled trees and diff from `out/dtb/` | 14 days |

## Out of scope

Kernel build, image build, userland deb build, chroot install test, signing, release assets, tags.

## Local run

Each `run:` block is plain bash, run from top of repository with `bash -eo pipefail`. Blocks call `apt-get` as root, since jobs run as root inside containers; outside container, remove those lines (tools must already be installed). Steps named `safe directory` write `safe.directory` into global git config; for local run, first point `GIT_CONFIG_GLOBAL` at temporary file. Closest local equivalent: run each job inside `ubuntu:26.04` container with repository mounted.
