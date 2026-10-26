#!/bin/bash
# Stage 5 dryrun (laptop, Debian edition): input pins, versions and maintainer, version ledger over Ubuntu and Debian
# outputs, deb content gates, Depends closure against prepped trixie status + offline repo, scripts (syntax,
# static analysis, boot-tool scan), stage/ written. Usage: dryrun.sh [--repin]
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"; ST=$W/stage; EV=$EVR; mkdir -p "$EV"
MAINT='Scrumpper <190908034+Scrumpper@users.noreply.github.com>'; DV=8.0.0~r39+deb13.1
K=6.12.69-h96v58-8.0; KF=6.1.172-h96v58-8.0
CHROOT="repo-apply.sh f5-chroot.sh stage-kernel.sh image-brand.sh final-check.sh image-clean.sh"
fail=0; warn=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }; wn() { echo "WARN $*"; warn=$((warn+1)); }
ctl() { dpkg-deb -f "$1" "$2"; }
bootsnap() { ls -la --time-style=full-iso /boot 2>/dev/null | md5sum | cut -d' ' -f1; }
b0=$(bootsnap)
pick() { local best="" bv="" f v; while IFS= read -r f; do case "$f" in *.deb) v=$(ctl "$f" Version) ;; *) v=0 ;; esac
  if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$bv"; then best=$f; bv=$v; fi; done < <(compgen -G "$IN/$1" || compgen -G "$H96_REPO/$1"); [ -n "$best" ] && echo "$best"; }
echo "== inputs"
declare -A SRC
while IFS=$'\t' read -r name glob; do case "$name" in ''|'#'*) continue ;; esac
  f=$(pick "$glob") || { bad "no source for $name ($glob)"; continue; }; SRC[$name]=$f; done < "$H/inputs.src"
if [ "${1:-}" = --repin ]; then
  for name in "${!SRC[@]}"; do echo "$(sha256sum < "${SRC[$name]}" | cut -d' ' -f1)  $(basename "${SRC[$name]}")"; done | sort -k2 > "$H/inputs.sha256"; echo "repinned $(wc -l < "$H/inputs.sha256")"
fi
n=0; for name in "${!SRC[@]}"; do b=$(basename "${SRC[$name]}"); s=$(awk -v b="$b" '$2==b{print $1}' "$H/inputs.sha256")
  [ -n "$s" ] && [ "$(sha256sum < "${SRC[$name]}" | cut -d' ' -f1)" = "$s" ] && n=$((n+1)) || bad "$b not pinned or sha differs"; done
[ "$(grep -c . "$H/inputs.sha256")" = "${#SRC[@]}" ] && ok "inputs pinned and matching: $n of ${#SRC[@]}" || bad "pin count"
# inputs.sha256 deb lines agree with pins file
while read -r s b; do case "$b" in *.deb) [ "$(pin "debs/$b")" = "$s" ] || bad "$b: inputs.sha256 differs from pins file" ;; esac; done < "$H/inputs.sha256"
echo "== debs"
for p in h96-base h96-boot h96-net h96-audio h96-desktop h96-media h96-tools h96-gaming; do f=${SRC[$p]}
  [ "$(ctl "$f" Version)" = "$DV" ] || bad "$p Version $(ctl "$f" Version)"; [ "$(ctl "$f" Maintainer)" = "$MAINT" ] || bad "$p Maintainer"
  case "$(basename "$f")" in *"_${DV}_"*) ;; *) bad "$p file name" ;; esac
  dpkg-deb --fsys-tarfile "$f" | tar -xOf - "./usr/share/doc/$p/changelog.gz" | gzip -dc | head -1 | grep -q "($DV) trixie;" || bad "$p changelog head"
  echo "  $p $DV $(sha256sum < "$f" | cut -c1-16)"; done
ok "userland $DV, maintainer, changelog distribution trixie"
for p in h96-kernel h96-dtb; do [ "$(ctl "${SRC[$p]}" Package)" = "$p-$K" ] && [ "$(ctl "${SRC[$p-fallback]}" Package)" = "$p-$KF" ] || bad "$p package names"; done
[ "$(ctl "${SRC[h96-kernel]}" Version)" = 8.0.0~r23 ] && [ "$(ctl "${SRC[h96-dtb]}" Version)" = 8.0.0~r23 ] && [ "$(ctl "${SRC[h96-kernel-fallback]}" Version)" = 8.0.0~r11 ] && [ "$(ctl "${SRC[h96-dtb-fallback]}" Version)" = 8.0.0~r12 ] && [ "$(ctl "${SRC[h96-kernel-switch]}" Version)" = 8.0.0~r17 ] && ok "kernel 6.12 8.0.0~r23 default, 6.1 r11/DTB r12 fallback, kernel switch r17" || bad "kernel versions"
for p in h96-kernel h96-dtb h96-kernel-fallback h96-dtb-fallback; do [ "$(sha256sum < "${SRC[$p]}" | cut -d' ' -f1)" = "$(pin "debs/$(basename "${SRC[$p]}")")" ] && ok "$p deb = pins file" || bad "$p sha vs pins file"; done
x=$(mktemp -d); dpkg-deb -x "${SRC[h96-kernel]}" "$x"; [ "$(sha256sum < "$x/usr/lib/h96-kernel/$K/Image" | cut -c1-8)" = 95a659ab ] && ok "6.12 Image 95a659ab" || bad "6.12 Image sha"; rm -rf "$x"
x=$(mktemp -d); dpkg-deb -x "${SRC[h96-dtb]}" "$x"; [ "$(sha256sum < "$x/usr/lib/h96-kernel/$K/dtb/rockchip/rk3588-h96-max-v58-panthor.dtb" | cut -c1-8)" = 601c18fb ] && ok "6.12 DTB 601c18fb" || bad "6.12 DTB sha"; rm -rf "$x"
# steam-arm-setup: Steam ARM 3.1 deb = pins file
SAD=${SRC[steam-arm-setup]:-}
[ -n "$SAD" ] && [ "$(sha256sum < "$SAD" | cut -d' ' -f1)" = "$(pin "debs/$(basename "$SAD")")" ] && ok "steam-arm-setup $(basename "$SAD") = pins file" || bad "steam-arm-setup sha vs pins file"
echo "== version ledger (Ubuntu and Debian outputs: one file name, one content)"
led=$(mktemp)
# H96_DEB_LEDGER: optional file of "sha256  name" lines from earlier builds (one file name, one content)
for f in "$IN"/debs/*.deb; do echo "$(sha256sum < "$f" | cut -d' ' -f1)  $(basename "$f")"; done > "$led"
[ -n "${H96_DEB_LEDGER:-}" ] && grep '\.deb$' "$H96_DEB_LEDGER" >> "$led"
d=$(sort -u "$led" | awk '{c[$2]++; if (c[$2]==2) print $2}')
[ -z "$d" ] && ok "no deb name with two contents ($(sort -u "$led" | wc -l) known files)" || { for x in $d; do bad "version reused: $x"; done; }
rm -f "$led"
echo "== deb content"
x=$(mktemp -d); for p in h96-base h96-media h96-gaming h96-audio h96-desktop; do mkdir -p "$x/$p"; dpkg-deb -x "${SRC[$p]}" "$x/$p"; done
grep -qx H96_EDITION=debian "$x/h96-base/etc/h96-release" && grep -qx H96_RELEASE=v8.0 "$x/h96-base/etc/h96-release" && ok "h96-release v8.0, H96_EDITION=debian" || bad "h96-release"
grep -q 'Unofficial Port v8\.0 Debian Edition)' "$x/h96-base/usr/lib/h96/seed/h96-issue" && ok "issue seed Debian Edition" || bad "issue seed"
grep -q 'Pin: version 26.1.6-1~bpo13+1' "$x/h96-base/etc/apt/preferences.d/01-h96-protect-mesa" && ok "Mesa pin Debian stanza" || bad "Mesa pin"
grep -q 'MESA_VER="26.1.6-1~bpo13+1"' "$x/h96-gaming/usr/lib/h96/h96-gaming-setup.sh" && ok "gaming setup Debian MESA_VER" || bad "MESA_VER"
grep -q 'WANT=0.5.18-1~h96.1+deb13.1' "$x/h96-audio/usr/lib/h96/h96-wireplumber-offline.sh" && ok "WirePlumber offline WANT Debian" || bad "WP WANT"
tar xzf "$x/h96-media/usr/lib/h96/video/h96-video-stack.tar.gz" -C "$x" usr/bin/mpv
n=$(objdump -p "$x/usr/bin/mpv" | grep -cE 'NEEDED +(libplacebo\.so\.349|libpipewire-0\.3\.so\.0|libpulse\.so\.0)$')
[ "$(objdump -T "$x/usr/bin/mpv" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)" = GLIBC_2.38 ] && [ "$n" = 3 ] && ok "bundled mpv GLIBC 2.38, libplacebo 349, pipewire and pulse AO" || bad "bundled mpv"
[ "$(sha256sum < "$x/h96-media/usr/lib/h96/mpv-mpris/mpris.so" | cut -d' ' -f1)" = "$(pin video/mpris.so)" ] && ok "MPRIS plugin = trixie build (pins video/mpris.so)" || bad "MPRIS plugin"
grep -q '^#!/bin/bash' "$x/h96-base/usr/lib/armbian/armbian-firstlogin" && grep -q 'timeout 120s systemctl is-system-running' "$x/h96-base/usr/lib/armbian/armbian-firstlogin" && ok "firstlogin 26.8.3 + H96 line" || bad "firstlogin"
rm -rf "$x"
echo "== Depends closure (prepped trixie status + offline repo)"
tb=$(mktemp -d); tar --zstd -xf "$W/prep-rootfs.tar.zst" -C "$tb" ./var/lib/dpkg/status
[ "$(sha256sum < "$W/prep-rootfs.tar.zst" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$EV/prep/prep-tarball.sha256")" ] && ok "prep tarball sha" || bad "prep tarball sha"
(cd "$W/repo" && sha256sum -c --quiet "$EV/repo/index.sha256") && ok "offline repo index = evidence/repo/index.sha256" || bad "repo index sha"
gpgv --keyring "$KEYRING" "$W/repo/InRelease" 2>&1 | grep -q 'Good signature' && ok "offline repo InRelease gpgv" || bad "repo gpgv"
dl=(); for p in h96-base h96-boot h96-net h96-audio h96-desktop h96-media h96-tools h96-gaming steam-arm-setup h96-kernel h96-dtb h96-kernel-fallback h96-dtb-fallback h96-kernel-switch; do [ -n "${SRC[$p]:-}" ] && dl+=("${SRC[$p]}"); done
out=$(python3 -I "$H/repo-closure.py" "$tb/var/lib/dpkg/status" "$W/repo/Packages" --deb "${dl[@]}") && ok "input Depends resolvable${out:+; F5 preinstalls: $(echo "$out" | xargs)}" || { echo "$out"; bad "unresolved Depends"; }
for w in $(grep -v '^#' "$H/repo-wanted.txt") $(cat "$H/repo-mesa.txt") wireplumber libwireplumber-0.5-0 librockchip-mpp1 libv4l-rkmpp box64-rk3588; do
  python3 -I "$H/repo-closure.py" "$tb/var/lib/dpkg/status" "$W/repo/Packages" --want "$w" > /dev/null || bad "offline set: $w not installable from base + repo"
done; ok "offline set installable from base + repo"
rm -rf "$tb"
echo "== scripts"
for s in $CHROOT; do bash -n "$H/chroot/$s" || bad "bash -n $s"; done
for s in "$H"/*.sh "$H"/prep-in/*.sh "$H"/repo-in/*.sh; do bash -n "$s" || bad "bash -n $s"; done
for s in "$H"/*.py; do python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$s" || bad "parse $s"; done
(cd "$H" && shellcheck -S warning -e SC1090,SC1091 ./*.sh chroot/*.sh prep-in/*.sh repo-in/*.sh) > "$EV/shellcheck.txt" 2>&1 && ok "shellcheck -S warning clean" || bad "shellcheck: $(grep -c '^In ' "$EV/shellcheck.txt") findings"
out=$({ grep -nE '(^|[;&|[:space:](])(update-initramfs|u-boot-update|flash-kernel)([[:space:]);]|$)' "$H"/chroot/*.sh "$H"/prep-in/*.sh; grep -n 'extlinux' "$H"/chroot/*.sh | grep -v '! -e /boot/extlinux\|no /boot/extlinux\|/boot/extlinux exists\|"/boot/extlinux"'; } | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -z "$out" ] && ok "no update-initramfs, u-boot-update, flash-kernel or extlinux writes" || { echo "$out"; bad "boot tool call"; }
bash -n "${SRC[f5-rows-debian.sh]}" && ok "f5-rows-debian.sh syntax ($(grep -c '^row ' "${SRC[f5-rows-debian.sh]}") rows)" || bad "rows syntax"
echo "== stage"
rm -rf "$ST"; mkdir -p "$ST"
for name in "${!SRC[@]}"; do cp -p "${SRC[$name]}" "$ST/"; done
for s in $CHROOT; do cp -p "$H/chroot/$s" "$ST/"; done
cp -p "$H/repo-closure.py" "$H/inputs.sha256" "$ST/"
cp -p "$KEYRING" "$ST/h96-local-archive-keyring.gpg"
echo "$K" > "$ST/krel"; echo "$KF" > "$ST/krel-fallback"
mkdir -p "$ST/repo"; cp -p "$W"/repo/* "$ST/repo/"; cp -p "$EV/repo/index.sha256" "$ST/repo/"
find "$ST" -path '*gnupg*' -o -name '*.key' -o -name 'secring*' | grep -q . && bad "key material in stage" || ok "no key material in stage"
(cd "$ST" && sha256sum $CHROOT repo-closure.py krel krel-fallback h96-local-archive-keyring.gpg > scripts.sha256 && sha256sum -c --quiet inputs.sha256) && ok "stage inputs match pins" || bad "stage inputs"
du -sh "$ST" | sed 's/^/  stage size /'
[ "$(bootsnap)" = "$b0" ] && ok "laptop /boot listing unchanged" || bad "laptop /boot listing changed"
echo "dryrun fail=$fail warn=$warn"
[ "$fail" = 0 ] && sha256sum "$H/inputs.sha256" "$ST/scripts.sha256" > "$ST/DRYRUN-OK"
[ "$fail" = 0 ]
