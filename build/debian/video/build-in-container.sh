#!/bin/bash
# Runs inside amd64 trixie container: Debian multiarch cross build (gcc aarch64-linux-gnu) of ffmpeg-rockchip 40c412d
# (static) and mpv v0.41.0 with v7.1 patches and pipewire + pulse AO (as Ubuntu r18), against trixie arm64 dev packages.
# Mounts: /src (source tarballs, read only), /w (this folder: patches, out/). Build tree /b maps to /build in binaries.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
J=${JOBS:-6}
cat > /etc/apt/sources.list.d/debian.sources <<'S'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates trixie-backports
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
S
dpkg --add-architecture arm64
apt-get update -q
apt-get install -y -q --no-install-recommends crossbuild-essential-arm64 meson ninja-build pkgconf python3 make patch \
  ca-certificates file binutils-aarch64-linux-gnu
apt-get install -y -q --no-install-recommends libc6-dev:arm64 libdrm-dev:arm64 libdisplay-info-dev:arm64 \
  libgnutls28-dev:arm64 zlib1g-dev:arm64 libbz2-dev:arm64 libasound2-dev:arm64 libass-dev:arm64 libplacebo-dev:arm64 \
  liblcms2-dev:arm64 libluajit-5.1-dev:arm64 libx11-dev:arm64 libxext-dev:arm64 libxv-dev:arm64 libxss-dev:arm64 \
  libxpresent-dev:arm64 libxrandr-dev:arm64 libxfixes-dev:arm64 libxkbcommon-dev:arm64 libwayland-dev:arm64 \
  wayland-protocols libegl-dev:arm64 libgl-dev:arm64 libvulkan-dev:arm64 libxcb1-dev:arm64 libdav1d-dev:arm64 \
  libgbm-dev:arm64 libstdc++6:arm64 libpipewire-0.3-dev:arm64 libpulse-dev:arm64
apt-get install -y -q --no-install-recommends libwayland-bin
dpkg-query -W -f '${Package}:${Architecture} ${Version}\n' libplacebo-dev libdisplay-info-dev libdav1d-dev libgbm-dev libc6-dev libluajit-5.1-dev libpipewire-0.3-dev libpulse-dev | sort
L=/usr/lib/aarch64-linux-gnu
rm -rf /b && mkdir -p /b/sys /b/build && cd /b/build
mkdir ffmpeg mpv mpp librga
tar xzf /src/ffmpeg-40c412d.tar.gz -C ffmpeg --strip-components=1
tar xzf /src/mpv-0.41.0.tar.gz -C mpv --strip-components=1
tar xzf /src/mpp-48962a10.tar.gz -C mpp --strip-components=1
tar xzf /src/librga-75af4dd.tar.gz -C librga --strip-components=1
# MPP/RGA headers from pinned commits, runtime libs from the v7.0/v7.1 stack (Rockchip builds, GLIBC 2.38 max)
mkdir -p /usr/include/rockchip /usr/include/rga /b/stack
cp mpp/inc/*.h /usr/include/rockchip/; cp -r librga/include/* /usr/include/rga/
tar xzf /w/ubuntu-stack.tar.gz -C /b/stack
cp -a /b/stack/usr/lib/aarch64-linux-gnu/librockchip_mpp.so* /b/stack/usr/lib/aarch64-linux-gnu/librga.so* $L/
ln -sfn librga.so.2 $L/librga.so
cat > $L/pkgconfig/rockchip_mpp.pc <<'P'
prefix=/usr
libdir=${prefix}/lib/aarch64-linux-gnu
includedir=${prefix}/include
Name: rockchip_mpp
Description: Rockchip Media Process Platform (headers 48962a10)
Version: 1.3.9
Libs: -L${libdir} -lrockchip_mpp
Cflags: -I${includedir}/rockchip
P
cat > $L/pkgconfig/librga.pc <<'P'
prefix=/usr
libdir=${prefix}/lib/aarch64-linux-gnu
includedir=${prefix}/include
Name: librga
Description: Rockchip RGA (headers 75af4dd)
Version: 1.10.1
Libs: -L${libdir} -lrga
Cflags: -I${includedir} -I${includedir}/rga
P
export PKG_CONFIG_LIBDIR=$L/pkgconfig:/usr/share/pkgconfig PKG_CONFIG=aarch64-linux-gnu-pkg-config
PFX="-ffile-prefix-map=/b=/build"
cd /b/build/ffmpeg
echo 40c412dacc > VERSION
./configure --prefix=/usr --enable-cross-compile --arch=aarch64 --target-os=linux --cross-prefix=aarch64-linux-gnu- \
  --pkg-config=aarch64-linux-gnu-pkg-config --extra-cflags="$PFX" \
  --enable-gpl --enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --enable-gnutls \
  --disable-vulkan --enable-protocol='https,http,tls,tcp,hls,crypto' --enable-libdav1d --disable-cuda-llvm --disable-doc \
  > /w/out/ffmpeg-configure.log 2>&1 || { tail -30 ffbuild/config.log; exit 1; }
sed -n '/^External libraries:/,/^$/p;/^External libraries providing hardware acceleration:/,/^$/p' /w/out/ffmpeg-configure.log
make -j"$J" > /w/out/ffmpeg-make.log 2>&1 || { tail -40 /w/out/ffmpeg-make.log; exit 1; }
rm -rf /b/stage-ff; make install DESTDIR=/b/stage-ff >> /w/out/ffmpeg-make.log 2>&1
aarch64-linux-gnu-strip /b/stage-ff/usr/bin/ffmpeg /b/stage-ff/usr/bin/ffprobe
echo FFMPEG_OK
FF=/opt/ffh96; rm -rf $FF; mkdir -p $FF/lib
cp -a /b/stage-ff/usr/include $FF/; cp -a /b/stage-ff/usr/lib/*.a /b/stage-ff/usr/lib/pkgconfig $FF/lib/
python3 - "$FF/lib/pkgconfig" "$FF" <<'PY'
import sys, glob, re
for p in glob.glob(sys.argv[1] + "/*.pc"):
    t = open(p).read()
    t = re.sub(r"^prefix=.*$", "prefix=" + sys.argv[2], t, count=1, flags=re.M)
    t = re.sub(r"^libdir=.*$", "libdir=${prefix}/lib", t, count=1, flags=re.M)
    t = re.sub(r"^includedir=.*$", "includedir=${prefix}/include", t, count=1, flags=re.M)
    lp = re.search(r"^Libs\.private:(.*)$", t, re.M)
    rp = re.search(r"^Requires\.private:(.*)$", t, re.M)
    if lp and lp.group(1).strip():
        t = re.sub(r"^(Libs:.*)$", lambda m: m.group(1) + " " + lp.group(1).strip(), t, count=1, flags=re.M)
        t = re.sub(r"^Libs\.private:.*$", "Libs.private:", t, flags=re.M)
    if rp and rp.group(1).strip():
        t = re.sub(r"^(Requires:.*)$", lambda m: (m.group(1) + ", " if m.group(1).split(":",1)[1].strip() else "Requires: ") + rp.group(1).strip(), t, count=1, flags=re.M)
        t = re.sub(r"^Requires\.private:.*$", "Requires.private:", t, flags=re.M)
    open(p, "w").write(t)
PY
mkdir -p /root/.local/share/meson/cross
cat > /root/.local/share/meson/cross/h96-aarch64 <<C
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'aarch64-linux-gnu-pkg-config'

[built-in options]
c_args = ['$PFX']
cpp_args = ['$PFX']

[properties]
needs_exe_wrapper = false
pkg_config_libdir = ['$FF/lib/pkgconfig', '$L/pkgconfig', '/usr/share/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
C
export PKG_CONFIG_LIBDIR=$FF/lib/pkgconfig:$L/pkgconfig:/usr/share/pkgconfig
cd /b/build/mpv
patch -p1 < /w/mpv-rkmpp-zerocopy-v71.patch
patch -p1 < /w/mpv-drm-hdr-overlay.patch
meson setup build --cross-file h96-aarch64 --prefix=/usr --libdir=lib/aarch64-linux-gnu --buildtype=release \
  -Dlibmpv=true -Dlua=luajit -Ddrm=enabled -Dgbm=enabled -Degl-drm=enabled -Dpipewire=enabled -Dpulse=enabled > /w/out/mpv-meson.log 2>&1 || { tail -40 /w/out/mpv-meson.log; exit 1; }
grep -m1 -A3 "Enabled features" /w/out/mpv-meson.log || true
ninja -C build -j"$J" > /w/out/mpv-ninja.log 2>&1 || { tail -40 /w/out/mpv-ninja.log; exit 1; }
rm -rf /b/stage-mpv; DESTDIR=/b/stage-mpv ninja -C build install >> /w/out/mpv-ninja.log 2>&1
aarch64-linux-gnu-strip /b/stage-mpv/usr/bin/mpv /b/stage-mpv/usr/lib/aarch64-linux-gnu/libmpv.so.*.*.*
echo MPV_OK
mkdir -p /w/out/stage
cp -a /b/stage-ff/usr/bin/ffmpeg /b/stage-ff/usr/bin/ffprobe /b/stage-mpv/usr/bin/mpv /b/stage-mpv/usr/lib/aarch64-linux-gnu/libmpv.so.2.5.0 /w/out/stage/
cd /w/out/stage
for f in *; do echo "$f GLIBC max $(aarch64-linux-gnu-objdump -T "$f" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1); NEEDED $(aarch64-linux-gnu-objdump -p "$f" | awk '/NEEDED/{print $2}' | xargs)"; done | tee /w/out/needed.txt
./mpv --version | tee /w/out/mpv-version.txt
./mpv --ao=help | tee /w/out/mpv-ao.txt
./ffmpeg -hide_banner -hwaccels | tee /w/out/ffmpeg-hwaccels.txt
./mpv --gpu-context=help | tee /w/out/mpv-gpu-context.txt
./mpv --vo=help | grep -E '^ +(drm|gpu)' | tee -a /w/out/mpv-gpu-context.txt
dpkg-query -W -f '${Package}:${Architecture} ${Version}\n' | grep ':arm64' | sort > /w/out/sysroot-arm64.txt
echo VIDEO_OK
