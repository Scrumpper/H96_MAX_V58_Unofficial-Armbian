#!/bin/bash
# T8 (laptop part): highest GLIBC symbol version needed by every ELF in Debian userland debs, video stack tarball,
# kernel switch and carried Rockchip/box64 debs; trixie glibc is 2.41. Host objdump, nothing executed.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; x=$(mktemp -d); rc=0
for d in "$IN"/debs/h96-*.deb "$W"/repo-in/carry/*_arm64.deb; do dpkg-deb -x "$d" "$x/$(basename "$d" .deb)"; done
mkdir -p "$x/stack"; tar xzf "$IN/video/h96-video-stack.tar.gz" -C "$x/stack"
while IFS= read -r -d '' f; do
  head -c4 "$f" | grep -q $'\x7fELF' || continue
  g=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
  echo "${g:-none} ${f#"$x"/}"
  [ -z "$g" ] || [ "$(printf '%s\n%s\n' "$g" GLIBC_2.41 | sort -V | tail -1)" = GLIBC_2.41 ] || rc=1
done < <(find "$x" -type f -print0) | sort
rm -rf "$x"; exit $rc
