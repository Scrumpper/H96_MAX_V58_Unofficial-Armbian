#!/bin/bash
# Stage 4 repo (laptop): offline repo for Debian edition. Download closure in prepped rootfs (repo-in/repo-dl.sh),
# provenance against signed Debian/Armbian lists, carried debs (h96 WirePlumber rebuild, Rockchip MPP/RGA, box64/box86
# from v7.2 repo, sha checked against pinned v7.2 index), flat index, signed with offline-repo key (repo-sign.py; no key: published signatures).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd); . "$H/../env.sh"
EV=$EVR/repo; mkdir -p "$EV"
V72PKG=$IN/v72-opt-h96-pkgs.Packages; V72PKGSHA=$(pin v72-opt-h96-pkgs.Packages)
[ "$(sha256sum < "$V72" | cut -d' ' -f1)" = "$V72SHA" ] && [ "$(sha256sum < "$V72PKG" | cut -d' ' -f1)" = "$V72PKGSHA" ] || { echo "v7.2 pins"; exit 1; }
[ "$(sha256sum < "$W/prep-rootfs.tar.zst" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$EVR/prep/prep-tarball.sha256")" ] || { echo "prep tarball sha"; exit 1; }
RI=$W/repo-in; rm -rf "$RI"; mkdir -p "$RI/local" "$RI/carry"; cp -p "$H/repo-in/repo-dl.sh" "$RI/"
cp "$H/repo-wanted.txt" "$H/repo-mesa.txt" "$RI/"
dpkg-deb --fsys-tarfile "$IN"/debs/h96-base_*.deb | tar -xOf - ./etc/apt/preferences.d/01-h96-protect-mesa > "$RI/01-h96-protect-mesa"
# carried: v7.2 repo Rockchip + box debs (sha = pinned v7.2 index), h96 WirePlumber trixie rebuild (sha = wp/out/SHA256SUMS)
CARRY="librga2_2.2.0-1_arm64.deb librockchip-mpp1_1.5.0-1_arm64.deb librockchip-vpu0_1.5.0-1_arm64.deb libv4l-rkmpp_1.7.0-1_arm64.deb rockchip-mpp-demos_1.5.0-1_arm64.deb box64-rk3588_0.4.3+20260703.0c3d239-1_arm64.deb box86-rk3588_0.3.9+20260108.0579f8b-1_armhf.deb"
mapfile -t CM < <(for f in $CARRY; do echo "./opt/h96-pkgs/$f"; done)
tar --zstd -xf "$V72" -C "$RI/carry" --strip-components=3 "${CM[@]}"
for f in $CARRY; do
  want=$(awk -v f="./$f" '$1=="Filename:"&&$2==f{x=1} x&&$1=="SHA256:"{print $2; exit}' "$V72PKG")
  [ -n "$want" ] && [ "$(sha256sum < "$RI/carry/$f" | cut -d' ' -f1)" = "$want" ] || { echo "carry $f sha vs v7.2 index"; exit 1; }
done
for f in wireplumber_0.5.18-1~h96.1+deb13.1_arm64.deb libwireplumber-0.5-0_0.5.18-1~h96.1+deb13.1_arm64.deb; do
  [ "$(sha256sum < "$IN/debs/$f" | cut -d' ' -f1)" = "$(pin "debs/$f")" ] || { echo "$f sha vs pins"; exit 1; }; cp -p "$IN/debs/$f" "$RI/carry/"; done
echo "PASS carried debs: $(ls "$RI/carry" | wc -l) (sha against v7.2 index and pins)"
# closure inputs: carried debs plus every image input deb, so their missing Depends land in the repo
cp -p "$RI"/carry/*.deb "$IN"/debs/h96-*.deb "$IN"/debs/steam-arm-setup_3.0_arm64.deb "$RI/local/"
R=$W/rootfs-repo
[ -e "$R" ] && podman unshare rm -rf "$R"
mkdir -p "$R"
podman unshare tar --zstd --numeric-owner --xattrs --xattrs-include='*' -xpf "$W/prep-rootfs.tar.zst" -C "$R"
rc=0; bash "$H/chroot-run.sh" "$R" "$RI" repo-dl.sh "$EV/repo-dl-run.txt" --net || rc=$?
cat "$EV/repo-dl-run.txt"
podman unshare rm -rf "$EV/log"; rm -rf "$W/repo-dl"; mkdir -p "$EV/log" "$W/repo-dl"
podman unshare sh -c 'cp -a "$1/root/f5-log/repo/." "$2/"; cp -a "$1"/root/repo-dl/*.deb "$3/"' _ "$R" "$EV/log" "$W/repo-dl"
podman unshare rm -rf "$R"
[ "$rc" = 0 ] || exit "$rc"
bash "$H/repo-index.sh"
