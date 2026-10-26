#!/usr/bin/env bash
# Prepares kernel source tree: vendor base commit + H96 patch series, checked by git tree id, exported without .git.
# Usage: source.sh <6.12|6.1> <ksrc>   (env KGIT: vendor repo URL or local clone, default armbian/linux-rockchip)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VER="${1:?6.12 or 6.1}"
KSRC="${2:?ksrc}"
KGIT="${KGIT:-https://github.com/armbian/linux-rockchip}"

case "$VER" in
6.12) BASE=fa8a79f7d8f35ee81b8e52d9d2d7902213449a1f; TREE=a2338c0b7acdd6adb29b3c8b365de15675bce311 ;;
6.1)  BASE=44bbd021d7808cab93d1f2d64c1f092038257576; TREE=0da5b96600efd935cad572f63d1b9baf7133dc2d ;;
*) echo "version must be 6.12 or 6.1" >&2; exit 1 ;;
esac
PATCHES="$REPO/patch/kernel-$VER"

# kbuild needs a path without spaces; tree is exported, so KSRC must be new or empty
case "$KSRC" in *" "*) echo "kbuild needs a source path without spaces" >&2; exit 1;; esac
[ ! -e "$KSRC" ] || [ -z "$(ls -A "$KSRC")" ] || { echo "$KSRC not empty" >&2; exit 1; }
(cd "$PATCHES" && sha256sum -c --quiet SHA256SUMS)

G="$(mktemp -d)"
trap 'rm -rf "$G"' EXIT
git -C "$G" init -q
git -C "$G" fetch -q --depth=1 "$KGIT" "$BASE"
git -C "$G" -c advice.detachedHead=false checkout -q FETCH_HEAD
# committer identity does not enter the tree id
git -C "$G" -c user.name=builder -c user.email=builder@h96-build am -q "$PATCHES"/*.patch
got="$(git -C "$G" rev-parse 'HEAD^{tree}')"
[ "$got" = "$TREE" ] || { echo "tree $got != $TREE" >&2; exit 1; }
echo "tree ok $TREE"
mkdir -p "$KSRC"
git -C "$G" archive HEAD | tar -x -C "$KSRC"
