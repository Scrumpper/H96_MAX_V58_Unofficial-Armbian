#!/bin/bash
# h96-steam-fex-install: install x86-64 Steam on the H96 Max V58 (RK3588 Armbian) through
# FEX-Emu, with games rendering on the Mali GPU and the Steam client on the KDE desktop.
#
# Steam is an x86 program. FEX-Emu runs it with a matching x86-64 RootFS and forwards its
# OpenGL, Vulkan and X11 calls to the native libraries, so games use the Mali GPU. The client
# UI (steamwebhelper, a Chromium build) is software rendered; H96-STEAM-FEX-RECIPE.md records
# the GPU client experiments. The installer builds the RootFS, installs Steam into it through
# an isolated chroot (never through FEXBash, whose writes reach the host), replaces the x86
# bubblewrap with the native one so the Steam Linux Runtime container starts, patches libX11
# so X protocol errors are not fatal, and keeps the webhelper's network service inside its
# browser process so the client's transport check passes and no error dialog appears.
#
# Run as root on the box:  sudo bash h96-steam-fex-install.sh
# Then launch Steam:       steam-fex   (ensures /dev/shm, then runs as the game user)
# Without a desktop session Steam runs headless inside gamescope.
#
# Components: the core (RootFS, Steam, native bwrap, libX11 patch, webhelper flag, launcher)
# is always installed. The rest is selectable. On a terminal a checklist is shown; otherwise
# the defaults apply. Options:
#   --defaults            no checklist, install the default selection
#   --select a,b,c        install exactly these optional components, no checklist
#   --skip a,b            defaults minus these, no checklist
#   --list                print the optional components and exit
# Optional components (all on by default):
#   glx-lax     private Mesa GLX copy for titles that bind one GL context from several threads
#   vk-spoof    host Vulkan layer that reports features DXVK requires but the Mali driver lacks
#   map-count   raise vm.max_map_count to the SteamOS value
#   multiblock  FEX multi-block JIT (measured gain under emulation)
#   big-cores   pin the client, container and games to the A76 cores
#   xpad-dedup  drop the duplicate joystick node of third-party Xbox 360 style pads
#   pad-hidraw  let the client read pads directly, for rumble and battery level
#   pad-xbox    present XInput pads from other makers as Xbox 360 pads (off by default)
#   desktop     application menu entry, desktop icon and passwordless steam-fex for the user
# A component that is deselected on a re-run is removed again. DEFAULT_OFF in the environment
# names components that are off unless asked for (pad-xbox here).
#
# Idempotent: re-running rebuilds the launcher and re-applies every fix. Experimental: not
# part of the shipped image.
#
# This project is not affiliated with, endorsed by or sponsored by Valve Corporation.
# Steam, Proton and Steam Deck are trademarks of Valve Corporation.
set -u
[ -r /usr/local/lib/h96/banner.sh ] && . /usr/local/lib/h96/banner.sh
command -v h96_banner >/dev/null 2>&1 || h96_banner() { :; }

# GAMEUSER: uid 1000 account, or $GAMEUSER; created (with a generated, printed password) if none exists.
GAMEUSER="${GAMEUSER:-$(getent passwd 1000 2>/dev/null | cut -d: -f1)}"
GAMEUSER="${GAMEUSER:-h96steam}"
GAMEPASS="${GAMEPASS:-}"
DEFAULT_OFF="${DEFAULT_OFF:-pad-xbox}"
RFS=/opt/fex-rootfs/Ubuntu_24_04
FEXPPA="ppa:fex-emu/fex"
say(){ printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[fail]\033[0m %s\n' "$*"; exit 1; }
# ---------------------------------------------------------------------------
# Optional components: tag, OPT_* variable, one-line description shown in the checklist.
COMPONENTS="glx-lax vk-spoof map-count multiblock big-cores xpad-dedup pad-hidraw pad-xbox desktop"
desc_of(){ case "$1" in
  glx-lax)    echo "Private Mesa GLX copy, for titles that bind one GL context from several threads";;
  vk-spoof)   echo "Vulkan feature layer: DXVK device on the Mali driver (Proton titles)";;
  map-count)  echo "vm.max_map_count raised to the SteamOS value (Proton warns below it)";;
  multiblock) echo "FEX multi-block JIT (measured gain under emulation)";;
  big-cores)  echo "Pin client, container and games to the A76 cores";;
  xpad-dedup) echo "Drop the duplicate joystick node of third-party Xbox 360 style pads";;
  pad-hidraw) echo "Let the client read pads directly, for rumble and battery level";;
  pad-xbox)   echo "Present XInput pads from other makers as Xbox 360 pads (engines match on IDs)";;
  desktop)    echo "Application menu entry, desktop icon, passwordless steam-fex for the user";;
esac; }
var_of(){ echo "OPT_$(echo "$1" | tr 'a-z-' 'A-Z_')"; }
for c in $COMPONENTS; do eval "$(var_of "$c")=1"; done
# DEFAULT_OFF components stay opt-in (pad-xbox grabs the physical pad, starving direct reads).
for c in ${DEFAULT_OFF:-}; do eval "$(var_of "$c")=0"; done
MODE=ask
while [ $# -gt 0 ]; do
  case "$1" in
    --defaults) MODE=defaults;;
    --select)   MODE=select; SEL="${2:-}"; shift;;
    --select=*) MODE=select; SEL="${1#*=}";;
    --skip)     MODE=skip; SEL="${2:-}"; shift;;
    --skip=*)   MODE=skip; SEL="${1#*=}";;
    --list)     for c in $COMPONENTS; do printf '  %-11s %s\n' "$c" "$(desc_of "$c")"; done; exit 0;;
    -h|--help)  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1 (see --help)";;
  esac; shift
done
known(){ for c in $COMPONENTS; do [ "$c" = "$1" ] && return 0; done; return 1; }
case "$MODE" in
  select) for c in $COMPONENTS; do eval "$(var_of "$c")=0"; done
          for c in $(echo "$SEL" | tr ',' ' '); do known "$c" || die "unknown component: $c"; eval "$(var_of "$c")=1"; done;;
  skip)   for c in $(echo "$SEL" | tr ',' ' '); do known "$c" || die "unknown component: $c"; eval "$(var_of "$c")=0"; done;;
  ask)    if [ -t 0 ] && [ -t 1 ]; then
            # Explain the keyboard-driven picker and its flag alternatives before showing it.
            printf '\n  Components: --defaults takes the recommended set, --select a,b takes exactly\n'
            printf '  those, --skip a,b takes the defaults without them, --list prints them all.\n\n'
            if command -v whiptail >/dev/null 2>&1; then
              args=(); for c in $COMPONENTS; do
                args+=("$c" "$(desc_of "$c")" "$(eval "[ \"\$$(var_of "$c")\" = 1 ]" && echo ON || echo OFF)")
              done
              chosen=$(whiptail --title "Steam via FEX" --checklist "Optional components.\n\nSPACE toggles the item under the cursor.  TAB moves to the buttons.  ENTER confirms.\nThis list is keyboard driven; a mouse click does nothing." 22 92 6 "${args[@]}" 3>&1 1>&2 2>&3) || die "cancelled"
              for c in $COMPONENTS; do eval "$(var_of "$c")=0"; done
              for c in $chosen; do c=${c//\"/}; eval "$(var_of "$c")=1"; done
            else
              for c in $COMPONENTS; do
                if eval "[ \"\$$(var_of "$c")\" = 1 ]"; then
                  printf '  %-11s %s [Y/n] ' "$c" "$(desc_of "$c")"; read -r a
                  case "$a" in n|N) eval "$(var_of "$c")=0";; esac
                else
                  printf '  %-11s %s [y/N] ' "$c" "$(desc_of "$c")"; read -r a
                  case "$a" in y|Y) eval "$(var_of "$c")=1";; esac
                fi
              done
            fi
          fi;;
esac
opt(){ eval "[ \"\$$(var_of "$1")\" = 1 ]"; }
[ "$(id -u)" = 0 ] || die "run as root"

# wait for any boot-time apt/dpkg (unattended-upgrades, armbian online-extras) to release the lock
wait_apt(){
  local n=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ $n = 0 ] && warn "another apt/dpkg is running; waiting for the lock..."
    sleep 5; n=$((n+5)); [ $n -ge 600 ] && die "dpkg lock still held after 10 min"
  done
}

# ---------------------------------------------------------------------------
h96_banner "S T E A M   V I A   F E X"
printf 'Optional components:'; for c in $COMPONENTS; do opt "$c" && printf ' %s' "$c" || printf ' [no %s]' "$c"; done; echo
say "1/9  host packages: FEX + native bubblewrap"
export DEBIAN_FRONTEND=noninteractive
wait_apt
command -v add-apt-repository >/dev/null || apt-get install -y software-properties-common
grep -rq "fex-emu/fex" /etc/apt/sources.list.d/ 2>/dev/null || add-apt-repository -y "$FEXPPA"
wait_apt; apt-get update -y
BUILDPKGS=""; opt vk-spoof && BUILDPKGS="gcc libc6-dev libvulkan-dev"   # step 5d builds a small Vulkan layer on the box
opt glx-lax && BUILDPKGS="$BUILDPKGS patchelf"                             # step 5c gives the GLX copy its own SONAME
wait_apt; apt-get install -y fex-emu-armv8.2 fex-emu-binfmt32 fex-emu-binfmt64 bubblewrap dbus-daemon xz-utils xdotool $BUILDPKGS
command -v FEXBash >/dev/null || die "FEX did not install"
file -b /usr/bin/bwrap | grep -q aarch64 || die "host bwrap is not native aarch64"

# ---------------------------------------------------------------------------
say "2/9  disable box64/box32 binfmt so FEX owns x86 exec (persistent via systemd)"
echo 0 > /proc/sys/fs/binfmt_misc/box64 2>/dev/null || true
echo 0 > /proc/sys/fs/binfmt_misc/box32 2>/dev/null || true
cat > /etc/systemd/system/h96-fex-binfmt.service <<'UNIT'
[Unit]
Description=Disable box64/box32 binfmt so FEX owns x86-64 execution
After=systemd-binfmt.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > /proc/sys/fs/binfmt_misc/box64 2>/dev/null; echo 0 > /proc/sys/fs/binfmt_misc/box32 2>/dev/null; true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable --now h96-fex-binfmt.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
say "3/9  game user '$GAMEUSER' + systemd linger + /dev/shm"
if ! id "$GAMEUSER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G video,render,input,audio "$GAMEUSER"
  if [ -z "$GAMEPASS" ]; then
    GAMEPASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14)
    say "     created account '$GAMEUSER' with password: $GAMEPASS"
    say "     write it down now; change it with: passwd $GAMEUSER"
  fi
  echo "$GAMEUSER:$GAMEPASS" | chpasswd
fi
for g in video render input audio; do usermod -aG "$g" "$GAMEUSER" 2>/dev/null; done
loginctl enable-linger "$GAMEUSER" >/dev/null 2>&1 || true
UID_N=$(id -u "$GAMEUSER")
# gamescope/wlroots and CEF need /dev/shm as a 1777 tmpfs; guard and persist via fstab.
if ! mountpoint -q /dev/shm || [ "$(stat -c %a /dev/shm)" != 1777 ]; then
  mountpoint -q /dev/shm && umount /dev/shm 2>/dev/null
  mount -t tmpfs -o rw,nosuid,nodev,mode=1777 tmpfs /dev/shm; chmod 1777 /dev/shm
fi
grep -q '[[:space:]]/dev/shm[[:space:]]' /etc/fstab || echo 'tmpfs /dev/shm tmpfs rw,nosuid,nodev,mode=1777 0 0' >> /etc/fstab
# Proton warns below 262144 max_map_count (SteamOS value); zz- prefix sorts after 99-sysctl.conf so this wins at boot.
if opt map-count; then
  rm -f /etc/sysctl.d/99-h96-steam.conf
  printf 'vm.max_map_count = 2147483642\n' > /etc/sysctl.d/zz-h96-steam.conf
  sysctl -q -p /etc/sysctl.d/zz-h96-steam.conf 2>/dev/null || true
else
  rm -f /etc/sysctl.d/99-h96-steam.conf /etc/sysctl.d/zz-h96-steam.conf
  sysctl -q -w vm.max_map_count=65530 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
say "4/9  x86-64 RootFS (Ubuntu 24.04) fetch + relocate + config"
if [ ! -d "$RFS" ]; then
  SRC=$(find /root/.fex-emu/RootFS /root/.local/share/fex-emu/RootFS -maxdepth 1 -name Ubuntu_24_04 -type d 2>/dev/null | head -1)
  if [ -z "$SRC" ]; then
    ( cd /opt 2>/dev/null; env -u DISPLAY FEXRootFSFetcher -y -x --force-ui=tty --distro-name=ubuntu --distro-version=24.04 )
    SRC=$(find /root/.fex-emu/RootFS /root/.local/share/fex-emu/RootFS -maxdepth 1 -name Ubuntu_24_04 -type d 2>/dev/null | head -1)
  fi
  [ -n "$SRC" ] || die "RootFS fetch failed"
  mkdir -p /opt/fex-rootfs && mv "$SRC" "$RFS"
fi
chmod o+rx /opt /opt/fex-rootfs "$RFS"

# HostEnv (host side only): first entry selects the GLX copy (step 5c), second keeps the Vulkan loader path inside runtime containers (step 5d).
FEXEXTRA=""
opt multiblock && FEXEXTRA="$FEXEXTRA,
  \"Multiblock\":\"1\""
opt glx-lax   && FEXEXTRA="$FEXEXTRA,
  \"HostEnv\":\"__GLX_VENDOR_LIBRARY_NAME=h96lax\""
opt vk-spoof  && FEXEXTRA="$FEXEXTRA,
  \"HostEnv\":\"VK_IMPLICIT_LAYER_PATH=/usr/share/vulkan/implicit_layer.d\""
write_fex_config(){  # $1=path  $2=owner
  install -d -o "$2" -g "$2" "$(dirname "$1")"
  cat > "$1" <<JSON
{ "Config": { "RootFS":"$RFS",
  "ThunkHostLibs":"/usr/lib/aarch64-linux-gnu/fex-emu/HostThunks/",
  "ThunkGuestLibs":"/usr/share/fex-emu/GuestThunks/",
  "ThunkConfig":"/usr/share/fex-emu/ThunksDB.json"$FEXEXTRA },
  "ThunksDB":{"GL":1,"Vulkan":1} }
JSON
  chown "$2:$2" "$1"
}
write_fex_config /root/.fex-emu/Config.json root
write_fex_config "/home/$GAMEUSER/.fex-emu/Config.json" "$GAMEUSER"

# steamwebhelper's GPU process aborts if thunked to panvk (ANGLE software backend); thunks off (SwiftShader) for steamwebhelper/exe only, games keep them.
install -d -o "$GAMEUSER" -g "$GAMEUSER" "/home/$GAMEUSER/.fex-emu/AppConfig"
for n in steamwebhelper exe; do
  printf '{ "ThunksDB": { "GL": 0, "Vulkan": 0 } }\n' > "/home/$GAMEUSER/.fex-emu/AppConfig/$n.json"
  chown "$GAMEUSER:$GAMEUSER" "/home/$GAMEUSER/.fex-emu/AppConfig/$n.json"
done

# Nativize RootFS bwrap (x86-64 bwrap hangs on the userns handshake under FEX); no-op unless one already exists.
nativize_rootfs_bwrap(){
  find "$RFS/usr/bin" "$RFS/usr/local/bin" -name bwrap -type f 2>/dev/null | while read -r b; do
    if file -b "$b" 2>/dev/null | grep -q x86-64; then
      mv -f "$b" "$b.x86"; cp -f /usr/bin/bwrap "$b"; chmod 0755 "$b"
    fi
  done
}
nativize_rootfs_bwrap

# ---------------------------------------------------------------------------
say "5/9  install Steam + fonts into RootFS via isolated chroot"
cat > /tmp/h96-chroot-steam.sh <<CHROOT
#!/bin/bash
set -u
RFS="$RFS"
cleanup(){
  umount -R -l "\$RFS/proc" "\$RFS/sys" "\$RFS/dev" 2>/dev/null
  umount -l "\$RFS/usr/lib/aarch64-linux-gnu" "\$RFS/usr/bin/FEX" "\$RFS/usr/bin/FEXServer" 2>/dev/null
  # host /dev submounts must survive the chroot teardown; restore any that did not
  grep -q " /dev/shm " /proc/mounts || { mount -t tmpfs -o rw,nosuid,nodev,mode=1777 tmpfs /dev/shm; chmod 1777 /dev/shm; echo "[warn] host /dev/shm was unmounted by the chroot teardown; remounted"; }
  # Same for /sys submounts: a propagated teardown strips cgroup2, blocking new cgroups until reboot.
  for spec in "cgroup2 cgroup2 /sys/fs/cgroup" "debugfs debugfs /sys/kernel/debug" "tracefs tracefs /sys/kernel/tracing" "bpf bpf /sys/fs/bpf" "configfs configfs /sys/kernel/config"; do
    set -- \$spec; mountpoint -q "\$3" || { mount -t "\$1" "\$2" "\$3" 2>/dev/null && echo "[warn] host \$3 was unmounted by the chroot teardown; remounted"; }
  done
  grep -q " /dev/pts " /proc/mounts || { mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts; echo "[warn] host /dev/pts remounted"; }
  grep -q " /dev/mqueue " /proc/mounts || mount -t mqueue mqueue /dev/mqueue 2>/dev/null
}
trap cleanup EXIT
mkdir -p "\$RFS"/{proc,sys,dev,dev/pts,tmp,run/user/0,etc/apt/apt.conf.d,root/.fex-emu,usr/lib/aarch64-linux-gnu}
chmod 1777 "\$RFS/tmp"; chmod 700 "\$RFS/run/user/0"
mount --bind /usr/lib/aarch64-linux-gnu "\$RFS/usr/lib/aarch64-linux-gnu"
ln -sf aarch64-linux-gnu/ld-linux-aarch64.so.1 "\$RFS/usr/lib/ld-linux-aarch64.so.1"
for b in FEX FEXServer; do [ -e "\$RFS/usr/bin/\$b" ] || : > "\$RFS/usr/bin/\$b"; mount --bind /usr/bin/\$b "\$RFS/usr/bin/\$b"; done
echo '{ "Config": { "RootFS":"/" } }' > "\$RFS/root/.fex-emu/Config.json"
# --make-rslave stops the cleanup umount from propagating back and stripping host /dev/shm, /dev/pts, /dev/mqueue.
mount -t proc proc "\$RFS/proc"
mount --rbind /sys "\$RFS/sys"; mount --make-rslave "\$RFS/sys"
mount --rbind /dev "\$RFS/dev"; mount --make-rslave "\$RFS/dev"
mount -t devpts devpts "\$RFS/dev/pts" 2>/dev/null
cp -f /etc/resolv.conf "\$RFS/etc/resolv.conf"
echo 'APT::Sandbox::User "root";' > "\$RFS/etc/apt/apt.conf.d/99fex"
# user-db (RootFS ships none) + messagebus (dbus statoverride)
[ -f "\$RFS/etc/passwd" ] || cp "\$RFS/usr/share/base-passwd/passwd.master" "\$RFS/etc/passwd"
[ -f "\$RFS/etc/group" ]  || cp "\$RFS/usr/share/base-passwd/group.master"  "\$RFS/etc/group"
touch "\$RFS/etc/shadow" "\$RFS/etc/gshadow"
grep -q "^messagebus:" "\$RFS/etc/group"  || echo "messagebus:x:999:" >> "\$RFS/etc/group"
grep -q "^messagebus:" "\$RFS/etc/passwd" || echo "messagebus:x:999:999:messagebus:/nonexistent:/usr/sbin/nologin" >> "\$RFS/etc/passwd"
[ -f /tmp/steam-launcher.deb ] || wget -q https://repo.steampowered.com/steam/archive/stable/steam-launcher_latest_all.deb -O /tmp/steam-launcher.deb
cp -f /tmp/steam-launcher.deb "\$RFS/tmp/steam-launcher.deb"
chroot "\$RFS" /usr/bin/env XDG_RUNTIME_DIR=/run/user/0 HOME=/root FEX_ROOTFS=/ DEBIAN_FRONTEND=noninteractive /bin/bash -c '
  FEXServer -p 600 2>/dev/null; sleep 1
  apt-get update -y >/dev/null 2>&1
  echo "steam steam/question select I AGREE" | debconf-set-selections
  echo "steam steam/license note " | debconf-set-selections
  apt-get install -y /tmp/steam-launcher.deb 2>&1 | grep -iE "Setting up steam|unmet|dpkg: error" | tail -4
  apt-get install -y fonts-dejavu-core fonts-liberation fontconfig xfonts-base xfonts-utils >/dev/null 2>&1
  fc-cache -f 2>/dev/null || true
  [ -f /usr/bin/steamdeps ] && { cp -a /usr/bin/steamdeps /usr/bin/steamdeps.real 2>/dev/null; printf "#!/bin/sh\nexit 0\n" > /usr/bin/steamdeps; chmod 755 /usr/bin/steamdeps; }
  echo "steam bin: \$(command -v steam || echo MISSING)"
' 2>&1 | grep -vE "connect to FEXServer|execute: FEXServer|squashFS|Expect errors|Failure to setup"
CHROOT
chmod +x /tmp/h96-chroot-steam.sh
if [ ! -x "$RFS/usr/bin/steam" ]; then bash /tmp/h96-chroot-steam.sh; fi
[ -x "$RFS/usr/bin/steam" ] || die "Steam not installed in RootFS"

# Steam's chroot install pulls an x86 bwrap into the RootFS; nativize now or srt-bwrap/steamwebhelper deadlock on userns handshake.
nativize_rootfs_bwrap

# ---------------------------------------------------------------------------
say "5b/9  make X protocol errors non-fatal (libX11 default-handler patch)"
# BadDrawable on a freed dialog window aborts Steam (RTLD_DEEPBIND blocks interposition); patch _XDefaultError to return 0 in guest and a private native libX11 copy.
cat > /usr/local/lib/h96-xerr-patch.py <<'PYEOF'
#!/usr/bin/env python3
# Patch _XDefaultError to "xor eax,eax; ret" (return 0) so BadDrawable no longer aborts; minimal ELF parser, backs up first.
import struct, sys, shutil, os

def patch(path):
    with open(path, "rb") as f:
        d = bytearray(f.read())
    assert d[:4] == b"\x7fELF", "not ELF"
    is64 = d[4] == 2
    if is64:
        e_shoff = struct.unpack_from("<Q", d, 0x28)[0]
        e_shentsize = struct.unpack_from("<H", d, 0x3a)[0]
        e_shnum = struct.unpack_from("<H", d, 0x3c)[0]
        e_shstrndx = struct.unpack_from("<H", d, 0x3e)[0]
    else:
        e_shoff = struct.unpack_from("<I", d, 0x20)[0]
        e_shentsize = struct.unpack_from("<H", d, 0x2e)[0]
        e_shnum = struct.unpack_from("<H", d, 0x30)[0]
        e_shstrndx = struct.unpack_from("<H", d, 0x32)[0]

    secs = []  # (name_off, type, addr, offset, size, entsize, link)
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if is64:
            name, typ = struct.unpack_from("<II", d, off)
            addr, offset = struct.unpack_from("<QQ", d, off + 0x10)
            size = struct.unpack_from("<Q", d, off + 0x20)[0]
            link = struct.unpack_from("<I", d, off + 0x28)[0]
            entsize = struct.unpack_from("<Q", d, off + 0x38)[0]
        else:
            name, typ = struct.unpack_from("<II", d, off)
            addr, offset, size = struct.unpack_from("<III", d, off + 0x0c)
            link = struct.unpack_from("<I", d, off + 0x18)[0]
            entsize = struct.unpack_from("<I", d, off + 0x24)[0]
        secs.append((name, typ, addr, offset, size, entsize, link))

    shstr_off = secs[e_shstrndx][3]
    def sname(n):
        e = d.index(0, shstr_off + n); return d[shstr_off + n:e].decode()

    # locate .text and the symbol tables
    text = next(s for s in secs if sname(s[0]) == ".text")
    def find_sym(name):
        for s in secs:
            if s[1] not in (2, 11):  # SYMTAB=2, DYNSYM=11
                continue
            symtab_off, symtab_size, entsize, strtab = s[3], s[4], s[5], s[6]
            stroff = secs[strtab][3]
            cnt = symtab_size // entsize
            for k in range(cnt):
                so = symtab_off + k * entsize
                if is64:
                    st_name = struct.unpack_from("<I", d, so)[0]
                    st_value = struct.unpack_from("<Q", d, so + 8)[0]
                else:
                    st_name = struct.unpack_from("<I", d, so)[0]
                    st_value = struct.unpack_from("<I", d, so + 4)[0]
                if st_name == 0:
                    continue
                e = d.index(0, stroff + st_name)
                if d[stroff + st_name:e].decode(errors="replace") == name and st_value:
                    return st_value
        return None

    # If a prior (bad) patch left a backup, restore first so we re-patch clean bytes.
    if os.path.exists(path + ".orig"):
        shutil.copy2(path + ".orig", path)
        with open(path, "rb") as f:
            d = bytearray(f.read())

    e_machine = struct.unpack_from("<H", d, 0x12)[0]   # 0x03=i386 0x3e=x86-64 0xb7=aarch64
    vaddr = find_sym("_XDefaultError")
    if vaddr is None:
        print(f"  {path}: _XDefaultError not found"); return False
    _, _, taddr, toff, tsize, _, _ = text
    foff = vaddr - taddr + toff
    if e_machine == 0xb7:
        # Stub needs neither PAC nor a signed LR: BTI landing pad + "mov w0,#0 ; ret" (paciasp never runs).
        lead = 0
        patch = b"\x5f\x24\x03\xd5\x00\x00\x80\x52\xc0\x03\x5f\xd6"   # bti c ; mov w0,#0 ; ret
    else:
        # x86: preserve a CET landing pad (endbr32=..fb / endbr64=..fa) then "xor eax,eax ; ret".
        lead = 4 if (bytes(d[foff:foff+3]) == b"\xf3\x0f\x1e" and d[foff+3] in (0xfa, 0xfb)) else 0
        patch = b"\x31\xc0\xc3"
    at = foff + lead
    orig = bytes(d[at:at+len(patch)])
    if orig == patch:
        print(f"  {path}: already patched (lead={lead})"); return True
    if not os.path.exists(path + ".orig"):
        shutil.copy2(path, path + ".orig")
    d[at:at+len(patch)] = patch
    with open(path, "wb") as f:
        f.write(d)
    print(f"  {path}: patched _XDefaultError @0x{vaddr:x} (+{lead}, file 0x{at:x}) {orig.hex()} -> {patch.hex()}")
    return True

ok = True
for p in sys.argv[1:]:
    real = os.path.realpath(p)
    if not (os.path.isfile(real)):
        print(f"  {p}: skipped (target missing: {real})"); continue
    try:
        ok = patch(real) and ok
    except Exception as e:
        print(f"  {real}: skipped ({e})")
sys.exit(0 if ok else 1)
PYEOF
find "$RFS/usr/lib" "/home/$GAMEUSER/.local/share/Steam" -name 'libX11.so.6' 2>/dev/null | sort -u \
  | while read -r L; do python3 /usr/local/lib/h96-xerr-patch.py "$L"; done
HL="/home/$GAMEUSER/.fex-emu/hostlib"; install -d -o "$GAMEUSER" -g "$GAMEUSER" "$HL"
NSRC=$(realpath /usr/lib/aarch64-linux-gnu/libX11.so.6)
cp -f "$NSRC" "$HL/$(basename "$NSRC")"; ln -sf "$(basename "$NSRC")" "$HL/libX11.so.6"
python3 /usr/local/lib/h96-xerr-patch.py "$HL/$(basename "$NSRC")"
chown -R "$GAMEUSER:$GAMEUSER" "$HL"
echo "  native libX11 patched copy ready"

# ---------------------------------------------------------------------------
if opt glx-lax; then
say "5c/9  GL context binding across threads (private Mesa GLX copy)"
# Patch libGLX_mesa to allow one GL context bound from multiple threads (some titles need this); installed as vendor "h96lax", host-side only.
cat > /usr/local/lib/h96-glx-lax-patch.py <<'PYEOF'
#!/usr/bin/env python3
# Patch libGLX_mesa: nop MakeContextCurrent's cross-thread current-context check (exit 1 if no match). Usage: <in> <out>
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
b = bytearray(open(src, "rb").read())
hits = []
for off in range(0, len(b) - 12, 4):
    i0, i1, i2 = struct.unpack_from("<III", b, off)
    if (i0 & 0xFFFFFC00) != 0xF9408000: continue      # ldr x?, [x?, #256]
    if (i1 & 0xFF000000) != 0xB5000000: continue      # cbnz x?, imm
    if (i2 & 0xFFFFFC00) != 0xF9401400: continue      # ldr x?, [x?, #40]
    rt, rn = i0 & 31, (i0 >> 5) & 31
    if (i1 & 31) != rt or ((i2 >> 5) & 31) != rn: continue
    hits.append(off + 4)
if len(hits) != 1:
    print("h96-glx-lax-patch: expected one match, found %d %s" % (len(hits), [hex(h) for h in hits]), file=sys.stderr)
    sys.exit(1)
struct.pack_into("<I", b, hits[0], 0xD503201F)  # nop
open(dst, "wb").write(b)
print("h96-glx-lax-patch: cbnz at 0x%x replaced" % hits[0])
PYEOF
cat > /usr/local/sbin/h96-glx-lax <<'GLX'
#!/bin/sh
# Keep libGLX_h96lax.so.0 in sync with system Mesa GLX; rebuilds only on checksum change.
SRC=$(realpath /usr/lib/aarch64-linux-gnu/libGLX_mesa.so.0 2>/dev/null) || exit 0
[ -f "$SRC" ] || exit 0
OUT=/usr/lib/aarch64-linux-gnu/libGLX_h96lax.so.0
STAMP=/usr/local/lib/h96-glx-lax.src
SUM=$(sha256sum "$SRC" | cut -c1-64)
[ -f "$OUT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SUM" ] && [ "$(patchelf --print-soname "$OUT" 2>/dev/null)" = libGLX_h96lax.so.0 ] && exit 0
T=$(mktemp "$OUT.XXXXXX") || exit 1
if python3 /usr/local/lib/h96-glx-lax-patch.py "$SRC" "$T" >/dev/null 2>&1; then
  echo "h96-glx-lax: patched copy built from $(basename "$SRC")"
else
  cp -f "$SRC" "$T"
  echo "h96-glx-lax: pattern not found in $(basename "$SRC"); vendor library is an unpatched copy" >&2
fi
# Own SONAME so Steam Linux Runtime containers copy this vendor lib in too.
command -v patchelf >/dev/null && patchelf --set-soname libGLX_h96lax.so.0 "$T"
chmod 644 "$T" && mv -f "$T" "$OUT" && echo "$SUM" > "$STAMP" && ldconfig
GLX
chmod 755 /usr/local/sbin/h96-glx-lax
/usr/local/sbin/h96-glx-lax
[ -f /usr/lib/aarch64-linux-gnu/libGLX_h96lax.so.0 ] && echo "  libGLX_h96lax.so.0 ready" || echo "  [warn] no native libGLX_mesa found; lax GLX copy skipped"
else
say "5c/9  private Mesa GLX copy: not selected"
rm -f /usr/lib/aarch64-linux-gnu/libGLX_h96lax.so.0 /usr/local/sbin/h96-glx-lax /usr/local/lib/h96-glx-lax-patch.py /usr/local/lib/h96-glx-lax.src
fi

# ---------------------------------------------------------------------------
if opt vk-spoof; then
say "5d/9  Vulkan feature layer for Proton titles (DXVK on the Mali driver)"
# DXVK requires Vulkan features panvk lacks; this layer spoofs them present, then strips them before vkCreateDevice. Enabled via H96_VK_SPOOF=1, opt-out H96_VK_SPOOF_DISABLE=1.
cat > /usr/local/lib/h96-vk-spoof.c <<'CEOF'
/* VK_LAYER_H96_feature_spoof: report a fixed set of VkPhysicalDeviceFeatures as supported and strip
 * them again from vkCreateDevice so the driver never sees them enabled. */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_INST 16
#define MAX_DEV 64
typedef struct { void *key; PFN_vkGetInstanceProcAddr gipa; PFN_vkCreateDevice create_device;
  PFN_vkGetPhysicalDeviceFeatures gpdf; PFN_vkGetPhysicalDeviceFeatures2 gpdf2; PFN_vkDestroyInstance destroy; } inst_t;
typedef struct { void *key; PFN_vkGetDeviceProcAddr gdpa; PFN_vkDestroyDevice destroy; } dev_t_;
static inst_t insts[MAX_INST]; static dev_t_ devs[MAX_DEV]; static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int dbg;

static void *key_of(const void *h) { return *(void **)h; }
static inst_t *inst_find(const void *h) { void *k = key_of(h); for (int i = 0; i < MAX_INST; i++) if (insts[i].key == k) return &insts[i]; return NULL; }
static dev_t_ *dev_find(const void *h) { void *k = key_of(h); for (int i = 0; i < MAX_DEV; i++) if (devs[i].key == k) return &devs[i]; return NULL; }

static void spoof_features(VkPhysicalDeviceFeatures *f) {
  f->fillModeNonSolid = VK_TRUE; f->geometryShader = VK_TRUE; f->multiViewport = VK_TRUE;
  f->shaderClipDistance = VK_TRUE; f->shaderCullDistance = VK_TRUE;
}
static void unspoof_features(VkPhysicalDeviceFeatures *f, const VkPhysicalDeviceFeatures *real) {
  f->fillModeNonSolid = real->fillModeNonSolid; f->geometryShader = real->geometryShader; f->multiViewport = real->multiViewport;
  f->shaderClipDistance = real->shaderClipDistance; f->shaderCullDistance = real->shaderCullDistance;
}

static VKAPI_ATTR void VKAPI_CALL layer_GetPhysicalDeviceFeatures(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) {
  inst_t *in = inst_find(pd); in->gpdf(pd, f); spoof_features(f);
}
static VKAPI_ATTR void VKAPI_CALL layer_GetPhysicalDeviceFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
  inst_t *in = inst_find(pd); in->gpdf2(pd, f); spoof_features(&f->features);
  for (VkBaseOutStructure *p = (VkBaseOutStructure *)f->pNext; p; p = p->pNext)
    if (p->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT)
      ((VkPhysicalDeviceRobustness2FeaturesEXT *)p)->robustBufferAccess2 = VK_TRUE;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *ac, VkInstance *inst) {
  VkLayerInstanceCreateInfo *li = (VkLayerInstanceCreateInfo *)ci->pNext;
  while (li && !(li->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && li->function == VK_LAYER_LINK_INFO)) li = (VkLayerInstanceCreateInfo *)li->pNext;
  if (!li) return VK_ERROR_INITIALIZATION_FAILED;
  PFN_vkGetInstanceProcAddr gipa = li->u.pLayerInfo->pfnNextGetInstanceProcAddr;
  li->u.pLayerInfo = li->u.pLayerInfo->pNext;
  PFN_vkCreateInstance next = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
  VkResult r = next(ci, ac, inst);
  if (r != VK_SUCCESS) return r;
  pthread_mutex_lock(&lock);
  for (int i = 0; i < MAX_INST; i++) if (!insts[i].key) {
    insts[i].key = key_of(*inst); insts[i].gipa = gipa;
    insts[i].create_device = (PFN_vkCreateDevice)gipa(*inst, "vkCreateDevice");
    insts[i].gpdf = (PFN_vkGetPhysicalDeviceFeatures)gipa(*inst, "vkGetPhysicalDeviceFeatures");
    insts[i].gpdf2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(*inst, "vkGetPhysicalDeviceFeatures2");
    if (!insts[i].gpdf2) insts[i].gpdf2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(*inst, "vkGetPhysicalDeviceFeatures2KHR");
    insts[i].destroy = (PFN_vkDestroyInstance)gipa(*inst, "vkDestroyInstance");
    break; }
  pthread_mutex_unlock(&lock);
  if (dbg) fprintf(stderr, "[h96-vk-spoof] instance created\n");
  return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL layer_DestroyInstance(VkInstance inst, const VkAllocationCallbacks *ac) {
  inst_t *in = inst_find(inst); PFN_vkDestroyInstance d = in->destroy;
  pthread_mutex_lock(&lock); memset(in, 0, sizeof *in); pthread_mutex_unlock(&lock);
  d(inst, ac);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *ac, VkDevice *dev) {
  inst_t *in = inst_find(pd);
  VkLayerDeviceCreateInfo *li = (VkLayerDeviceCreateInfo *)ci->pNext;
  while (li && !(li->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && li->function == VK_LAYER_LINK_INFO)) li = (VkLayerDeviceCreateInfo *)li->pNext;
  if (!li) return VK_ERROR_INITIALIZATION_FAILED;
  PFN_vkGetDeviceProcAddr gdpa = li->u.pLayerInfo->pfnNextGetDeviceProcAddr;
  li->u.pLayerInfo = li->u.pLayerInfo->pNext;

  VkPhysicalDeviceFeatures real; in->gpdf(pd, &real);
  VkDeviceCreateInfo ci2 = *ci;
  VkPhysicalDeviceFeatures ef;
  if (ci->pEnabledFeatures) { ef = *ci->pEnabledFeatures; unspoof_features(&ef, &real); ci2.pEnabledFeatures = &ef; }
  /* clone the chain nodes that need editing; the rest is shared */
  VkPhysicalDeviceFeatures2 f2; VkPhysicalDeviceRobustness2FeaturesEXT r2; int have_f2 = 0, have_r2 = 0;
  VkBaseOutStructure head = { VK_STRUCTURE_TYPE_APPLICATION_INFO, (VkBaseOutStructure *)ci->pNext }; VkBaseOutStructure *prev = &head;
  for (VkBaseOutStructure *p = (VkBaseOutStructure *)ci->pNext; p; p = p->pNext) {
    if (p->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 && !have_f2) {
      f2 = *(VkPhysicalDeviceFeatures2 *)p; unspoof_features(&f2.features, &real); prev->pNext = (VkBaseOutStructure *)&f2; prev = (VkBaseOutStructure *)&f2; have_f2 = 1;
    } else if (p->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT && !have_r2) {
      r2 = *(VkPhysicalDeviceRobustness2FeaturesEXT *)p; r2.robustBufferAccess2 = VK_FALSE; prev->pNext = (VkBaseOutStructure *)&r2; prev = (VkBaseOutStructure *)&r2; have_r2 = 1;
    } else prev = p;
  }
  ci2.pNext = head.pNext;
  VkResult r = in->create_device(pd, &ci2, ac, dev);
  if (dbg) fprintf(stderr, "[h96-vk-spoof] vkCreateDevice -> %d (features2 %d, robustness2 %d)\n", r, have_f2, have_r2);
  if (r != VK_SUCCESS) return r;
  pthread_mutex_lock(&lock);
  for (int i = 0; i < MAX_DEV; i++) if (!devs[i].key) { devs[i].key = key_of(*dev); devs[i].gdpa = gdpa; devs[i].destroy = (PFN_vkDestroyDevice)gdpa(*dev, "vkDestroyDevice"); break; }
  pthread_mutex_unlock(&lock);
  return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL layer_DestroyDevice(VkDevice dev, const VkAllocationCallbacks *ac) {
  dev_t_ *d = dev_find(dev); PFN_vkDestroyDevice f = d->destroy;
  pthread_mutex_lock(&lock); memset(d, 0, sizeof *d); pthread_mutex_unlock(&lock);
  f(dev, ac);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL h96_GetDeviceProcAddr(VkDevice dev, const char *name);
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL h96_GetInstanceProcAddr(VkInstance inst, const char *name) {
  if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)h96_GetInstanceProcAddr;
  if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)layer_CreateInstance;
  if (!strcmp(name, "vkDestroyInstance")) return (PFN_vkVoidFunction)layer_DestroyInstance;
  if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)layer_CreateDevice;
  if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)h96_GetDeviceProcAddr;
  if (!strcmp(name, "vkGetPhysicalDeviceFeatures")) return (PFN_vkVoidFunction)layer_GetPhysicalDeviceFeatures;
  if (!strcmp(name, "vkGetPhysicalDeviceFeatures2") || !strcmp(name, "vkGetPhysicalDeviceFeatures2KHR")) return (PFN_vkVoidFunction)layer_GetPhysicalDeviceFeatures2;
  if (!inst) return NULL;
  inst_t *in = inst_find(inst); return in ? in->gipa(inst, name) : NULL;
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL h96_GetDeviceProcAddr(VkDevice dev, const char *name) {
  if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)h96_GetDeviceProcAddr;
  if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)layer_DestroyDevice;
  dev_t_ *d = dev_find(dev); return d ? d->gdpa(dev, name) : NULL;
}
VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *p) {
  dbg = getenv("H96_VK_SPOOF_DEBUG") != NULL;
  if (p->loaderLayerInterfaceVersion < 2) return VK_ERROR_INITIALIZATION_FAILED;
  p->loaderLayerInterfaceVersion = 2;
  p->pfnGetInstanceProcAddr = h96_GetInstanceProcAddr;
  p->pfnGetDeviceProcAddr = h96_GetDeviceProcAddr;
  p->pfnGetPhysicalDeviceProcAddr = NULL;
  return VK_SUCCESS;
}
CEOF
if gcc -shared -fPIC -O2 -o /usr/lib/aarch64-linux-gnu/libVkLayer_h96_spoof.so /usr/local/lib/h96-vk-spoof.c -lpthread; then
  chmod 644 /usr/lib/aarch64-linux-gnu/libVkLayer_h96_spoof.so
  mkdir -p /usr/share/vulkan/implicit_layer.d
  cat > /usr/share/vulkan/implicit_layer.d/VkLayer_h96_spoof.json <<'JSON'
{
  "file_format_version": "1.0.0",
  "layer": {
    "name": "VK_LAYER_H96_feature_spoof",
    "type": "GLOBAL",
    "library_path": "/usr/lib/aarch64-linux-gnu/libVkLayer_h96_spoof.so",
    "api_version": "1.4.0",
    "implementation_version": "1",
    "description": "Reports fillModeNonSolid, geometryShader, multiViewport, shaderClipDistance, shaderCullDistance and robustBufferAccess2 as supported and strips them from device creation",
    "functions": {
      "vkNegotiateLoaderLayerInterfaceVersion": "vkNegotiateLoaderLayerInterfaceVersion"
    },
    "enable_environment": { "H96_VK_SPOOF": "1" },
    "disable_environment": { "H96_VK_SPOOF_DISABLE": "1" }
  }
}
JSON
  chmod 644 /usr/share/vulkan/implicit_layer.d/VkLayer_h96_spoof.json
  if command -v vulkaninfo >/dev/null 2>&1 && H96_VK_SPOOF=1 vulkaninfo 2>/dev/null | grep -q 'fillModeNonSolid *= *true'; then
    echo "  layer built and active under H96_VK_SPOOF=1"
  else
    echo "  layer built (vulkaninfo not available for a self-check)"
  fi
else
  echo "  [warn] layer build failed; Proton titles that need DXVK will not start"
fi
else
say "5d/9  Vulkan feature layer: not selected"
rm -f /usr/lib/aarch64-linux-gnu/libVkLayer_h96_spoof.so /usr/share/vulkan/implicit_layer.d/VkLayer_h96_spoof.json /usr/local/lib/h96-vk-spoof.c
fi

# ---------------------------------------------------------------------------
if opt xpad-dedup; then
say "5e/9  one joystick per pad (duplicate xpad node removed)"
# Some third-party pads expose a headset interface that xpad also binds, duplicating the joystick; unbind it.
cat > /usr/local/sbin/h96-xpad-dedup <<'DEDUP'
#!/bin/sh
# Unbind xpad from third-party pads' duplicate headset interface (ff/5d/3); idempotent.
case "${1:-}" in
  -h|--help)
    echo "usage: h96-xpad-dedup   (root)"
    echo "  Unbinds xpad from duplicate headset interface (class ff/5d, protocol 3) of"
    echo "  third-party Xbox 360 style pads, so one pad no longer shows as two joysticks."
    echo "  Run by udev on plug-in and at boot."
    exit 0;;
esac
for i in /sys/bus/usb/drivers/xpad/*:*; do
  [ -e "$i" ] || continue
  [ "$(cat "$i/bInterfaceClass" 2>/dev/null)" = ff ] || continue
  [ "$(cat "$i/bInterfaceSubClass" 2>/dev/null)" = 5d ] || continue
  [ "$(cat "$i/bInterfaceProtocol" 2>/dev/null)" = 03 ] || continue
  n=$(basename "$i"); echo "$n" > /sys/bus/usb/drivers/xpad/unbind && echo "h96-xpad-dedup: unbound duplicate pad interface $n"
done
exit 0
DEDUP
chmod 755 /usr/local/sbin/h96-xpad-dedup
cat > /etc/udev/rules.d/71-h96-xpad-dedup.rules <<'RULE'
# Drop duplicate xpad binding on third-party pads' headset interface.
ACTION=="add|bind", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", DRIVER=="xpad", ATTR{bInterfaceProtocol}=="03", RUN+="/usr/bin/systemd-run --no-block --quiet /usr/local/sbin/h96-xpad-dedup"
RULE
udevadm control --reload-rules 2>/dev/null; /usr/local/sbin/h96-xpad-dedup
else
say "5e/9  duplicate joystick node: not selected"
rm -f /usr/local/sbin/h96-xpad-dedup /etc/udev/rules.d/71-h96-xpad-dedup.rules; udevadm control --reload-rules 2>/dev/null
fi

# ---------------------------------------------------------------------------
if opt pad-hidraw; then
say "5f/9  controller access for the client"
# hidraw nodes are root-only; Valve's rules list only Valve-supported pads, so add rules for the rest.
# IDs are from the kernel's xpad_device[] table, matched vendor+product; regenerate with gen-gamepad-hidraw-rules.py.
PAD_IDS="
0079:18d4 03eb:ff01 03eb:ff02 03f0:0495 044f:0f00 044f:0f03 044f:0f07
044f:0f10 044f:b326 045e:0202 045e:0285 045e:0287 045e:0288 045e:0289
045e:028e 045e:028f 045e:0291 045e:02d1 045e:02dd 045e:02e3 045e:02ea
045e:0719 045e:0b00 045e:0b0a 045e:0b12 046d:c21d 046d:c21e 046d:c21f
046d:c242 046d:ca84 046d:ca88 046d:ca8a 046d:caa3 056e:2004 05fd:1007
05fd:107a 05fe:3030 05fe:3031 062a:0020 062a:0033 06a3:0200 06a3:0201
06a3:f51a 0738:4506 0738:4516 0738:4520 0738:4522 0738:4526 0738:4530
0738:4536 0738:4540 0738:4556 0738:4586 0738:4588 0738:45ff 0738:4716
0738:4718 0738:4726 0738:4728 0738:4736 0738:4738 0738:4740 0738:4743
0738:4758 0738:4a01 0738:6040 0738:9871 0738:b726 0738:b738 0738:beef
0738:cb02 0738:cb03 0738:cb29 0738:f738 07ff:ffff 0c12:0005 0c12:8801
0c12:8802 0c12:8809 0c12:880a 0c12:8810 0c12:9902 0d2f:0002 0e4c:1097
0e4c:1103 0e4c:2390 0e4c:3510 0e6f:0003 0e6f:0005 0e6f:0006 0e6f:0008
0e6f:0105 0e6f:0113 0e6f:011f 0e6f:0131 0e6f:0133 0e6f:0139 0e6f:013a
0e6f:0146 0e6f:0147 0e6f:015c 0e6f:0161 0e6f:0162 0e6f:0163 0e6f:0164
0e6f:0165 0e6f:0201 0e6f:0213 0e6f:021f 0e6f:0246 0e6f:02a0 0e6f:02a1
0e6f:02a2 0e6f:02a4 0e6f:02a6 0e6f:02a7 0e6f:02a8 0e6f:02ab 0e6f:02ad
0e6f:02b3 0e6f:02b8 0e6f:0301 0e6f:0346 0e6f:0401 0e6f:0413 0e6f:0501
0e6f:f900 0e8f:0201 0e8f:3008 0f0d:000a 0f0d:000c 0f0d:000d 0f0d:0016
0f0d:001b 0f0d:0063 0f0d:0067 0f0d:0078 0f0d:00c5 0f30:010b 0f30:0202
0f30:8888 102c:ff0c 1038:1430 1038:1431 11c9:55f0 11ff:0511 1209:2882
12ab:0004 12ab:0301 12ab:0303 12ab:8809 1430:4748 1430:8888 1430:f801
146b:0601 146b:0604 1532:0a00 1532:0a03 1532:0a29 15e4:3f00 15e4:3f0a
15e4:3f10 162e:beef 1689:fd00 1689:fd01 1689:fe00 17ef:6182 1949:041a
1bad:0002 1bad:0003 1bad:0130 1bad:f016 1bad:f018 1bad:f019 1bad:f021
1bad:f023 1bad:f025 1bad:f027 1bad:f028 1bad:f02e 1bad:f030 1bad:f036
1bad:f038 1bad:f039 1bad:f03a 1bad:f03d 1bad:f03e 1bad:f03f 1bad:f042
1bad:f080 1bad:f501 1bad:f502 1bad:f503 1bad:f504 1bad:f505 1bad:f506
1bad:f900 1bad:f901 1bad:f903 1bad:f904 1bad:f906 1bad:fa01 1bad:fd00
1bad:fd01 20d6:2001 20d6:2009 20d6:281f 24c6:5000 24c6:5300 24c6:5303
24c6:530a 24c6:531a 24c6:5397 24c6:541a 24c6:542a 24c6:543a 24c6:5500
24c6:5501 24c6:5502 24c6:5503 24c6:5506 24c6:550d 24c6:550e 24c6:5510
24c6:551a 24c6:561a 24c6:5b00 24c6:5b02 24c6:5b03 24c6:5d04 24c6:fafe
2563:058d 2dc8:2000 2dc8:310a 2e24:0652 31e3:1100 31e3:1200 31e3:1210
31e3:1220 31e3:1300 31e3:1310 3285:0607 3767:0101
"
{
  echo "# Hand the logged-in user the hidraw node of a game controller."
  echo "# Written by the Steam installer. uaccess grants the access to whoever holds the"
  echo "# active local seat, the same way it is granted for a keyboard or a sound card."
  for id in $PAD_IDS; do
    v=${id%:*}; p=${id#*:}
    u=$(printf '%s:%s' "$v" "$p" | tr 'a-f' 'A-F')
    echo "KERNEL==\"hidraw*\", ATTRS{idVendor}==\"$v\", ATTRS{idProduct}==\"$p\", MODE=\"0660\", TAG+=\"uaccess\""
    echo "KERNEL==\"hidraw*\", KERNELS==\"*$u*\", MODE=\"0660\", TAG+=\"uaccess\""
  done
  echo "# Pads that speak HID rather than going through xpad"
  for v in 054c 057e 28de; do
    u=$(printf '%s' "$v" | tr 'a-f' 'A-F')
    echo "KERNEL==\"hidraw*\", ATTRS{idVendor}==\"$v\", MODE=\"0660\", TAG+=\"uaccess\""
    echo "KERNEL==\"hidraw*\", KERNELS==\"*$u:*\", MODE=\"0660\", TAG+=\"uaccess\""
  done
  echo "# The client also creates its virtual controller through /dev/uinput."
  echo "KERNEL==\"uinput\", SUBSYSTEM==\"misc\", MODE=\"0660\", TAG+=\"uaccess\", OPTIONS+=\"static_node=uinput\""
} > /etc/udev/rules.d/60-h96-gamepad-hidraw.rules
chmod 644 /etc/udev/rules.d/60-h96-gamepad-hidraw.rules
udevadm control --reload 2>/dev/null
udevadm trigger --subsystem-match=hidraw --subsystem-match=misc 2>/dev/null
udevadm settle 2>/dev/null
n=$(grep -c '^KERNEL=="hidraw\*", ATTRS' /etc/udev/rules.d/60-h96-gamepad-hidraw.rules)
say "     $n pads covered"
else
say "5f/9  controller access: not selected"
rm -f /etc/udev/rules.d/60-h96-gamepad-hidraw.rules; udevadm control --reload 2>/dev/null
fi

# ---------------------------------------------------------------------------
if opt pad-xbox; then
say "5g/9  pads from other makers presented as Xbox 360 pads"
# Re-emit non-Microsoft xpad pads as Xbox 360 (045e:028e) via uinput, for engines matching by USB IDs; grabs the physical node.
wait_apt; apt-get install -y python3-evdev >/dev/null 2>&1 || warn "python3-evdev did not install; the pad service will not start"
cat > /usr/local/sbin/h96-pad-xbox <<'PADEOF'
#!/usr/bin/env python3
"""h96-pad-xbox: present XInput-class pads from other makers as a Microsoft Xbox 360 pad.

Games identify controllers by USB vendor and product ID. A pad in XInput mode from 8BitDo,
PowerA and others is driven by the kernel's xpad driver and works like an Xbox pad, but carries
its maker's IDs, so engines without a profile for that exact model (Rewired, InControl, older
SDL, Wine's XInput) ignore it or show it as unknown. This service grabs every xpad device whose
vendor is not Microsoft and re-emits it through uinput as "Microsoft X-Box 360 pad" 045e:028e,
which every engine maps. The physical node stays grabbed so nothing sees the pad twice. Rumble
is not forwarded.
"""
import glob, os, threading, time
import evdev
from evdev import UInput, ecodes

XBOX360 = dict(vendor=0x045E, product=0x028E, version=0x0114, name="Microsoft X-Box 360 pad")
active = {}   # physical path -> thread

def is_target(dev):
    try:
        drv = os.path.basename(os.readlink("/sys/class/input/%s/device/device/driver" % os.path.basename(dev.path)))
    except OSError:
        return False
    return drv == "xpad" and dev.info.vendor != XBOX360["vendor"]

def caps_of(dev):
    caps = {}
    for etype, codes in dev.capabilities(absinfo=True).items():
        if etype in (ecodes.EV_SYN, ecodes.EV_FF):
            continue
        caps[etype] = codes
    return caps

def forward(path):
    try:
        dev = evdev.InputDevice(path)
        if not is_target(dev):
            return
        ui = UInput(caps_of(dev), name=XBOX360["name"], vendor=XBOX360["vendor"],
                    product=XBOX360["product"], version=XBOX360["version"], bustype=ecodes.BUS_USB)
        dev.grab()
        print("h96-pad-xbox: %s (%04x:%04x '%s') -> %s" % (path, dev.info.vendor, dev.info.product, dev.name, ui.device.path), flush=True)
        for ev in dev.read_loop():
            ui.write_event(ev)
    except OSError:
        pass
    finally:
        try: ui.close()
        except Exception: pass
        print("h96-pad-xbox: %s gone" % path, flush=True)
        active.pop(path, None)

def main():
    while True:
        for path in glob.glob("/dev/input/event*"):
            if path in active:
                continue
            try:
                dev = evdev.InputDevice(path)
            except OSError:
                continue
            if is_target(dev):
                dev.close()
                t = threading.Thread(target=forward, args=(path,), daemon=True)
                active[path] = t
                t.start()
            else:
                dev.close()
        time.sleep(2)

if __name__ == "__main__":
    main()
PADEOF
chmod 755 /usr/local/sbin/h96-pad-xbox
cat > /etc/systemd/system/h96-pad-xbox.service <<'UNIT'
[Unit]
Description=Present XInput pads from other makers as Xbox 360 pads
After=systemd-udevd.service
[Service]
ExecStart=/usr/local/sbin/h96-pad-xbox
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now h96-pad-xbox >/dev/null 2>&1 && echo "  h96-pad-xbox running" || warn "h96-pad-xbox did not start (python3-evdev missing?)"
else
say "5g/9  pads presented as Xbox 360 pads: not selected"
systemctl disable --now h96-pad-xbox >/dev/null 2>&1
rm -f /usr/local/sbin/h96-pad-xbox /etc/systemd/system/h96-pad-xbox.service; systemctl daemon-reload
fi

# ---------------------------------------------------------------------------
say "6/9  pressure-vessel bwrap wrapper (inject FEX; do NOT close fds)"
# CRITICAL FIX 2: pressure-vessel passes bwrap args via --args FD; closing any fd breaks it.
cat > /usr/local/bin/fex-pv-bwrap <<'WRAP'
#!/bin/bash
exec /usr/bin/bwrap \
  --ro-bind /usr/lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu \
  --ro-bind /usr/share/fex-emu /usr/share/fex-emu \
  --ro-bind-try /run/user/__UID__/0.FEXServer.Socket /run/user/__UID__/0.FEXServer.Socket \
  --setenv FEX_ROOTFS / \
  "$@"
WRAP
sed -i "s/__UID__/$UID_N/g" /usr/local/bin/fex-pv-bwrap
chmod 755 /usr/local/bin/fex-pv-bwrap

# ---------------------------------------------------------------------------
say "7/9  launch script /home/$GAMEUSER/steam-fex-launch.sh"
LAUNCH="/home/$GAMEUSER/steam-fex-launch.sh"
VKSPOOF_LINE="# vk-spoof not selected"
opt vk-spoof && VKSPOOF_LINE='export H96_VK_SPOOF=1   # host Vulkan layer (installer step 5d): DXVK gets a device on the Mali driver; per title opt-out: H96_VK_SPOOF_DISABLE=1'
cat > "$LAUNCH" <<LAUNCHSCRIPT
#!/bin/bash
# Launch x86-64 Steam under FEX. Run as $GAMEUSER.
# Display: runs on X11 if DISPLAY's X socket is present, else headless gamescope.
# First run bootstraps without -noverifyfiles (fresh install skips it), waits for "Update complete", relaunches with it; later runs always need the flag (watcher changes file sizes, breaking verification).
set -u
export HOME="/home/$GAMEUSER"
export XDG_RUNTIME_DIR="/run/user/$UID_N"      # tmpfs, provided by systemd linger
export PRESSURE_VESSEL_BWRAP=/usr/local/bin/fex-pv-bwrap
export STEAM_RUNTIME=1
export LIBGL_ALWAYS_SOFTWARE=0   # games use the Mali GPU (Panfrost); CEF client stays software via -cef-disable-gpu flags
$VKSPOOF_LINE
export PATH="/usr/games:/usr/local/bin:\$PATH"   # gamescope lives in /usr/games
# Pin to big cores (A76; derived from cpu_capacity, not fixed numbering) since capacity-aware placement isn't guaranteed for emulated threads.
BIG=\$(for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "\$(cat \$c/cpu_capacity 2>/dev/null) \${c##*cpu}"; done | sort -rn | awk 'NR==1{m=\$1} \$1==m{printf "%s,",\$2}' | sed 's/,\$//')
[ "$OPT_BIG_CORES" = 1 ] && [ -n "\$BIG" ] && command -v taskset >/dev/null 2>&1 && taskset -pc "\$BIG" \$\$ >/dev/null 2>&1
# Load our patched native libX11 (X protocol errors non-fatal) into the FEX process only.
export LD_LIBRARY_PATH="/home/$GAMEUSER/.fex-emu/hostlib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
S="\$HOME/.local/share/Steam"
LOG="\$HOME/steam-fex.log"
CLIENT="\$S/ubuntu12_64/steamwebhelper"          # present once the client package is installed
# Client UI is software either way; these flags stop Chromium probing GPU paths and Steam's runtime-detect restart.
STEAM_FLAGS="-noverifyfiles -cef-disable-gpu -cef-disable-gpu-compositing"
cd "\$HOME"

# stage substitute bootstrapper fonts (real ones arrive with client download; chicken-and-egg)
FDIR="\$S/clientui/fonts"; mkdir -p "\$FDIR"
SUBFONT=\$(find "$RFS/usr/share/fonts" -iname DejaVuSans.ttf 2>/dev/null | head -1)
for f in GoNotoKurrent-Regular.ttf GoNotoKurrent-Bold.ttf GoNotoKurrent-Medium.ttf; do
  [ -f "\$FDIR/\$f" ] || cp -f "\$SUBFONT" "\$FDIR/\$f" 2>/dev/null
done

# CEF's separate network-service process fails the client's PID check; append --enable-features=NetworkServiceInProcess2 to steamwebhelper.sh (re-applied since updates overwrite it).
ensure_webhelper_flag(){
  local f="\$S/ubuntu12_64/steamwebhelper.sh"
  [ -f "\$f" ] || return 0
  grep -q 'NetworkServiceInProcess2' "\$f" && return 0
  sed -i 's|"\${DIR}/steamwebhelper_sniper_wrap.sh" "\$@"|"\${DIR}/steamwebhelper_sniper_wrap.sh" "\$@" --enable-features=NetworkServiceInProcess2|' "\$f" \
    && echo "\$(date '+%F %T') steam-fex: enabled NetworkServiceInProcess2 in steamwebhelper.sh" >> "\$LOG"
}
ensure_webhelper_flag
if [ -n "\${DISPLAY:-}" ] && [ -S "/tmp/.X11-unix/X\${DISPLAY#:}" ]; then MODE=x11; else MODE=headless; export STEAMOS=1; fi

# Restore the output's preferred mode/framebuffer if a crashed fullscreen title left it lower-res; only while no game is running.
restore_display(){
  [ "\${MODE:-}" = x11 ] || return 0
  command -v xrandr >/dev/null 2>&1 || return 0
  pgrep -f 'reaper SteamLaunch' >/dev/null 2>&1 && return 0
  local out cur pref
  out=\$(xrandr --current 2>/dev/null | awk '/ connected/{print \$1; exit}'); [ -n "\$out" ] || return 0
  # Indented lines are modes ("*"=current, "+"=preferred); the output line's own "+" is excluded by the indent check.
  cur=\$(xrandr --current 2>/dev/null | awk '/^ +[0-9]+x[0-9]+/ && /\\*/{print \$1; exit}')
  pref=\$(xrandr --current 2>/dev/null | awk '/^ +[0-9]+x[0-9]+/ && /\\+/{print \$1; exit}')
  [ -n "\$cur" ] && [ -n "\$pref" ] && [ "\$cur" != "\$pref" ] || return 0
  xrandr --output "\$out" --mode "\$pref" --pos 0x0 --fb "\$pref" 2>/dev/null \
    && echo "\$(date '+%F %T') steam-fex: display restored from \$cur to \$pref" >> "\$LOG"
}

# Watcher: nativize any x86 bwrap/srt-bwrap Steam extracts (hangs on userns handshake under FEX).
( while true; do
    ensure_webhelper_flag
    restore_display
    for b in \$(find "\$S" \( -name bwrap -o -name srt-bwrap -o -name pv-bwrap \) ! -name '*.x86' 2>/dev/null); do
      if [ "\$(od -An -tx1 -N4 "\$b" 2>/dev/null | tr -d ' ')" = "7f454c46" ] && \
         [ "\$(od -An -tu1 -j18 -N1 "\$b" 2>/dev/null | tr -d ' ')" = "62" ]; then
        mv "\$b" "\$b.x86" 2>/dev/null && cp -f /usr/bin/bwrap "\$b" 2>/dev/null
      fi
    done
    sleep 2
  done ) &
WATCHER=\$!
trap 'kill \$WATCHER 2>/dev/null' EXIT

# Fallback if the "Unexpected Transport Error" dialog still appears despite ensure_webhelper_flag: click "Continue Anyway" via xdotool (libX11 patch makes the resulting X errors non-fatal).
dismiss_transport_dialog(){
  command -v xdotool >/dev/null 2>&1 || return 0
  local W p0
  while true; do
    W=\$(xdotool search --name "Unexpected Transport Error" 2>/dev/null | head -1)
    if [ -n "\$W" ] && [ "\$(xdotool getwindowgeometry "\$W" 2>/dev/null | awk '/Geometry/{print \$2}')" = "700x350" ]; then
      p0=\$(xdotool getmouselocation --shell 2>/dev/null | awk -F= '/^X=/{x=\$2}/^Y=/{y=\$2}END{print x, y}')
      xdotool windowraise "\$W" 2>/dev/null
      xdotool mousemove --window "\$W" 40 208 click 1 mousemove --window "\$W" 489 326 click 1 mousemove \$p0 2>/dev/null
      echo "\$(date '+%F %T') steam-fex: answered transport dialog (Continue Anyway), pointer restored to \$p0" >> "\$LOG"
      sleep 3
    fi
    sleep 1
  done
}
if [ "\$MODE" = x11 ]; then dismiss_transport_dialog & DISMISSER=\$!; trap 'kill \$WATCHER \$DISMISSER 2>/dev/null' EXIT; fi
echo "\$(date '+%F %T') steam-fex: mode=\$MODE client=\$([ -x "\$CLIENT" ] && echo present || echo missing)" >> "\$LOG"

run_steam(){   # \$@ = steam arguments; foreground
  if [ "\$MODE" = x11 ]; then
    FEXBash -c "cd \$HOME; exec /usr/bin/steam \$*"
  else
    dbus-run-session -- gamescope --backend headless -W 1280 -H 720 -- FEXBash -c "cd \$HOME; exec /usr/bin/steam \$*"
  fi
}
stop_steam(){
  pkill -u "$GAMEUSER" -f "\$S/steam.sh" 2>/dev/null; pkill -u "$GAMEUSER" -f "ubuntu12_32/steam" 2>/dev/null
  pkill -u "$GAMEUSER" -f steamwebhelper 2>/dev/null
  [ "\$MODE" = headless ] && pkill -u "$GAMEUSER" -x gamescope 2>/dev/null
  sleep 3
  pkill -9 -u "$GAMEUSER" -f "ubuntu12_32/steam" 2>/dev/null; pkill -9 -u "$GAMEUSER" -f steamwebhelper 2>/dev/null
}

FEXServer -p 999999 >/dev/null 2>&1 & sleep 1

if [ ! -x "\$CLIENT" ]; then
  echo "first run: downloading the Steam client (about 2.4 GB), bootstrap pass without -noverifyfiles" | tee -a "\$LOG"
  run_steam >> "\$LOG" 2>&1 &
  BP=\$!
  for i in \$(seq 1 540); do    # up to 90 min
    if [ -x "\$CLIENT" ] && grep -q "Update complete, launching Steam" "\$S/logs/bootstrap_log.txt" 2>/dev/null; then
      sleep 5; break
    fi
    kill -0 \$BP 2>/dev/null || break
    sleep 10
  done
  stop_steam; wait \$BP 2>/dev/null
  if [ ! -x "\$CLIENT" ]; then
    echo "client download did not finish; see \$LOG and \$S/logs/bootstrap_log.txt" | tee -a "\$LOG"; exit 1
  fi
  echo "client installed; relaunching Steam with \$STEAM_FLAGS" | tee -a "\$LOG"
fi
run_steam \$STEAM_FLAGS "\$@" >> "\$LOG" 2>&1
LAUNCHSCRIPT
chmod 755 "$LAUNCH"; chown "$GAMEUSER:$GAMEUSER" "$LAUNCH"

# ---------------------------------------------------------------------------
say "8/9  'steam-fex' command, application menu entry and desktop icon"
# Run as root: gamescope/wlroots and CEF need /dev/shm as a 1777 tmpfs. Ensure it each launch.
cat > /usr/local/bin/steam-fex <<CMD
#!/bin/sh
# Root half of launch; desktop entry runs this as the game user via passwordless sudoers.d/h96-steam-fex.
if [ "\$(id -u)" != 0 ]; then exec sudo -n --preserve-env=DISPLAY,XAUTHORITY /usr/local/bin/steam-fex "\$@"; fi
# Nativize RootFS bwrap (an x86 copy deadlocks steamwebhelper's container); game user can't touch /opt itself.
RB="$RFS/usr/bin/bwrap"
if [ "\$(od -An -tu1 -j18 -N1 "\$RB" 2>/dev/null | tr -d ' ')" = "62" ]; then
  mv -f "\$RB" "\$RB.x86" 2>/dev/null; cp -f /usr/bin/bwrap "\$RB"; chmod 0755 "\$RB"
fi
# Re-apply little-core IRQ affinity (h96-perf-tune) in case its boot unit didn't run.
[ -x /usr/local/sbin/h96-irq-affinity ] && /usr/local/sbin/h96-irq-affinity
# Private Mesa GLX copy for the GL thunk (see installer step 5c); rebuilt after a Mesa update.
[ -x /usr/local/sbin/h96-glx-lax ] && /usr/local/sbin/h96-glx-lax
if ! grep -q ' /dev/shm ' /proc/mounts || [ "\$(stat -c %a /dev/shm 2>/dev/null)" != 1777 ]; then
  mount -t tmpfs -o rw,nosuid,nodev,mode=1777 tmpfs /dev/shm 2>/dev/null; chmod 1777 /dev/shm 2>/dev/null
fi
# hand the desktop X display through when the game user has one (KDE autologin); else headless
if [ -z "\${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X0 ] && [ -f "/home/$GAMEUSER/.Xauthority" ]; then
  export DISPLAY=:0 XAUTHORITY="/home/$GAMEUSER/.Xauthority"
fi
exec sudo --preserve-env=DISPLAY,XAUTHORITY -u "$GAMEUSER" "/home/$GAMEUSER/steam-fex-launch.sh" "\$@"
CMD
chmod 755 /usr/local/bin/steam-fex

# Per-title launch options (Steam closed, it rewrites the file on exit); e.g. Godot 4 needs a Vulkan-splash-freeze workaround:
#   h96-steam-launchopts <appid> 'MESA_GL_VERSION_OVERRIDE=3.3 MESA_GLSL_VERSION_OVERRIDE=330 %command% --rendering-driver opengl3'
cat > /usr/local/lib/h96-steam-launchopts.py <<'PYEOF'
#!/usr/bin/env python3
# Insert or replace "LaunchOptions" for one app inside Steam's localconfig.vdf (apps/<id> block).
import re, sys, shutil
path, appid, opts = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8", errors="surrogateescape").read()
m = re.search(r'(\n(\t+)"%s"\n\2\{\n)' % re.escape(appid), s)
if not m:
    print("app block not found (start the title once from Steam first)", file=sys.stderr); sys.exit(1)
start = m.end(); ind = m.group(2) + "\t"
end = s.find("\n" + m.group(2) + "}", start)
block = s[start:end]
line = '%s"LaunchOptions"\t\t"%s"\n' % (ind, opts.replace('"', '\\"'))
if re.search(r'^\t+"LaunchOptions"\t\t".*"\n', block, re.M):
    block2 = re.sub(r'^\t+"LaunchOptions"\t\t".*"\n', line, block, count=1, flags=re.M); action = "replaced"
else:
    block2 = line + block; action = "inserted"
shutil.copy(path, path + ".bak-h96")
open(path, "w", encoding="utf-8", errors="surrogateescape").write(s[:start] + block2 + s[end:])
print("LaunchOptions %s for app %s" % (action, appid))
PYEOF
cat > /usr/local/bin/h96-steam-launchopts <<CMD
#!/bin/sh
# usage: h96-steam-launchopts <appid> '<launch options>'   (run as root with Steam closed)
[ \$# -eq 2 ] || { echo "usage: h96-steam-launchopts <appid> '<launch options>'" >&2; exit 2; }
pgrep -f 'ubuntu12_32/steam ' >/dev/null && { echo "close Steam first (it rewrites the file on exit)" >&2; exit 1; }
U=\$(ls -d /home/$GAMEUSER/.local/share/Steam/userdata/[0-9]* 2>/dev/null | head -1)
[ -n "\$U" ] || { echo "no Steam user data yet" >&2; exit 1; }
python3 /usr/local/lib/h96-steam-launchopts.py "\$U/config/localconfig.vdf" "\$1" "\$2" && chown $GAMEUSER:$GAMEUSER "\$U/config/localconfig.vdf"
CMD
chmod 755 /usr/local/bin/h96-steam-launchopts

if opt desktop; then
# Passwordless elevation; SETENV lets DISPLAY/XAUTHORITY survive sudo's environment reset.
printf '%s ALL=(root) NOPASSWD:SETENV: /usr/local/bin/steam-fex\n' "$GAMEUSER" > /etc/sudoers.d/h96-steam-fex
chmod 440 /etc/sudoers.d/h96-steam-fex
visudo -cf /etc/sudoers.d/h96-steam-fex >/dev/null 2>&1 || die "sudoers.d/h96-steam-fex does not validate"

# App menu/KRunner entry and desktop icon; icon files come from the Steam package in the RootFS.
for sz in 16 32 48 256; do
  src="$RFS/usr/share/icons/hicolor/${sz}x${sz}/apps/steam.png"
  [ -f "$src" ] || continue
  mkdir -p "/usr/share/icons/hicolor/${sz}x${sz}/apps"
  cp -f "$src" "/usr/share/icons/hicolor/${sz}x${sz}/apps/h96-steam-fex.png"
done
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null
cat > /usr/share/applications/h96-steam-fex.desktop <<DESK
[Desktop Entry]
Type=Application
Name=Steam
GenericName=Game store and launcher
Comment=Steam client (x86-64) through FEX-Emu; games render on the GPU
Exec=/usr/local/bin/steam-fex %U
Icon=h96-steam-fex
Terminal=false
Categories=Game;
Keywords=steam;valve;games;fex;
MimeType=x-scheme-handler/steam;
StartupNotify=false
DESK
chmod 644 /usr/share/applications/h96-steam-fex.desktop
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications 2>/dev/null
# Plasma trusts an executable .desktop in the Desktop folder (no confirmation prompt needed).
DESKDIR="/home/$GAMEUSER/Desktop"
mkdir -p "$DESKDIR"; chown "$GAMEUSER:$GAMEUSER" "$DESKDIR"
cp -f /usr/share/applications/h96-steam-fex.desktop "$DESKDIR/Steam.desktop"
chmod 755 "$DESKDIR/Steam.desktop"; chown "$GAMEUSER:$GAMEUSER" "$DESKDIR/Steam.desktop"
# Rebuild the running KDE session's application cache so search finds the entry now.
if [ -S /tmp/.X11-unix/X0 ]; then
  sudo -u "$GAMEUSER" env DISPLAY=:0 XDG_RUNTIME_DIR="/run/user/$UID_N" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
    sh -c 'command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental || kbuildsycoca5 --noincremental' >/dev/null 2>&1 || true
fi
else
echo "  desktop entry not selected: steam-fex runs from a root shell (sudo steam-fex)"
rm -f /etc/sudoers.d/h96-steam-fex /usr/share/applications/h96-steam-fex.desktop "/home/$GAMEUSER/Desktop/Steam.desktop"
for sz in 16 32 48 256; do rm -f "/usr/share/icons/hicolor/${sz}x${sz}/apps/h96-steam-fex.png"; done
fi

# ---------------------------------------------------------------------------
say "9/9  done"
LAUNCHHINT="sudo steam-fex in a terminal (or: sudo -u $GAMEUSER $LAUNCH)"
opt desktop && LAUNCHHINT="the Steam icon on the desktop, \"Steam\" in the application menu or search,
            or steam-fex in a terminal (or: sudo -u $GAMEUSER $LAUNCH)"
SELECTED=""; for c in $COMPONENTS; do opt "$c" && SELECTED="$SELECTED $c"; done
cat <<DONE

Steam-under-FEX installed. Optional components:${SELECTED:- none}
  (re-run with --select or --skip to change; see --help)

  Launch:   $LAUNCHHINT
  First run downloads the ~2.4 GB Steam client in a bootstrap pass, stops, then relaunches
  with -noverifyfiles. With a desktop session Steam shows on it; otherwise it renders into
  headless gamescope. It is logged out until you log in.

Notes:
  - Client UI is software rendered (see H96-STEAM-FEX-RECIPE.md). Games render on the
    Mali GPU through the GL and Vulkan thunks.
  - Games that bind one GL context from several threads run through a private Mesa GLX
    copy (libGLX_h96lax, step 5c); h96-glx-lax rebuilds it after a Mesa update.
  - Windows titles (Proton) get a Direct3D device through DXVK because a host Vulkan layer
    (step 5d) reports the features DXVK requires but the Mali driver lacks. A title that
    uses one of them can opt out with H96_VK_SPOOF_DISABLE=1 in its launch options.
  - box64 binfmt is disabled for FEX (h96-fex-binfmt.service). Gaming stack that calls
    box64 explicitly still works; binfmt auto-exec of x86 is FEX's.
DONE
