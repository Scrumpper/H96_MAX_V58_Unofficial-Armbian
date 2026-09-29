#!/bin/bash
# h96-steam-arm-install: installs Valve's native ARM64 Steam client. x86 titles run through the
# emulator against an x86-64 RootFS; Proton runs the ARM64 build; Remote Play uses the package's
# x86-64 streaming client under the emulator with software decoding.
#
# Run as root: sudo bash h96-steam-arm-install.sh
# Launch: steam-arm (as the game user)
#
# Core: host packages, RootFS, graphics provider, client package, launcher. Optional components
# (on by default except pad-xbox):
#   glx-lax          private Mesa GLX copy for titles binding one GL context from several threads
#   vk-spoof         host Vulkan layer reporting features DXVK needs but the Mali driver lacks
#   map-count        raise vm.max_map_count to the SteamOS value
#   xpad-dedup       drop the duplicate joystick node some third-party Xbox pads expose
#   pad-hidraw       hidraw access so the client can read pads directly
#   pad-xbox         present other makers' XInput pads as Xbox 360 pads (off by default)
#   desktop          menu entry and window frame rule for the desktop interface
#   desktop-mode     second menu entry for the desktop interface
#   icon-bigpicture  desktop icon "Steam ARM"
#   icon-desktop     desktop icon "Steam ARM (Desktop mode)"
#   tray             Steam icon in the panel tray
#   page-size        Raspberry Pi 5: select firmware's 4K page kernel (reboot, then run again)
# Options: --defaults | --keep | --select a,b,c | --skip a,b | --list | --help | --replace-other
# Selection saved in /etc/h96/steam-arm.conf; --keep or a non-terminal run reuses it.
#
# Page size: emulation needs 4K pages. STEAM_ARM_IGNORE_PAGESIZE=1 skips the check.
#
# Coexists with h96-steam-fex-install.sh; keeps its own home (ARMHOME_DIR) and library.
# Idempotent. Installed games, sign-in and settings are kept; only the client program folder is
# replaced. Experimental: not part of the shipped image.
set -u
# Self-contained: no board-specific banner helper assumed. TTY-gated, honours NO_COLOR.
steam_banner() {
    [ -t 1 ] || return 0
    local C=$'\033[96m' D=$'\033[2m' B=$'\033[1m' X=$'\033[0m'
    [ -n "${NO_COLOR:-}" ] && { C=; D=; B=; X=; }
    local line; line=$(printf '\u2500%.0s' $(seq 1 62))
    printf '\n%s  %s%s\n' "$D" "$line" "$X"
    printf '%s   %s%s\n' "${C}${B}" "$1" "$X"
    printf '%s   %s%s\n' "$D" "$2" "$X"
    printf '%s  %s%s\n\n' "$D" "$line" "$X"
}

say(){ printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[fail]\033[0m %s\n' "$*"; exit 1; }
GAMEPASS="${GAMEPASS:-}"
# pad-xbox is off by default: the client's own Steam Input already re-identifies pads.
DEFAULT_OFF="${DEFAULT_OFF:-pad-xbox}"
# Client home: env var, then saved setting, then default; re-run never moves games.
ARMHOME_DIR="${ARMHOME_DIR:-$(sed -n 's/^ARMHOME_DIR=//p' /etc/h96/steam-arm.conf 2>/dev/null | tail -1)}"
ARMHOME_DIR="${ARMHOME_DIR:-.local/share/h96-steam-arm}"
# Settings file also read by launcher and tray; installer updates only its own keys.
CONF=/etc/h96/steam-arm.conf
conf_get(){ sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -1; }
conf_set(){
  local t; [ -f "$CONF" ] || : > "$CONF" || die "could not write $CONF"
  t=$(mktemp "$CONF.XXXXXX") || die "could not write $CONF"
  awk -v k="$1=" -v v="$1=$2" 'index($0, k) == 1 { if (!d) print v; d = 1; next } { print } END { if (!d) print v }' "$CONF" > "$t" \
    && chmod 644 "$t" && mv -f "$t" "$CONF" || { rm -f "$t"; die "could not write $CONF"; }
}
# Account: env var, then saved config, then existing client home, then uid 1000; else h96steam is created with a generated password.
# Only an env GAMEUSER or the final h96steam fallback may create an account; a conf/detected
# name must already exist here, else a restored conf naming a foreign user creates it.
GAMEUSER_MAY_CREATE=0
if [ -n "${GAMEUSER:-}" ]; then
  GAMEUSER_MAY_CREATE=1
else
  GAMEUSER="$(conf_get GAMEUSER)"
  if [ -n "$GAMEUSER" ] && ! getent passwd "$GAMEUSER" >/dev/null 2>&1; then
    warn "conf GAMEUSER='$GAMEUSER' has no account on this box; ignored"
    GAMEUSER=
  fi
fi
if [ -z "$GAMEUSER" ] && [ -f "$CONF" ]; then
  GAMEUSER=$(getent passwd | while IFS=: read -r u _ id _ _ h _; do
    [ "$id" -ge 1000 ] 2>/dev/null && [ -d "$h/$ARMHOME_DIR/.local/share/Steam" ] && echo "$u"; done)
  [ "$(printf '%s\n' "$GAMEUSER" | wc -l)" = 1 ] || GAMEUSER=
fi
GAMEUSER="${GAMEUSER:-$(getent passwd 1000 2>/dev/null | cut -d: -f1)}"
if [ -z "$GAMEUSER" ]; then GAMEUSER=h96steam; GAMEUSER_MAY_CREATE=1; fi
RFS=/opt/fex-rootfs/Ubuntu_24_04
FEXPPA="ppa:fex-emu/fex"
MANIFEST=https://client-update.fastly.steamstatic.com/steam_client_publicbeta_linuxarm64
CDN=https://client-update.steamstatic.com
COMPONENTS="glx-lax vk-spoof map-count xpad-dedup pad-hidraw pad-xbox desktop desktop-mode icon-bigpicture icon-desktop tray page-size"
desc_of(){ case "$1" in
  glx-lax)    echo "Private Mesa GLX copy, for GL contexts bound from several threads";;
  vk-spoof)   echo "Vulkan feature layer: DXVK device on the Mali driver (Proton titles)";;
  map-count)  echo "vm.max_map_count raised to the SteamOS value (Proton warns below it)";;
  xpad-dedup) echo "Drop the duplicate joystick node of third-party Xbox 360 style pads";;
  pad-hidraw) echo "Let the client read pads directly, for rumble and battery level";;
  pad-xbox)   echo "Present other makers' XInput pads as Xbox 360 pads (client does this itself)";;
  desktop)    echo "Menu entry \"Steam ARM\", and title bar for desktop interface windows";;
  desktop-mode) echo "Menu entry \"Steam ARM (Desktop mode)\": desktop interface, for signing in";;
  icon-bigpicture) echo "Desktop icon \"Steam ARM\"";;
  icon-desktop) echo "Desktop icon \"Steam ARM (Desktop mode)\"";;
  tray)       echo "Steam icon in the panel tray, with Open, desktop mode and Stop";;
  page-size)  echo "Raspberry Pi 5: boot firmware's 4K page kernel (no effect elsewhere)";;
esac; }
var_of(){ echo "OPT_$(echo "$1" | tr 'a-z-' 'A-Z_')"; }
for c in $COMPONENTS; do eval "$(var_of "$c")=1"; done
# pad-xbox opt-in: it grabs the physical pad, starving a title that opens it directly.
for c in ${DEFAULT_OFF:-}; do eval "$(var_of "$c")=0"; done
usage(){
  local c mark
  cat <<'USAGE'
Usage: sudo h96-steam install [--defaults | --select a,b,... | --skip a,b,...]
       h96-steam install --list | --help

Installs Valve's native ARM64 Steam client for the desktop user, with the pieces it
needs on this system. Nothing downloads until this command runs.

Options
  (none)            checklist of components: keyboard list in terminal, dialog
                    (zenity) on desktop when started without terminal
  --defaults        recommended components, no questions
  --keep            components saved by last run, no questions (recommended set if none)
  --select a,b      exactly these components
  --skip a,b        recommended components, without these
  --list            print components and exit
  --help            print this text and exit
  --replace-other   install even when other flavour of this installer is present;
                    its steam-arm and steamos-session-select commands are replaced

Always installed: host packages, x86-64 root filesystem, client package, launcher.

Components (* = on by default)
USAGE
  for c in $COMPONENTS; do
    mark=" "; eval "[ \"\$$(var_of "$c")\" = 1 ]" && mark="*"
    printf '  %s %-16s %s\n' "$mark" "$c" "$(desc_of "$c")"
  done
  cat <<'USAGE'

Examples
  sudo h96-steam install --defaults
  sudo h96-steam install --skip tray                           no tray icon
  sudo h96-steam install --skip icon-bigpicture,icon-desktop   no desktop icons
  sudo h96-steam install --select desktop,desktop-mode         menu entries only
  sudo env GAMEUSER=alice h96-steam install --defaults         install for account alice

Re-running
  --keep, and any run without terminal or dialog, reuse account and components saved
  by last run; checklist and dialog start from them.
  A component left out on a later run is removed again. Installed games, sign-in
  and settings are kept: install, re-run, component changes and package upgrades
  never touch the game library.

After install
  Start "Steam ARM" from the menu, or run: steam-arm
  Sign in from "Steam ARM (Desktop mode)". The first start downloads the client
  and restarts it once.

Environment
  GAMEUSER=name                account to install into (default: account of last run,
                               else uid 1000)
  STEAM_ARM_IGNORE_PAGESIZE=1  skip the 4K page size check

Documentation: COMMANDS.md on the image, and h96-steam --help

This project is not affiliated with, endorsed by or sponsored by Valve Corporation.
Steam, Proton and Steam Deck are trademarks of Valve Corporation.
USAGE
}
MODE=ask; REPLACE_OTHER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --defaults) MODE=defaults;;
    --keep)     MODE=keep;;
    --replace-other) REPLACE_OTHER=1;;
    --select)   MODE=select; SEL="${2:-}"; shift;;
    --select=*) MODE=select; SEL="${1#*=}";;
    --skip)     MODE=skip; SEL="${2:-}"; shift;;
    --skip=*)   MODE=skip; SEL="${1#*=}";;
    --list)     for c in $COMPONENTS; do printf '  %-16s %s\n' "$c" "$(desc_of "$c")"; done; exit 0;;
    -h|--help)  usage; exit 0;;
    *) die "unknown option: $1 (see --help)";;
  esac; shift
done
known(){ for c in $COMPONENTS; do [ "$c" = "$1" ] && return 0; done; return 1; }
# Component whose files are in place (install from before selection was saved in $CONF).
installed(){ case "$1" in
  glx-lax)    [ -e /usr/local/sbin/h96-glx-lax ];;
  vk-spoof)   [ -e /usr/share/vulkan/implicit_layer.d/VkLayer_h96_spoof.json ];;
  map-count)  [ -e /etc/sysctl.d/zz-h96-steam.conf ];;
  xpad-dedup) [ -e /etc/udev/rules.d/71-h96-xpad-dedup.rules ];;
  pad-hidraw) [ -e /etc/udev/rules.d/60-h96-gamepad-hidraw.rules ];;
  pad-xbox)   [ -e /etc/systemd/system/h96-pad-xbox.service ];;
  desktop)    [ -e /usr/share/applications/h96-steam-arm.desktop ];;
  desktop-mode) [ -e /usr/share/applications/h96-steam-arm-desktop.desktop ];;
  icon-bigpicture) [ -e "$2/Desktop/Steam ARM.desktop" ];;
  icon-desktop) [ -e "$2/Desktop/Steam ARM (Desktop mode).desktop" ];;
  tray)       [ -e /usr/local/bin/h96-steam-tray ];;
  page-size)  grep -qs '^# h96-steam page-size:' /boot/firmware/config.txt /boot/config.txt;;
  *)          return 1;;
esac; }
# Prior selection from $CONF, else inferred from installed files; returns 1 if none.
prior_selection(){
  local c on= off= uh
  if grep -q '^COMPONENTS_ON=' "$CONF" 2>/dev/null; then
    on=$(conf_get COMPONENTS_ON); off=$(conf_get COMPONENTS_OFF)
  elif [ -f "$CONF" ] && [ -x /usr/local/bin/steam-arm ]; then
    uh=$(getent passwd "$GAMEUSER" | cut -d: -f6)
    for c in $COMPONENTS; do if installed "$c" "$uh"; then on="$on,$c"; else off="$off,$c"; fi; done
  else
    return 1
  fi
  for c in $(echo "$on" | tr ',' ' '); do known "$c" && eval "$(var_of "$c")=1"; done
  for c in $(echo "$off" | tr ',' ' '); do known "$c" && eval "$(var_of "$c")=0"; done
  return 0
}
case "$MODE" in
  select) for c in $COMPONENTS; do eval "$(var_of "$c")=0"; done
          for c in $(echo "$SEL" | tr ',' ' '); do known "$c" || die "unknown component: $c"; eval "$(var_of "$c")=1"; done;;
  skip)   for c in $(echo "$SEL" | tr ',' ' '); do known "$c" || die "unknown component: $c"; eval "$(var_of "$c")=0"; done;;
  keep)   prior_selection;;
  ask)    if prior_selection; then PRIOR=1; else PRIOR=0; fi
          if [ -t 0 ] && [ -t 1 ]; then
            # Note the picker is keyboard-only, and name the flags that skip it.
            printf '\n  Components: --defaults takes the recommended set, --select a,b takes exactly\n'
            printf '  those, --skip a,b takes the defaults without them, --list prints them all.\n'
            [ "$PRIOR" = 1 ] && printf '  Checklist starts from selection of last run; --keep reuses it without asking.\n'
            echo
            if command -v whiptail >/dev/null 2>&1; then
              args=(); for c in $COMPONENTS; do
                args+=("$c" "$(desc_of "$c")" "$(eval "[ \"\$$(var_of "$c")\" = 1 ]" && echo ON || echo OFF)")
              done
              chosen=$(whiptail --title "Native ARM64 Steam" --checklist "Optional components.\n\nSPACE toggles the item under the cursor.  TAB moves to the buttons.  ENTER confirms.\nThis list is keyboard driven; a mouse click does nothing." 28 100 12 "${args[@]}" 3>&1 1>&2 2>&3) || die "cancelled"
              for c in $COMPONENTS; do eval "$(var_of "$c")=0"; done
              for c in $chosen; do c=${c//\"/}; eval "$(var_of "$c")=1"; done
            else
              for c in $COMPONENTS; do
                if eval "[ \"\$$(var_of "$c")\" = 1 ]"; then
                  printf '  %-16s %s [Y/n] ' "$c" "$(desc_of "$c")"; read -r a
                  case "$a" in n|N) eval "$(var_of "$c")=0";; esac
                else
                  printf '  %-16s %s [y/N] ' "$c" "$(desc_of "$c")"; read -r a
                  case "$a" in y|Y) eval "$(var_of "$c")=1";; esac
                fi
              done
            fi
          elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1 \
               && ! { : </dev/tty; } 2>/dev/null; then
            # No controlling terminal but graphical session: same checklist as dialog; no reachable display keeps preset.
            args=(); for c in $COMPONENTS; do
              args+=("$(eval "[ \"\$$(var_of "$c")\" = 1 ]" && echo TRUE || echo FALSE)" "$c" "$(desc_of "$c")")
            done
            zerr=$(mktemp); rc=0
            chosen=$(zenity --list --checklist --title="Native ARM64 Steam" --text="Optional components" \
              --column="Install" --column="Component" --column="Description" --print-column=2 --separator=' ' \
              --width=900 --height=560 "${args[@]}" 2>"$zerr") || rc=$?
            if [ "$rc" = 0 ]; then
              for c in $COMPONENTS; do eval "$(var_of "$c")=0"; done
              for c in $chosen; do known "$c" && eval "$(var_of "$c")=1"; done
            elif [ "$rc" = 1 ] && ! grep -qiE '(cannot|failed to|unable to) open display' "$zerr"; then
              rm -f "$zerr"; die "cancelled"
            else
              warn "component dialog failed (status $rc); using preset selection"
            fi
            rm -f "$zerr"
          fi;;
esac
opt(){ eval "[ \"\$$(var_of "$1")\" = 1 ]"; }

# Detect the other installer flavour (same launcher paths, marked by /etc/steam-arm/steam-arm.conf); stop unless --replace-other.
if grep -qs '/etc/steam-arm/steam-arm.conf' /usr/local/bin/steam-arm; then
  [ "$REPLACE_OTHER" = 1 ] || die "/usr/local/bin/steam-arm belongs to other flavour of this installer (it
       reads /etc/steam-arm/steam-arm.conf). Both flavours write steam-arm and steamos-session-select.
       Pass --replace-other to install anyway; its commands are then replaced by this flavour."
  warn "steam-arm of other flavour found; --replace-other given, its commands are replaced"
fi

# --- page size ---
# Emulation needs 4K pages; Pi firmware ships a 4K kernel as an alternative, selected by page-size. STEAM_ARM_TEST_* vars fake the system for testing.
PAGESIZE=${STEAM_ARM_TEST_PAGESIZE:-$(getconf PAGESIZE 2>/dev/null || echo 4096)}
MODEL=${STEAM_ARM_TEST_MODEL-$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)}
FWDIR=${STEAM_ARM_TEST_FWDIR:-/boot/firmware}
[ -f "$FWDIR/config.txt" ] || { [ -z "${STEAM_ARM_TEST_FWDIR:-}" ] && [ -f /boot/config.txt ] && FWDIR=/boot; }
FWCFG="$FWDIR/config.txt"
PS_BEGIN="# h96-steam page-size: 4K page kernel for x86 emulation. Remove this block to undo."
PS_END="# end h96-steam page-size"
is_pi(){ case "$MODEL" in "Raspberry Pi"*) [ -f "$FWCFG" ];; *) return 1;; esac; }
ps_block(){ [ -f "$FWCFG" ] && grep -qxF "$PS_BEGIN" "$FWCFG"; }
ps_remove(){
  local t; t=$(awk -v b="$PS_BEGIN" -v e="$PS_END" '$0==b{s=1} !s{print} $0==e{s=0}' "$FWCFG") || return 1
  printf '%s\n' "$t" > "$FWCFG"
}
if [ "$PAGESIZE" = 4096 ]; then
  if is_pi && ps_block && ! opt page-size; then
    [ "$(id -u)" = 0 ] || die "run as root"
    ps_remove || die "could not edit $FWCFG"
    warn "page-size deselected: 4K kernel line removed from $FWCFG. After next reboot, firmware"
    warn "loads its default kernel, and x86 titles stop running until page-size is selected again."
  fi
elif [ "${STEAM_ARM_IGNORE_PAGESIZE:-0}" = 1 ]; then
  warn "page size is $PAGESIZE, not 4096; continuing because STEAM_ARM_IGNORE_PAGESIZE=1."
  warn "x86 titles run only if this system provides its own 4K environment for them."
elif is_pi; then
  opt page-size || die "page size is $PAGESIZE and emulation needs 4096. Select page-size
       component, or add kernel=kernel8.img to $FWCFG yourself and reboot."
  [ "$(id -u)" = 0 ] || die "run as root"
  if ps_block; then
    say "4K page kernel already selected in $FWCFG; reboot, then run sudo h96-steam install again."
    exit 0
  fi
  [ -f "$FWDIR/kernel8.img" ] || die "page size is $PAGESIZE and $FWDIR has no kernel8.img (4K page
       kernel). Install your distribution's 4K kernel package, then run this again."
  if grep -qE '^[[:space:]]*kernel[[:space:]]*=' "$FWCFG"; then
    die "$FWCFG already sets kernel itself: $(grep -E '^[[:space:]]*kernel[[:space:]]*=' "$FWCFG" | head -1)
       Point it at kernel8.img (4K pages) and reboot, then run this again."
  fi
  [ -f "$FWCFG.steam-arm.bak" ] || cp -p "$FWCFG" "$FWCFG.steam-arm.bak" || die "could not back up $FWCFG"
  [ -n "$(tail -c1 "$FWCFG")" ] && echo >> "$FWCFG"   # file ending without a newline
  printf '%s\n[all]\nkernel=kernel8.img\n%s\n' "$PS_BEGIN" "$PS_END" >> "$FWCFG" || die "could not edit $FWCFG"
  say "page size is $PAGESIZE: $FWCFG now selects 4K page kernel (kernel8.img)."
  say "     previous file kept as $FWCFG.steam-arm.bak"
  say "     reboot, then run sudo h96-steam install again to install."
  exit 0
else
  case "$MODEL" in
    Apple*) die "page size is $PAGESIZE (Apple Silicon) and emulation needs 4096. Kernel on this
       hardware stays at 16K; x86 side has to run inside 4K virtual machine, such as muvm,
       which this installer does not set up. STEAM_ARM_IGNORE_PAGESIZE=1 skips this check.";;
  esac
  die "page size is $PAGESIZE and emulation needs 4096. Boot 4K page kernel (on most
       distributions, separate kernel package), then run this again.
       STEAM_ARM_IGNORE_PAGESIZE=1 skips this check."
fi
[ "$(id -u)" = 0 ] || die "run as root"

# wait for any boot-time apt/dpkg (unattended-upgrades, armbian online-extras) to release the lock
wait_apt(){
  local n=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ $n = 0 ] && warn "another apt/dpkg is running; waiting for the lock..."
    sleep 5; n=$((n+5)); [ $n -ge 600 ] && die "dpkg lock still held after 10 min"
  done
}

steam_banner "Native ARM64 Steam client setup" \
             "Valve's ARM Linux client, x86 titles through the emulation tool it downloads"
printf 'Optional components:'; for c in $COMPONENTS; do opt "$c" && printf ' %s' "$c" || printf ' [no %s]' "$c"; done; echo
say "1/11  host packages"
export DEBIAN_FRONTEND=noninteractive
wait_apt
# FEX (system emulator) serves Remote Play and the thunk libraries the RootFS config points at.
if ! command -v FEX >/dev/null 2>&1; then
  command -v add-apt-repository >/dev/null || apt-get install -y software-properties-common
  grep -rq "fex-emu/fex" /etc/apt/sources.list.d/ 2>/dev/null || add-apt-repository -y "$FEXPPA"
fi
wait_apt; apt-get update -y
BUILDPKGS=""; opt vk-spoof && BUILDPKGS="gcc libc6-dev libvulkan-dev"
opt glx-lax && BUILDPKGS="$BUILDPKGS patchelf"
want_icons(){ opt desktop || opt desktop-mode || opt icon-bigpicture || opt icon-desktop; }
want_icons && BUILDPKGS="$BUILDPKGS python3-pil"                                     # menu and desktop icons
opt tray && BUILDPKGS="$BUILDPKGS gir1.2-ayatanaappindicator3-0.1"                   # tray helper binding
wait_apt; apt-get install -y fex-emu-armv8.2 fex-emu-binfmt32 fex-emu-binfmt64 bubblewrap dbus-daemon xz-utils \
  libsdl3-0 libsdl3-image0 libsdl3-ttf0 libgtk2.0-0t64 libopenal1 zenity xdotool curl python3 file $BUILDPKGS
command -v FEX >/dev/null || die "FEX did not install"
for l in libSDL3.so.0 libopenal.so.1 libgtk-x11-2.0.so.0; do ldconfig -p | grep -q "$l" || die "$l missing after install"; done
# FEX owns x86 execution (box64/box32 binfmt off), persistent
echo 0 > /proc/sys/fs/binfmt_misc/box64 2>/dev/null || true
echo 0 > /proc/sys/fs/binfmt_misc/box32 2>/dev/null || true
if [ ! -f /etc/systemd/system/h96-fex-binfmt.service ]; then
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
fi

say "2/11  game user '$GAMEUSER', /dev/shm, kernel limits"
if ! id "$GAMEUSER" >/dev/null 2>&1; then
  [ "$GAMEUSER_MAY_CREATE" = 1 ] || die "account '$GAMEUSER' not found and this source may not create one"
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
UID_N=$(id -u "$GAMEUSER"); UHOME=$(getent passwd "$GAMEUSER" | cut -d: -f6)
ARMHOME="$UHOME/$ARMHOME_DIR"
if ! mountpoint -q /dev/shm || [ "$(stat -c %a /dev/shm)" != 1777 ]; then
  mountpoint -q /dev/shm && umount /dev/shm 2>/dev/null
  mount -t tmpfs -o rw,nosuid,nodev,mode=1777 tmpfs /dev/shm; chmod 1777 /dev/shm
fi
grep -q '[[:space:]]/dev/shm[[:space:]]' /etc/fstab || echo 'tmpfs /dev/shm tmpfs rw,nosuid,nodev,mode=1777 0 0' >> /etc/fstab
# zz- prefix needed: /etc/sysctl.conf is linked in as 99-sysctl.conf, so it wins over a 99- drop-in.
if opt map-count; then
  rm -f /etc/sysctl.d/99-h96-steam.conf
  printf 'vm.max_map_count = 2147483642\n' > /etc/sysctl.d/zz-h96-steam.conf
  sysctl -q -p /etc/sysctl.d/zz-h96-steam.conf 2>/dev/null || true
else
  # Deselect keeps the image's zz-h96-steam.conf baseline; only removes the legacy 99- drop-in.
  rm -f /etc/sysctl.d/99-h96-steam.conf
  [ -f /etc/sysctl.d/zz-h96-steam.conf ] && echo "  map-count deselected: image baseline /etc/sysctl.d/zz-h96-steam.conf kept"
fi

say "3/11  x86-64 RootFS (graphics provider) + emulator configuration"
# Graphics provider: x86-64 RootFS with Mesa, same one the x86 client installer uses.
if [ ! -d "$RFS" ]; then
  SRC=$(find /root/.fex-emu/RootFS /root/.local/share/fex-emu/RootFS -maxdepth 1 -name Ubuntu_24_04 -type d 2>/dev/null | head -1)
  if [ -z "$SRC" ]; then
    # leftover download from earlier run: fetcher's overwrite prompt aborts under -y
    rm -f /root/.fex-emu/RootFS/Ubuntu_24_04.sqsh /root/.local/share/fex-emu/RootFS/Ubuntu_24_04.sqsh
    ( cd /opt 2>/dev/null; env -u DISPLAY FEXRootFSFetcher -y -x --force-ui=tty --distro-name=ubuntu --distro-version=24.04 )
    SRC=$(find /root/.fex-emu/RootFS /root/.local/share/fex-emu/RootFS -maxdepth 1 -name Ubuntu_24_04 -type d 2>/dev/null | head -1)
  fi
  [ -n "$SRC" ] || die "RootFS fetch failed"
  mkdir -p /opt/fex-rootfs && mv "$SRC" "$RFS"
  # download no longer needed once extracted (525 MB)
  rm -f /root/.fex-emu/RootFS/Ubuntu_24_04.sqsh /root/.local/share/fex-emu/RootFS/Ubuntu_24_04.sqsh
fi
chmod o+rx /opt /opt/fex-rootfs "$RFS"
[ -f "$RFS/usr/lib/x86_64-linux-gnu/libGL.so.1" ] || warn "RootFS carries no x86-64 libGL; games will not reach the GPU"
# Steam Linux Runtime uses the emulation path only when this manifest exists.
cat > "$RFS/graphics_provider.json" <<'JSON'
{
  "graphics_provider_v0": {
    "architectures": ["x86_64-linux-gnu", "i386-linux-gnu"]
  }
}
JSON
chmod 644 "$RFS/graphics_provider.json"
mkdir -p /usr/share/guestos && ln -sfn "$RFS" /usr/share/guestos/fex-mesa
# FEX config for the game user; HostEnv applies to the host side only (GLX copy, Vulkan loader path). One value per key.
FEXEXTRA=",
  \"Multiblock\":\"1\""
opt glx-lax   && FEXEXTRA="$FEXEXTRA,
  \"HostEnv\":\"__GLX_VENDOR_LIBRARY_NAME=h96lax\""
opt vk-spoof  && FEXEXTRA="$FEXEXTRA,
  \"HostEnv\":\"VK_IMPLICIT_LAYER_PATH=/usr/share/vulkan/implicit_layer.d\""
install -d -o "$GAMEUSER" -g "$GAMEUSER" "$UHOME/.fex-emu"
cat > "$UHOME/.fex-emu/Config.json" <<JSON
{ "Config": { "RootFS":"$RFS",
  "ThunkHostLibs":"/usr/lib/aarch64-linux-gnu/fex-emu/HostThunks/",
  "ThunkGuestLibs":"/usr/share/fex-emu/GuestThunks/",
  "ThunkConfig":"/usr/share/fex-emu/ThunksDB.json"$FEXEXTRA },
  "ThunksDB":{"GL":1,"Vulkan":1} }
JSON
chown "$GAMEUSER:$GAMEUSER" "$UHOME/.fex-emu/Config.json"
rm -f "$ARMHOME/.fex-emu/Config.json" 2>/dev/null   # the launcher copies the fresh one

if opt glx-lax; then
say "4/11  GL context binding across threads (private Mesa GLX copy)"
# Some GL ports bind one context from several threads; Mesa GLX refuses with BadAccess and the game crashes. Fix: patched libGLX_mesa copy (no-op check), installed as vendor "h96lax" and selected via FEX HostEnv; falls back to an unpatched copy if the pattern isn't found.
cat > /usr/local/lib/h96-glx-lax-patch.py <<'PYEOF'
#!/usr/bin/env python3
# Patch MakeContextCurrent to stop refusing a context current in another thread. Usage: h96-glx-lax-patch.py <libGLX_mesa.so.0> <out>
# Matches the aarch64 ldr/cbnz/ldr sequence (gc->currentDpy check) and nops the cbnz; requires exactly one match.
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
# Rebuild libGLX_h96lax.so.0 when the system Mesa GLX library's checksum changes.
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
# Own SONAME so Steam Linux Runtime's by-pattern GLX vendor copy picks this library up too.
command -v patchelf >/dev/null && patchelf --set-soname libGLX_h96lax.so.0 "$T"
chmod 644 "$T" && mv -f "$T" "$OUT" && echo "$SUM" > "$STAMP" && ldconfig
GLX
chmod 755 /usr/local/sbin/h96-glx-lax
/usr/local/sbin/h96-glx-lax
[ -f /usr/lib/aarch64-linux-gnu/libGLX_h96lax.so.0 ] && echo "  libGLX_h96lax.so.0 ready" || echo "  [warn] no native libGLX_mesa found; lax GLX copy skipped"
else
say "4/11  private Mesa GLX copy: not selected"
rm -f /usr/lib/aarch64-linux-gnu/libGLX_h96lax.so.0 /usr/local/sbin/h96-glx-lax /usr/local/lib/h96-glx-lax-patch.py /usr/local/lib/h96-glx-lax.src
fi

if opt vk-spoof; then
say "5/11  Vulkan feature layer for Proton titles (DXVK on the Mali driver)"
# Proton's DXVK requires Vulkan features (fillModeNonSolid, geometryShader, multiViewport, shaderClipDistance, shaderCullDistance, robustBufferAccess2) the Mali driver lacks; this layer reports them present and strips them again in vkCreateDevice. Enabled via H96_VK_SPOOF=1, opt out via H96_VK_SPOOF_DISABLE=1.
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
typedef struct { void *key; PFN_vkGetDeviceProcAddr gdpa; } dev_t_;
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
  /* record the device only; vkDestroyDevice is resolved when it is called */
  for (int i = 0; i < MAX_DEV; i++) if (!devs[i].key) { devs[i].key = key_of(*dev); devs[i].gdpa = gdpa; break; }
  pthread_mutex_unlock(&lock);
  return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL layer_DestroyDevice(VkDevice dev, const VkAllocationCallbacks *ac) {
  dev_t_ *d = dev_find(dev); PFN_vkDestroyDevice f = (PFN_vkDestroyDevice)d->gdpa(dev, "vkDestroyDevice");
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
say "5/11  Vulkan feature layer: not selected"
rm -f /usr/lib/aarch64-linux-gnu/libVkLayer_h96_spoof.so /usr/share/vulkan/implicit_layer.d/VkLayer_h96_spoof.json /usr/local/lib/h96-vk-spoof.c
fi

if opt xpad-dedup; then
say "6/11  one joystick per pad (duplicate xpad node removed)"
# Some third-party pads expose a duplicate xpad interface (headset class ff/5d/3); the rule unbinds it.
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
# Drop duplicate xpad binding on the headset interface (see h96-xpad-dedup).
ACTION=="add|bind", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", DRIVER=="xpad", ATTR{bInterfaceProtocol}=="03", RUN+="/usr/bin/systemd-run --no-block --quiet /usr/local/sbin/h96-xpad-dedup"
RULE
udevadm control --reload-rules 2>/dev/null; /usr/local/sbin/h96-xpad-dedup
else
say "6/11  duplicate joystick node: not selected"
rm -f /usr/local/sbin/h96-xpad-dedup /etc/udev/rules.d/71-h96-xpad-dedup.rules; udevadm control --reload-rules 2>/dev/null
fi

if opt pad-hidraw; then
say "7/11  controller access for the client"
# Client reads pads via /dev/hidraw* (root-only by default); Valve's udev rules cover only Valve-supported pads. IDs are the kernel's xpad_device[] table, matched vendor+product. Regenerate with gen-gamepad-hidraw-rules.py.
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
say "7/11  controller access: not selected"
rm -f /etc/udev/rules.d/60-h96-gamepad-hidraw.rules; udevadm control --reload 2>/dev/null
fi

if opt pad-xbox; then
say "8/11  pads from other makers presented as Xbox 360 pads"
# Engines that key controllers by USB vendor/product ID (Rewired, InControl, older SDL, Wine XInput) ignore an unrecognised pad even though the kernel drives it as Xbox-compatible; this re-emits non-Microsoft xpad devices via uinput with Xbox 360 pad IDs. Grabs the physical node, so leave off for titles that open the pad directly.
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
say "8/11  pads presented as Xbox 360 pads: not selected"
systemctl disable --now h96-pad-xbox >/dev/null 2>&1
rm -f /usr/local/sbin/h96-pad-xbox /etc/systemd/system/h96-pad-xbox.service; systemctl daemon-reload
fi

say "9/11  client package (publicbeta, linuxarm64) into $ARMHOME"
echo "  installed games, sign-in and settings are kept; only the client program folder is ever replaced"
S="$ARMHOME/.local/share/Steam"; D="$S/steamrtarm64"
install -d -o "$GAMEUSER" -g "$GAMEUSER" "$ARMHOME" "$ARMHOME/.local" "$ARMHOME/.local/share" "$S"
if [ -x "$D/steam" ] && file -b "$D/steam" | grep -q aarch64; then
  echo "  client present ($(cat "$D/builddate.txt" 2>/dev/null | head -1)); keeping it (the client updates itself)"
else
  TMPZ=$(mktemp /tmp/steam-arm64.XXXXXX.zip)
  curl -fsSL -o "$TMPZ.manifest" "$MANIFEST" || die "client manifest download failed"
  ENTRY=$(strings "$TMPZ.manifest" | grep -oE 'bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+' | grep -v '\.vz\.' | head -1)
  [ -n "$ENTRY" ] || die "no linuxarm64 package entry in the client manifest"
  echo "  package $ENTRY"
  curl -fL --progress-bar -o "$TMPZ" "$CDN/$ENTRY" || die "client package download failed"
  rm -rf "$D"
  # archive uses backslash separators; unzip would create literal backslash names
  python3 - "$TMPZ" "$S" <<'PY'
import os, sys, zipfile
zpath, root = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(zpath); n = 0
for i in z.infolist():
    name = i.filename.replace("\\", "/")
    if name.endswith("/") or ".." in name.split("/"): continue
    dst = os.path.join(root, name); os.makedirs(os.path.dirname(dst), exist_ok=True)
    with z.open(i) as src, open(dst, "wb") as out: out.write(src.read())
    mode = i.external_attr >> 16
    if mode: os.chmod(dst, mode)
    n += 1
print("  extracted %d files" % n)
PY
  rm -f "$TMPZ" "$TMPZ.manifest"
  # the archive carries no unix modes; mark programs and scripts executable
  find "$D" -type f | while read -r f; do file -b "$f" | grep -qE 'executable|shell script' && chmod 755 "$f"; done
  chown -R "$GAMEUSER:$GAMEUSER" "$D"
  [ -x "$D/steam" ] || die "client binary missing after extraction"
fi
# package channel at the data directory level (a copy under steamrtarm64 selects the generic client)
install -d -o "$GAMEUSER" -g "$GAMEUSER" "$S/package"; echo publicbeta > "$S/package/beta"
# the -deckard client reads a VR runtime registry; an empty one keeps it quiet
install -d -o "$GAMEUSER" -g "$GAMEUSER" "$ARMHOME/.config" "$ARMHOME/.config/openvr"
[ -f "$ARMHOME/.config/openvr/openvrpaths.vrpath" ] || cat > "$ARMHOME/.config/openvr/openvrpaths.vrpath" <<'JSON'
{
  "config": [],
  "external_drivers": null,
  "jsonid": "vrpathreg",
  "log": [],
  "runtime": [],
  "version": 1
}
JSON
chown -R "$GAMEUSER:$GAMEUSER" "$ARMHOME"

say "10/11  launcher, configuration, menu entry"
mkdir -p /etc/h96
conf_set ARMHOME_DIR "$ARMHOME_DIR"
conf_set GAMEUSER "$GAMEUSER"
CONF_ON=; CONF_OFF=
for c in $COMPONENTS; do if opt "$c"; then CONF_ON="$CONF_ON${CONF_ON:+,}$c"; else CONF_OFF="$CONF_OFF${CONF_OFF:+,}$c"; fi; done
conf_set COMPONENTS_ON "$CONF_ON"
conf_set COMPONENTS_OFF "$CONF_OFF"
# Launch handler: replaces Valve's LD_PRELOAD deletion; decides overlay, MangoHud and engine fixes per title.
cat > /usr/local/lib/h96-steam-handler.py <<'HANDLERPY'
#!/usr/bin/env python3
"""steam-arm launch handler.

Valve's FEX compatibility tool (fex-compat-tool, patched by h96-steam-arm-install) runs this file in
place of its own `del os.environ['LD_PRELOAD']`, before the runtime container starts. It works
on the tool's os.environ and sys.argv and decides per title:

  Steam overlay   x86 overlay core by default; `vulkan` adds the arm64 core and the arm64
                  overlay Vulkan layer (for Vulkan titles, whose frames x86 core never sees);
                  `off` removes both. The arm64 core stops OpenGL titles from starting, so it
                  is never loaded unless asked for.
  MangoHud        loaded when title asks for it: `mangohud %command%`, `MANGOHUD=1`, or profile.
  Engine fixes    Godot 4 titles: OpenGL renderer and GL 3.3 report (Vulkan renderer freezes on
                  splash; Panfrost reports GL 3.1, Godot's OpenGL renderer needs 3.3).
                  32-bit Unity players: Steam overlay off (the title stops when it attaches).
                  64-bit Unity players with a Vulkan renderer: -force-vulkan (Unity's OpenGL core
                  context needs a newer GL than Panfrost offers); overlay mode for Vulkan titles.
                  Other Unity 5+ players: GL 4.5 report, so the core context is created.
                  32-bit titles: -vulkan/-force-vulkan removed (no 32-bit Vulkan thunk, so
                  Vulkan lands on CPU renderer). Source 2 titles: warning only.
  Script launchers  Source engine style start scripts are followed to binary they name, for detection.

Profiles, one title per line, later files override earlier ones:
  /usr/local/share/h96/titles.conf      shipped with h96-steam-arm-install
  /etc/h96/titles.conf                  system
  ~/.config/steam-arm/titles.conf       client home (HOME inside the launcher)
Line: <appid> key=value ...   keys: overlay=x86|vulkan|off  mangohud=on|off
      godot=gl|vulkan  unity=vulkan|gl  env=NAME=VALUE;NAME=VALUE  args=ARG;ARG
      gl32=off (32-bit title on emulated x86 Mesa, no GL thunk)  vk32=keep (keep -vulkan)
Per-title launch options override profiles: STEAM_ARM_OVERLAY=x86|vulkan|off, and
STEAM_ARM_PRELOAD_KEEP=a,b (keep exactly LD_PRELOAD entries containing these substrings).
Every decision is printed to the tool's log, /tmp/fex-compat-tool-<pid>.log."""
import atexit
import glob
import json
import os
import re
import struct
import sys


def log(*a):
    print("steam-arm:", *a)


APPID = os.environ.get("SteamAppId") or os.environ.get("SteamGameId") or ""
PROFILE_FILES = ("/usr/local/share/h96/titles.conf", "/etc/h96/titles.conf",
                 os.path.join(os.path.expanduser("~"), ".config/steam-arm/titles.conf"))


def load_profile():
    prof = {}
    for path in PROFILE_FILES:
        try:
            lines = open(path).read().splitlines()
        except OSError:
            continue
        for line in lines:
            words = line.split("#", 1)[0].split()
            if len(words) > 1 and words[0] == APPID:
                for kv in words[1:]:
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        prof[k] = v
    return prof


def godot_major():
    """Engine major version from a .pck header next to the game (GDPC, format, major...)."""
    dirs = [os.getcwd()]
    for a in reversed(sys.argv):
        if os.path.isfile(a):
            dirs.append(os.path.dirname(os.path.abspath(a)))
            break
    for d in dirs:
        for p in glob.glob(os.path.join(d, "*.pck")):
            try:
                with open(p, "rb") as f:
                    h = f.read(12)
            except OSError:
                continue
            if len(h) == 12 and h[:4] == b"GDPC":
                return struct.unpack("<I", h[8:12])[0]
    return None


def is_elf(p):
    try:
        with open(p, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def script_target(path):
    """ELF in the script's own directory that a start script (hl2.sh style) names, else None."""
    try:
        with open(path, "rb") as f:
            if f.read(2) != b"#!":
                return None
            text = f.read(1 << 16).decode("utf-8", "replace")
    except OSError:
        return None
    d = os.path.dirname(os.path.abspath(path))
    found = []
    for m in re.finditer(r"[\w./+-]+", text):
        tok = m.group(0)
        # "$DIR"/game and "${DIR}/game": path relative to script
        if tok.startswith("/") and m.start() and text[m.start() - 1] in "\"}":
            tok = tok[1:]
        tok = tok[2:] if tok.startswith("./") else tok
        if not tok or tok.startswith("/") or ".." in tok.split("/") or re.search(r"\.so(\.|$)", tok) \
                or re.search(r"crash|report|breakpad|minidump", tok, re.I):
            continue
        p = os.path.join(d, tok)
        if p != os.path.abspath(path) and p not in found and os.path.isfile(p) and is_elf(p):
            found.append(p)
    # arch-switch scripts name both builds; FEX reports x86_64, so 64-bit one runs
    for p in found:
        try:
            with open(p, "rb") as f:
                if f.read(5)[4:5] == b"\x02":
                    return p
        except OSError:
            pass
    return found[-1] if found else None


def game_binary():
    """The title's own executable: last existing file on the command line that is an ELF,
    or the binary a start script there names."""
    for a in reversed(sys.argv):
        if os.path.isfile(a):
            if is_elf(a):
                return os.path.abspath(a)
            t = script_target(a)
            if t:
                return t
    return None


def source2():
    """True when the title's files carry Source 2's engine library (bin/linuxsteamrt64/libengine2.so)."""
    dirs = [os.getcwd()]
    exe = game_binary()
    if exe:
        dirs.append(os.path.dirname(exe))
    for a in reversed(sys.argv):
        if os.path.isfile(a):
            dirs.append(os.path.dirname(os.path.abspath(a)))
            break
    for d in dirs:
        for sub in ("", "bin/linuxsteamrt64", "game/bin/linuxsteamrt64"):
            if os.path.isfile(os.path.join(d, sub, "libengine2.so")):
                return True
    return False


def gl_thunk_off():
    """FEX app config with ThunksDB GL=0; FEX_APP_CONFIG is FEX's highest ThunksDB layer."""
    cfg = {}
    user = os.environ.get("FEX_APP_CONFIG")
    if user:
        try:
            cfg = json.load(open(user))
        except (OSError, ValueError):
            cfg = {}
    else:
        # tool's own translation of Steam's FEX settings, which it skips once FEX_APP_CONFIG is set
        gen = getattr(sys.modules.get("__main__"), "generate_app_config", None)
        if callable(gen):
            cfg = gen()
    if not isinstance(cfg, dict):
        cfg = {}
    if not isinstance(cfg.get("ThunksDB"), dict):
        cfg["ThunksDB"] = {}
    cfg["ThunksDB"]["GL"] = 0
    path = "/tmp/h96-steam-fex-app-config-%d.json" % os.getpid()
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    os.environ["FEX_APP_CONFIG"] = path
    atexit.register(lambda: os.path.exists(path) and os.unlink(path))


def engine_info():
    """(engine, bits) for the title's executable. engine is 'unity' when the Unity player's
    <name>_Data folder (Managed or il2cpp data) sits beside it, else None."""
    exe = game_binary()
    if not exe:
        return None, None
    try:
        with open(exe, "rb") as f:
            bits = {1: 32, 2: 64}.get(f.read(5)[4])
    except OSError:
        bits = None
    d = os.path.dirname(exe)
    stem = os.path.splitext(os.path.basename(exe))[0]
    data = [os.path.join(d, stem + "_Data")] + glob.glob(os.path.join(d, "*_Data"))
    unity = any(os.path.isdir(os.path.join(p, "Managed")) or os.path.isdir(os.path.join(p, "il2cpp_data"))
                for p in data) or os.path.isfile(os.path.join(d, "UnityPlayer.so"))
    return ("unity" if unity else None), bits


def unity_legacy_gl():
    """True for Unity 4 players (<name>_Data/mainData): legacy OpenGL path, no core context."""
    exe = game_binary()
    if not exe:
        return False
    d = os.path.dirname(exe)
    return any(os.path.isfile(os.path.join(p, "mainData")) for p in glob.glob(os.path.join(d, "*_Data")))


def unity_has_vulkan():
    """True when the title's Unity player (UnityPlayer.so) carries the Vulkan renderer switch."""
    exe = game_binary()
    if not exe:
        return False
    p = os.path.join(os.path.dirname(exe), "UnityPlayer.so")
    try:
        with open(p, "rb") as f:
            while True:
                b = f.read(1 << 22)
                if b"force-vulkan" in b:
                    return True
                if len(b) < 1 << 22:
                    return False
                # step back in case the match straddles the chunk boundary
                f.seek(-16, 1)
    except OSError:
        return False


def dedupe(seq):
    out = []
    for s in seq:
        if s not in out:
            out.append(s)
    return out


prof = load_profile()
if prof:
    log("profile for", APPID, prof)
extra = [x for x in prof.get("args", "").split(";") if x]
engine, bits = engine_info()
if engine:
    log("engine: %s, %s-bit" % (engine, bits))
if source2():
    log("source 2: needs desktop-class Vulkan features; no known fix, launched unchanged")
# 32-bit Unity players crash when the x86 overlay attaches; overlay off unless asked for.
engine_overlay = "off" if (engine == "unity" and bits == 32) else None
# 64-bit Unity+Vulkan: OpenGL core needs a newer GL than Panfrost offers, so force Vulkan instead (profile unity=gl or -force-* keeps GL).
unity_vk = False
if engine == "unity" and bits == 64 and prof.get("unity", "vulkan") == "vulkan" \
        and not any(a.startswith("-force-") for a in sys.argv + extra) and unity_has_vulkan():
    unity_vk = True
    engine_overlay = "vulkan"
entries = [e for e in os.environ.get("LD_PRELOAD", "").replace(" ", ":").split(":") if e]
x86_overlay = [e for e in entries if "gameoverlayrenderer" in e and "steamrtarm64" not in e]
arm_overlay = [e for e in entries if "gameoverlayrenderer" in e and "steamrtarm64" in e]
mh_entries = [e for e in entries if "mangohud" in e.lower()]

# Steam overlay
explicit = os.environ.get("STEAM_ARM_PRELOAD_KEEP")
if explicit is not None:
    keep = [k for k in explicit.split(",") if k]
    items = [e for e in entries if any(k in e for k in keep)]
    log("overlay: STEAM_ARM_PRELOAD_KEEP", keep)
else:
    mode = os.environ.get("STEAM_ARM_OVERLAY") or prof.get("overlay") or engine_overlay or "x86"
    items = []
    if mode in ("x86", "vulkan"):
        items += x86_overlay
    if mode == "vulkan":
        items += arm_overlay
        os.environ["STEAM_ARM_VK_OVERLAY"] = "1"
    log("overlay:", mode)

# MangoHud
mh = prof.get("mangohud", "auto")
wants_mh = bool(mh_entries) or os.environ.get("MANGOHUD") == "1" \
    or os.environ.get("STEAM_ARM_PRELOAD_MANGOHUD") == "1" or mh == "on"
if mh == "off":
    os.environ.pop("MANGOHUD", None)
    log("mangohud: off (profile)")
elif wants_mh:
    items += mh_entries or ["/usr/$LIB/mangohud/libMangoHud_shim.so"]
    os.environ["MANGOHUD"] = "1"
    log("mangohud: on")

# Godot 4
major = godot_major()
if major == 4 and prof.get("godot", "gl") == "gl":
    os.environ.setdefault("MESA_GL_VERSION_OVERRIDE", "3.3")
    os.environ.setdefault("MESA_GLSL_VERSION_OVERRIDE", "330")
    if "--rendering-driver" not in sys.argv + extra:
        sys.argv += ["--rendering-driver", "opengl3"]
    log("godot 4: OpenGL renderer, GL 3.3 report")
elif major is not None:
    log("godot %d: left as is" % major)

# Unity 5+ needs GL core above Panfrost's 3.1; report GL 4.5 so the context is created. Unity 4 (legacy GL) is left alone.
if unity_vk:
    sys.argv += ["-force-vulkan"]
    log("unity: Vulkan renderer (-force-vulkan)")
elif engine == "unity" and not unity_legacy_gl():
    os.environ.setdefault("MESA_GL_VERSION_OVERRIDE", "4.5")
    os.environ.setdefault("MESA_GLSL_VERSION_OVERRIDE", "450")
    log("unity: OpenGL core, GL 4.5 report")

# profile extras
for kv in [x for x in prof.get("env", "").split(";") if "=" in x]:
    k, v = kv.split("=", 1)
    os.environ[k] = v
    log("env:", k)
if extra:
    sys.argv += extra
    log("args:", extra)

# 32-bit: FEX has no 32-bit Vulkan thunk, so a Vulkan renderer lands on lavapipe (CPU).
if bits == 32 and prof.get("vk32") != "keep":
    vk = [a for a in sys.argv if a in ("-vulkan", "-force-vulkan")]
    if vk:
        sys.argv = [a for a in sys.argv if a not in vk]
        log("32-bit: removed", vk, "(Vulkan would run on CPU; vk32=keep keeps it)")
# gl32=off: emulated x86 Mesa instead of the host GL thunk, for titles the thunk breaks.
if prof.get("gl32") == "off" and bits != 64:
    try:
        gl_thunk_off()
        log("gl32: GL thunk off (FEX_APP_CONFIG=%s)" % os.environ["FEX_APP_CONFIG"])
    except OSError as e:
        log("gl32: could not write FEX app config:", e)

items = dedupe(items)
if items:
    os.environ["LD_PRELOAD"] = ":".join(items)
    log("LD_PRELOAD for container:", os.environ["LD_PRELOAD"])
else:
    os.environ.pop("LD_PRELOAD", None)
    log("LD_PRELOAD: none")
HANDLERPY
chmod 644 /usr/local/lib/h96-steam-handler.py
mkdir -p /usr/local/share/h96
cat > /usr/local/share/h96/titles.conf <<'TITLES'
# Shipped profiles, replaced every run; local overrides go in /etc/h96/titles.conf or ~/.config/steam-arm/titles.conf. Line: <appid> key=value ...
TITLES
[ -f /etc/h96/titles.conf ] || cat > /etc/h96/titles.conf <<'TITLES'
# Local title profiles; override /usr/local/share/h96/titles.conf. One per line:
#   <appid> overlay=x86|vulkan|off  mangohud=on|off  godot=gl|vulkan  env=A=1;B=2  args=-x;-y
#   gl32=off (32-bit title on emulated x86 Mesa, no GL thunk)  vk32=keep (32-bit title keeps -vulkan)
# Example: <appid> overlay=off
TITLES

# FEX tool edit, shared by the launcher's start and its watcher (see the launcher).
cat > /usr/local/lib/h96-steam-fexpatch.py <<'FEXPY'
#!/usr/bin/env python3
"""steam-arm-fexpatch FEXTOOLDIR: thunk overlay paths, server socket, GL and Vulkan thunks on.

FEX substitutes a thunk only when the guest opens a library path listed in ThunksDB's Overlay.
Inside the runtime container the guest opens libGL, libEGL and libvulkan from pressure-vessel's
overrides directory, or from /run/gfx/main where current runtimes mount the graphics provider,
for 32-bit and 64-bit titles alike. Writes only when something is missing.

Also replaces the tool's deletion of LD_PRELOAD with a call to the steam-arm launch handler,
/usr/local/lib/h96-steam-handler.py, which decides overlay, MangoHud and engine fixes per title
(if it fails, the tool behaves as Valve wrote it). Patched only where Valve's two lines match
exactly; an earlier steam-arm filter (v1) is replaced."""
import json, os, sys
F = sys.argv[1]
db_p, tpl_p = F + "/usr/share/fex-emu/ThunksDB.json", F + "/ConfigTemplate.json"
db = json.load(open(db_p)); changed = False
names = {"GL": ["libGL.so", "libGL.so.1", "libGL.so.1.7.0", "libGL.so.1.2.0"],
         "Vulkan": ["libvulkan.so", "libvulkan.so.1"], "EGL": ["libEGL.so", "libEGL.so.1"]}
for lib, ns in names.items():
    if lib not in db["DB"]:
        continue
    ov = db["DB"][lib].setdefault("Overlay", [])
    for arch in ("i386-linux-gnu", "x86_64-linux-gnu"):
        for base in ("/usr/lib/pressure-vessel/overrides/lib/" + arch,
                     "/usr/lib/pressure-vessel/overrides/lib/%s/aliases" % arch,
                     "/run/gfx/main/usr/lib/" + arch):
            for n in ns:
                p = base + "/" + n
                if p not in ov:
                    ov.append(p); changed = True
if changed:
    json.dump(db, open(db_p, "w"), indent=2)
t = json.load(open(tpl_p)); c = t.setdefault("Config", {}); tc = False
sock = "/run/user/%s/h96-fexserver.sock" % os.getuid()
if c.get("ServerSocketPath") != sock:
    c["ServerSocketPath"] = sock; tc = True
td = t.setdefault("ThunksDB", {})
for k in ("GL", "Vulkan"):
    if td.get(k) != "1":
        td[k] = "1"; tc = True
if tc:
    json.dump(t, open(tpl_p, "w"), indent=4)
ct_p = F + "/fex-compat-tool"
MARK = "# steam-arm handler v2"
try:
    ct = open(ct_p).read()
except OSError:
    ct = MARK
block = ("    " + MARK + "\n"
         "    try:\n"
         "        import runpy\n"
         "        runpy.run_path('/usr/local/lib/h96-steam-handler.py')\n"
         "    except Exception as _e:\n"
         "        print('steam-arm: handler failed, Valve default applies:', _e)\n"
         "        os.environ.pop('LD_PRELOAD', None)\n")
old = "    if 'LD_PRELOAD' in os.environ:\n        del os.environ['LD_PRELOAD']\n"
out = None
if MARK in ct and "run_path('/usr/local/lib/h96-steam-handler.py')" not in ct:
    # already patched for the other flavour: re-point the block
    i = ct.index("    " + MARK)
    end = "        os.environ.pop('LD_PRELOAD', None)\n"
    j = ct.index(end, i) + len(end)
    out = ct[:i] + block + ct[j:]
elif MARK not in ct:
    if ct.count(old) == 1:
        out = ct.replace(old, block)
    elif "# steam-arm preload filter v1" in ct:
        i = ct.index("    # steam-arm preload filter v1")
        end = "        os.environ.pop('LD_PRELOAD', None)\n"
        j = ct.index(end, i) + len(end)
        out = ct[:i] + block + ct[j:]
if out:
    compile(out, ct_p, "exec")
    open(ct_p, "w").write(out)
FEXPY
chmod 755 /usr/local/lib/h96-steam-fexpatch.py
cat > /usr/local/bin/steam-arm <<'LAUNCHER'
#!/bin/sh
# steam-arm: starts the native ARM64 Steam client, run as the desktop user; re-applies setup the client package lacks on each start (client re-verifies files on update).
REALHOME="$HOME"
ARMHOME_DIR=.local/share/h96-steam-arm            # relative to the user's home
[ -r /etc/h96/steam-arm.conf ] && . /etc/h96/steam-arm.conf
ARMHOME="${H96_STEAM_ARM_HOME:-$REALHOME/$ARMHOME_DIR}"
export HOME="$ARMHOME"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export STEAM_COMPAT_GRAPHICS_PROVIDER=/opt/fex-rootfs/Ubuntu_24_04/graphics_provider.json
export __GLX_VENDOR_LIBRARY_NAME=h96lax
export STEAMOS=1
export H96_VK_SPOOF=1
# D3D8 titles: DXVK's d3d8 instead of wined3d, whose OpenGL path misrenders on Mali. Per-title override: set 0 in launch options.
export PROTON_DXVK_D3D8="${PROTON_DXVK_D3D8:-1}"
S="$ARMHOME/.local/share/Steam"; D="$S/steamrtarm64"; F="$S/steamapps/common/FEX-Emu"

# Pause h96-pad-xbox while this client runs: it grabs the physical pad and this client's Steam Input re-identifies pads itself.
PADSVC=0
if systemctl is-active --quiet h96-pad-xbox 2>/dev/null; then
  PADSVC=1; sudo -n systemctl stop h96-pad-xbox 2>/dev/null || systemctl stop h96-pad-xbox 2>/dev/null
fi
restore_pad(){ [ "$PADSVC" = 1 ] && { sudo -n systemctl start h96-pad-xbox 2>/dev/null || systemctl start h96-pad-xbox 2>/dev/null; }; }
FEXWATCH=
# Single exit handler: stop the FEX watcher, then restore the pad service.
on_exit(){ [ -n "$FEXWATCH" ] && kill "$FEXWATCH" 2>/dev/null; restore_pad; }
trap on_exit EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
if pgrep -f 'ubuntu12_32/steam ' >/dev/null 2>&1; then
  command -v zenity >/dev/null 2>&1 && zenity --warning --text="The x86 Steam client is running. Close it first; two clients fight over the controller and steam:// links." 2>/dev/null
fi

# --- client-side links ---
mkdir -p "$ARMHOME/.steam"
ln -sfn "$S" "$ARMHOME/.steam/steam"; ln -sfn "$S" "$ARMHOME/.steam/root"
ln -sfn "$S/linux32" "$ARMHOME/.steam/sdk32"; ln -sfn "$S/linux64" "$ARMHOME/.steam/sdk64"
ln -sfn "$S/linuxarm64" "$ARMHOME/.steam/sdkarm64"   # sdk dir: steamclient.so for games and Proton, steam-launch-wrapper
ln -sfn "$S/ubuntu12_32" "$ARMHOME/.steam/bin32"; ln -sfn "$S/ubuntu12_64" "$ARMHOME/.steam/bin64"
mkdir -p "$S/package"; [ -f "$S/package/beta" ] || echo publicbeta > "$S/package/beta"

# --- launch wrapper stand-in ---
if [ ! -x "$S/linuxarm64/steam-launch-wrapper" ] && [ ! -x "$D/steam-launch-wrapper" ]; then
cat > "$D/steam-launch-wrapper" <<'SH'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in
  --oom-score-adjust) [ -n "$2" ] && echo "$2" > /proc/self/oom_score_adj 2>/dev/null; shift 2;;
  --oom-score-adjust=*) echo "${1#*=}" > /proc/self/oom_score_adj 2>/dev/null; shift;;
  --) shift; break;; *) shift;; esac; done
exec "$@"
SH
chmod 755 "$D/steam-launch-wrapper"
fi

# --- Remote Play ---
# streaming_client needs Vulkan Video decode, absent here; run the package's x86-64 client under FEX with software decode instead.
if [ -f "$D/streaming_client" ] && [ "$(head -c 4 "$D/streaming_client" | tr -d '\177')" = "ELF" ]; then
  mv -f "$D/streaming_client" "$D/streaming_client.real"      # only the real binary is ever moved aside
fi
if [ ! -x "$D/streaming_client" ] || ! grep -q 'x86-64 streaming client' "$D/streaming_client" 2>/dev/null; then
cat > "$D/streaming_client" <<'SH'
#!/bin/sh
# Stand-in: run the x86-64 streaming client from this package under FEX (see steam-arm).
here="$(dirname "$0")"; S="$(dirname "$here")"
set -- $(for a in "$@"; do [ "$a" = "--openvr" ] || printf '%s\n' "$a"; done)
export LD_LIBRARY_PATH="$S/linux64:$S/ubuntu12_64:$S/ubuntu12_32${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset __GLX_VENDOR_LIBRARY_NAME
export SDL_VIDEO_X11_FORCE_EGL=0
cd "$S" && exec /usr/bin/FEX "$S/ubuntu12_64/streaming_client" "$@"
SH
chmod 755 "$D/streaming_client"
fi
# system FEX config for the x86 streaming client (same rootfs, thunks and host settings as the x86 stack)
mkdir -p "$ARMHOME/.fex-emu"; [ -f "$ARMHOME/.fex-emu/Config.json" ] || cp -f "$REALHOME/.fex-emu/Config.json" "$ARMHOME/.fex-emu/Config.json" 2>/dev/null

# --- FEX compatibility tool patch ---
# Client re-downloads this tool on update with thunks off; a watcher reapplies the patch within a second of it appearing or changing.
FEXPATCH=/usr/local/lib/h96-steam-fexpatch.py
fex_ok(){ grep -q '/run/gfx/main/' "$F/usr/share/fex-emu/ThunksDB.json" 2>/dev/null && grep -q '"GL": "1"' "$F/ConfigTemplate.json" 2>/dev/null \
  && grep -q "\"/run/user/$(id -u)/h96-fexserver.sock\"" "$F/ConfigTemplate.json" 2>/dev/null \
  && { grep -q '/usr/local/lib/h96-steam-handler.py' "$F/fex-compat-tool" 2>/dev/null || ! grep -q "LD_PRELOAD" "$F/fex-compat-tool" 2>/dev/null; }; }
[ -d "$F" ] && ! fex_ok && python3 "$FEXPATCH" "$F" 2>/dev/null
# Overlay and FEX leave shared-memory segments in /dev/shm; sweep unused ones (older than a minute, or from dead PIDs) at start and every minute to avoid SIGBUS from a full /dev/shm.
shm_sweep(){ python3 - "$(id -u)" 2>/dev/null <<'SHMPY'
import ctypes, glob, os, sys, time
uid = int(sys.argv[1]); now = time.time(); used = set(); mappers = {}; game = False
for p in glob.glob("/proc/[0-9]*"):
    try:
        comm = open(p + "/comm").read().strip()
        if os.stat(p).st_uid == uid and b"SteamLaunch" in open(p + "/cmdline", "rb").read():
            game = True
        for line in open(p + "/maps"):
            i = line.find("/dev/shm/")
            if i >= 0:
                used.add(line[i:].split()[0])
                mappers.setdefault(line[i:].split()[0], set()).add(comm)
    except OSError:
        pass
    try:
        for fd in os.listdir(p + "/fd"):
            try:
                t = os.readlink(p + "/fd/" + fd)
            except OSError:
                continue
            if t.startswith("/dev/shm/"):
                used.add(t.split()[0])
    except OSError:
        pass
for f in glob.glob("/dev/shm/u%d-Shm_*" % uid):
    try:
        if f not in used and now - os.stat(f).st_mtime > 60:
            os.unlink(f)
    except OSError:
        pass
# Overlay frame buffers of ended sessions stay mapped by steamwebhelper (25 MB each); with no game
# running, punch them (FALLOC_FL_PUNCH_HOLE|KEEP_SIZE): pages freed, size and mappings kept.
if not game:
    libc = ctypes.CDLL(None, use_errno=True)
    for f in glob.glob("/dev/shm/u%d-Shm_*" % uid):
        try:
            st = os.stat(f)
            if mappers.get(f) == {"steamwebhelper"} and st.st_blocks and st.st_size >= 8 << 20 \
                    and now - st.st_mtime > 60:
                fd = os.open(f, os.O_RDWR)
                try:
                    libc.fallocate(fd, 3, ctypes.c_long(0), ctypes.c_long(st.st_size))
                finally:
                    os.close(fd)
        except OSError:
            pass
for f in glob.glob("/dev/shm/fex-*-stats"):
    pid = f[len("/dev/shm/fex-"):-len("-stats")]
    try:
        if pid.isdigit() and os.stat(f).st_uid == uid and not os.path.exists("/proc/" + pid):
            os.unlink(f)
    except OSError:
        pass
SHMPY
}
shm_sweep
( n=0; while sleep 1; do [ -d "$F" ] && ! fex_ok && python3 "$FEXPATCH" "$F" 2>/dev/null; n=$((n + 1)); [ $((n % 60)) -eq 0 ] && shm_sweep; done ) &
FEXWATCH=$!

# --- Remote Play settings ---
# Pin hardware decoding and HEVC off (no hardware decode path here); applied before each start, skipped if a client is already running.
if command -v h96-steam-remoteplay >/dev/null 2>&1 && ! pgrep -x steam >/dev/null 2>&1; then
  h96-steam-remoteplay >/dev/null 2>&1
fi

# --- interface selection ---
# Desktop mode shows its own tray status icon (via xembedsniproxy); Big Picture (-gamepadui) registers none.
GPUI=-gamepadui
[ "$H96_STEAM_ARM_UI" = desktop ] && GPUI=
SWITCH=
case "$1" in
  --desktop) GPUI=; SWITCH=1; shift;;
  --bigpicture) GPUI=-gamepadui; SWITCH=1; shift;;
esac
# A named interface restarts a running client (steam -shutdown, wait, relaunch); reached from the power menu via steamos-session-select.
if [ -n "$SWITCH" ] && pgrep -u "$(id -u)" -x steam >/dev/null 2>&1; then
  ( cd "$D" && ./steam -shutdown >/dev/null 2>&1 )
  n=0
  while pgrep -u "$(id -u)" -x steam >/dev/null 2>&1; do
    sleep 1; n=$((n+1))
    [ $n -ge 60 ] && { echo "steam-arm: running client did not exit within 60 s; close it from its menu, then try again" >&2; exit 1; }
  done
fi

# Menu icon comes from the client's own icon file, absent until its first start. Wait for it in
# the background (poll every 5 s, up to 15 min) so start is never delayed; flock keyed by uid
# stops a second concurrent start from waiting twice.
if command -v h96-steam-arm-icon >/dev/null 2>&1 && [ ! -f /usr/share/icons/hicolor/256x256/apps/h96-steam-arm.png ] \
   && [ ! -f "$REALHOME/.local/share/icons/hicolor/256x256/apps/h96-steam-arm.png" ]; then
  ICONLOCK="${XDG_RUNTIME_DIR:-/tmp}/h96-steam-arm-icon-wait-$(id -u).lock"
  ( flock -n 9 || exit 0
    STEP="${STEAM_ARM_ICON_POLL:-5}"; n=0
    while [ ! -f "$S/public/steam_tray.ico" ]; do
      n=$((n + STEP)); [ "$n" -ge 900 ] && exit 0
      sleep "$STEP"
    done
    h96-steam-arm-icon "$S" "$REALHOME/.local/share/icons/hicolor" || exit 0
    if command -v kbuildsycoca6 >/dev/null 2>&1; then HOME="$REALHOME" kbuildsycoca6
    elif command -v kbuildsycoca5 >/dev/null 2>&1; then HOME="$REALHOME" kbuildsycoca5
    fi
    for d in "$REALHOME/Desktop/Steam ARM.desktop" "$REALHOME/Desktop/Steam ARM (Desktop mode).desktop"; do
      [ -f "$d" ] && touch "$d"
    done
  ) >/dev/null 2>&1 9>"$ICONLOCK" &
fi

# Tray icon: this client build shows none of its own, so h96-steam-tray supplies it (autostart plus started here, single-instance locked, runs with the real user's HOME).
if command -v h96-steam-tray >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
  HOME="$REALHOME" setsid h96-steam-tray </dev/null >/dev/null 2>&1 &
fi

# Registers the client's arm64 overlay Vulkan layer behind STEAM_ARM_VK_OVERLAY (set only for overlay=vulkan titles); enabling it for all titles crashes Proton ARM64 at device creation.
VKL="$ARMHOME/.local/share/vulkan/implicit_layer.d"
if [ -f "$D/steamoverlayvulkanlayer.so" ]; then
  mkdir -p "$VKL"; rm -f "$VKL/steamoverlay_arm64.json" "$VKL/steamoverlay_arm64.json.off"
  cat > "$VKL/steamoverlay_arm64_h96.json" <<VKJSON
{
  "file_format_version": "1.0.0",
  "layer": {
    "name": "VK_LAYER_VALVE_steam_overlay_arm64_h96",
    "type": "GLOBAL",
    "library_path": "$D/steamoverlayvulkanlayer.so",
    "api_version": "1.3.207",
    "implementation_version": "1",
    "description": "Steam overlay layer (arm64), registered by steam-arm for profiled Vulkan titles",
    "disable_environment": { "DISABLE_VK_LAYER_VALVE_steam_overlay_1": "1" },
    "enable_environment": { "STEAM_ARM_VK_OVERLAY": "1" }
  }
}
VKJSON
fi

# Client's helper programs (e.g. gameoverlayui) need the client dir on LD_LIBRARY_PATH or they SIGSEGV at start.
export LD_LIBRARY_PATH="$D${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$D" || exit 1
# First start only verifies files (downloads the rest of the package, e.g. the SDK dir) then exits; started once more to skip re-verification.
if [ ! -f "$S/linuxarm64/steamclient.so" ]; then
  ./steam -deckard -steamos3 ${GPUI:+"$GPUI"} "$@"
  [ -f "$S/linuxarm64/steamclient.so" ] || exit 1
  ln -sfn "$S/linuxarm64" "$ARMHOME/.steam/sdkarm64"
fi
./steam -deckard -steamos3 ${GPUI:+"$GPUI"} -noverifyfiles -norepairfiles -noshaders "$@"
exit $?
LAUNCHER
chmod 755 /usr/local/bin/steam-arm
# steamos-session-select restarts the client in the chosen interface (SteamOS instead swaps the whole session); run with the plain user environment, not the client's HOME.
cat > /usr/local/bin/steamos-session-select <<'SESSEL'
#!/bin/sh
# steamos-session-select for steam-arm: restart the client in the interface the power menu chose.
case "${1:-}" in
  plasma|plasma-x11|plasma-wayland|plasma-x11-persistent|plasma-wayland-persistent|desktop) m=--desktop;;
  *) m=--bigpicture;;
esac
u=$(id -un); h=$(getent passwd "$(id -u)" | cut -d: -f6)
setsid env -i HOME="$h" USER="$u" LOGNAME="$u" PATH=/usr/local/bin:/usr/bin:/bin \
  DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-$h/.Xauthority}" LANG="${LANG:-C.UTF-8}" \
  XDG_RUNTIME_DIR="/run/user/$(id -u)" XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-}" \
  XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-x11}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
  /usr/local/bin/steam-arm "$m" </dev/null >/dev/null 2>&1 &
exit 0
SESSEL
chmod 755 /usr/local/bin/steamos-session-select
# Client defaults to hardware decoding, unsupported here; this helper pins hardware decoding and HEVC off. --check reports only.
cat > /usr/local/bin/h96-steam-remoteplay <<'RPPY'
#!/usr/bin/env python3
"""Pin the Remote Play client settings the native ARM64 Steam client needs on this box.

The client stores its Remote Play settings as a serialized protobuf (CStreamingClientConfig
from steammessages_remoteplay.proto), hex-encoded under "ClientConfig" in the account's
localconfig.vdf. Two of its fields default to values this box cannot honour:

  enable_hardware_decoding (field 7) defaults to true. The streaming client decodes through
  Vulkan Video, which the Mali driver on this box does not provide, so the client advertises
  a decoder it does not have and the session never leaves negotiation. Titles with a light
  stream can still come up; heavier ones sit on the launch screen.
  enable_video_hevc (field 13) defaults to false, and is pinned false so the host keeps to
  H.264, which the software decoder handles.

This tool inserts both fields, set to false, when they are absent, and leaves every other
byte of the message untouched. A signed-in account that has not streamed yet has no
"ClientConfig" entry at all (the client writes one after its first session); the tool then
creates the entry, inside the existing "streaming_v2" block or in a new one, so the first
stream already runs with the pinned values. It refuses to run while the client is up,
because the client writes its own copy of the file back on exit. Run without arguments to
apply; --check only reports. Exit status 0 when the settings are in place, 1 when they
could not be applied.
"""
import glob
import os
import pwd
import re
import sys

USAGE = """Usage: h96-steam-remoteplay [--check]

Pins Remote Play settings of native ARM64 client in each localconfig.vdf of client
home: hardware decoding off, HEVC off. Launcher runs it before each client start.

  (none)       apply; refuses while client runs
  --check      report only, change nothing
  -h, --help   print this text and exit

Client home, resolved as launcher does: H96_STEAM_ARM_HOME, else ARMHOME_DIR from
/etc/h96/steam-arm.conf under account home (default .local/share/h96-steam-arm).
Exit status 0 when settings are in place, 1 otherwise."""
CONF_PATH = "/etc/h96/steam-arm.conf"
ARMHOME_DIR = ".local/share/h96-steam-arm"
HOME_VAR = "H96_STEAM_ARM_HOME"

# Field numbers are from the schema embedded in the client; wire type 0 (varint) for bool.
FIELD_HW_DECODE = 7
FIELD_HEVC = 13
KEY_RE = re.compile(r'("ClientConfig"\t\t")([0-9a-f]*)(")')
# streaming_v2 block, one level below root; closing brace is the first "\t}" after "\t{".
BLOCK_RE = re.compile(r'\n\t"streaming_v2"\n\t\{\n(?:.*\n)*?\t\}\n')
ROOT_RE = re.compile(r'\A"UserLocalConfigStore"\n\{\n')
ENABLE_RE = re.compile(r'\n\t\t"EnableStreaming"\t\t"')


def read_varint(b, i):
    val, shift = 0, 0
    while True:
        c = b[i]
        val |= (c & 0x7F) << shift
        i += 1
        if not c & 0x80:
            return val, i
        shift += 7


def split_fields(b):
    """Yield (field_number, raw_bytes_of_tag_and_value) for a wire-format message."""
    i = 0
    while i < len(b):
        start = i
        tag, i = read_varint(b, i)
        num, wt = tag >> 3, tag & 7
        if wt == 0:
            _, i = read_varint(b, i)
        elif wt == 1:
            i += 8
        elif wt == 2:
            ln, i = read_varint(b, i)
            i += ln
        elif wt == 5:
            i += 4
        else:
            raise ValueError("unsupported wire type %d at byte %d" % (wt, start))
        yield num, b[start:i]


def pinned(blob):
    """Return the message with both fields present as false, in ascending field order."""
    fields = list(split_fields(blob))
    present = {n for n, _ in fields}
    for num in (FIELD_HW_DECODE, FIELD_HEVC):
        if num not in present:
            fields.append((num, bytes([num << 3, 0])))
    fields.sort(key=lambda f: f[0])
    return b"".join(raw for _, raw in fields)


def with_entry(text):
    """The file text with a "ClientConfig" entry holding only the two pinned fields: added
    to the streaming_v2 block when the block exists, otherwise in a new block right after
    the root object opens. The entry goes first in the block, ahead of "EnableStreaming" "1",
    which is the layout the client itself writes; the EnableStreaming key is added after the
    entry when it is missing. Returns None when the file is not laid out as expected."""
    line = '\t\t"ClientConfig"\t\t"%s"\n' % pinned(b"").hex()
    enable = '\t\t"EnableStreaming"\t\t"1"\n'
    m = BLOCK_RE.search(text)
    if m:
        block = m.group(0)
        head = '\n\t"streaming_v2"\n\t{\n'
        assert block.startswith(head)
        add = line + ("" if ENABLE_RE.search(block) else enable)
        return text[:m.start()] + head + add + block[len(head):] + text[m.end():]
    m = ROOT_RE.match(text)
    if not m:
        return None
    return text[:m.end()] + '\t"streaming_v2"\n\t{\n' + line + enable + "\t}\n" + text[m.end():]


def client_running():
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                with open("/proc/%s/comm" % pid) as fh:
                    if fh.read().strip() == "steam":
                        return True
            except OSError:
                pass
    return False


def write_back(path, text):
    tmp = path + ".h96tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)
    os.replace(tmp, path)


def client_home():
    """Client home as launcher resolves it: H96_STEAM_ARM_HOME (settings file over environment), else
    ARMHOME_DIR under account home. Account home comes from password database, because
    launcher runs this tool with HOME already set to client home."""
    conf = {}
    try:
        with open(CONF_PATH) as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep and not key.startswith("#"):
                    conf[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    override = conf.get(HOME_VAR) or os.environ.get(HOME_VAR)
    if override:
        return override
    return os.path.join(pwd.getpwuid(os.getuid()).pw_dir, conf.get("ARMHOME_DIR") or ARMHOME_DIR)


def main():
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(USAGE)
        return 0
    check = "--check" in sys.argv[1:]
    steam = os.path.join(client_home(), ".local/share/Steam")
    files = glob.glob(os.path.join(steam, "userdata/*/config/localconfig.vdf"))
    if not files:
        print("h96-steam-remoteplay: no localconfig.vdf under %s yet; sign in to client once first" % steam)
        return 1
    status = 0
    for path in files:
        text = open(path, encoding="utf-8", errors="surrogateescape").read()
        m = KEY_RE.search(text)
        if not m:
            new_text = with_entry(text)
            if new_text is None:
                print("%s: no ClientConfig entry and no place to add one (unexpected layout)" % path)
                status = 1
                continue
            if check:
                print("%s: not pinned (would create the ClientConfig entry)" % path)
                status = 1
                continue
            if client_running():
                print("h96-steam-remoteplay: the client is running; close it first, it rewrites this file on exit")
                return 1
            # verify before writing: exactly one entry, pinned message, all original lines kept
            found = KEY_RE.findall(new_text)
            assert len(found) == 1 and bytes.fromhex(found[0][1]) == pinned(b"")
            assert all(l in new_text.splitlines() for l in text.splitlines())
            assert len(ENABLE_RE.findall(new_text)) == 1
            write_back(path, new_text)
            print("%s: ClientConfig entry created, pinned (hardware decoding off, HEVC off)" % path)
            continue
        old = bytes.fromhex(m.group(2))
        new = pinned(old)
        if new == old:
            print("%s: already pinned" % path)
            continue
        if check:
            print("%s: not pinned (would insert fields 7 and 13)" % path)
            status = 1
            continue
        if client_running():
            print("h96-steam-remoteplay: the client is running; close it first, it rewrites this file on exit")
            return 1
        # verify before writing: result must parse to the same fields plus the two pinned
        assert dict(split_fields(new)).keys() == dict(split_fields(old)).keys() | {FIELD_HW_DECODE, FIELD_HEVC}
        write_back(path, text[:m.start(2)] + new.hex() + text[m.end(2):])
        print("%s: pinned (hardware decoding off, HEVC off)" % path)
    return status


if __name__ == "__main__":
    sys.exit(main())
RPPY
chmod 755 /usr/local/bin/h96-steam-remoteplay
chmod 755 /usr/local/bin/steam-arm
# the launcher pauses the pad re-identification service (emulated-client component) while it runs
cat > /etc/sudoers.d/h96-steam-arm <<SUDO
$GAMEUSER ALL=(root) NOPASSWD: /usr/bin/systemctl start h96-pad-xbox, /usr/bin/systemctl stop h96-pad-xbox
SUDO
chmod 440 /etc/sudoers.d/h96-steam-arm
# compat tool mapping helper (titles with a Linux build on record but Windows files installed)
cat > /usr/local/lib/h96-steam-compatmap.py <<'PYEOF'
#!/usr/bin/env python3
# Insert/replace a CompatToolMapping entry in config.vdf (run with Steam closed). Usage: h96-steam-compatmap.py <config.vdf> <appid> <tool>
import re, sys, shutil
path, appid, tool = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8", errors="surrogateescape").read()

def body(ind):
    return ('{i}\t"{a}"\n{i}\t{{\n{i}\t\t"name"\t\t"{t}"\n{i}\t\t"config"\t\t""\n'
            '{i}\t\t"priority"\t\t"250"\n{i}\t}}\n').format(i=ind, a=appid, t=tool)

m = re.search(r'\n(\t+)"CompatToolMapping"\n\1\{\n', s)
if not m:
    sm = re.search(r'\n(\t+)"Steam"\n\1\{\n', s)
    if not sm:
        print("Software/Valve/Steam block not found", file=sys.stderr); sys.exit(1)
    ind = sm.group(1) + "\t"
    ins = '%s"CompatToolMapping"\n%s{\n%s%s}\n' % (ind, ind, body(ind), ind)
    s = s[:sm.end()] + ins + s[sm.end():]; action = "block created"
else:
    ind = m.group(1); start = m.end(); end = s.find("\n" + ind + "}", start) + 1   # keep the final newline
    block = s[start:end]
    am = re.search(r'^\t+"%s"\n\t+\{\n(?:.*\n)*?\t+\}\n' % re.escape(appid), block, re.M)
    if am:
        block = block[:am.start()] + body(ind) + block[am.end():]; action = "replaced"
    else:
        block = body(ind) + block; action = "inserted"
    s = s[:start] + block + s[end:]
shutil.copy(path, path + ".bak-h96")
open(path, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("CompatToolMapping %s for app %s -> %s" % (action, appid, tool))
PYEOF
cat > /usr/local/bin/h96-steam-arm-compatmap <<CM
#!/bin/sh
# usage: h96-steam-arm-compatmap <appid> <tool>  (Steam ARM must be closed)
[ \$# -eq 2 ] || { echo "usage: h96-steam-arm-compatmap <appid> <tool>" >&2; exit 2; }
C=$ARMHOME/.local/share/Steam/config/config.vdf
python3 /usr/local/lib/h96-steam-compatmap.py "\$C" "\$1" "\$2" && chown $GAMEUSER:$GAMEUSER "\$C"
CM
chmod 755 /usr/local/bin/h96-steam-arm-compatmap


# KWin only picks up kwinrulesrc changes after a reconfigure signal.
kwin_reload(){ su - "$GAMEUSER" -c "XDG_RUNTIME_DIR=/run/user/$UID_N DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_N/bus dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure" >/dev/null 2>&1 || true; }

# Round Steam icon on a green disc, chartreuse logo for Big Picture / bone for desktop mode; logo shape comes from the client's own steam_tray.ico (present only after first start).
steam_arm_icon(){
  cat > /usr/local/bin/h96-steam-arm-icon <<'ICONPY'
#!/usr/bin/env python3
"""h96-steam-arm-icon STEAMDIR HICOLORDIR: write h96-steam-arm.png and steam-arm-desktop.png.

Steam's round icon redrawn on a dark, grainy green disc with a few small squares of vivid
colour, generated from fixed seeds so every install draws the same icons. The logo tells the
entries apart: chartreuse for Big Picture (steam-arm), bone for desktop mode
(steam-arm-desktop). The logo shape comes from the client's own steam_tray.ico, where it is
white with graded transparency over a blue disc; whiteness picks the logo, and the disc is
made opaque. Nothing is bundled with the package."""
import math, os, subprocess, sys
from PIL import Image
steam, dest = sys.argv[1], sys.argv[2]
src = None
for c in (os.path.join(steam, "public/steam_tray.ico"),
          "/opt/fex-rootfs/Ubuntu_24_04/usr/share/icons/hicolor/256x256/apps/steam.png"):
    if os.path.isfile(c):
        src = c; break
if not src:
    sys.exit(1)
im = Image.open(src)
if src.endswith(".ico"):
    im.size = max(im.info.get("sizes", {im.size}))
im = im.convert("RGBA").resize((256, 256), Image.LANCZOS)
p = im.load(); W, H = im.size; CX = CY = 127.5; R = 126.5

def h(x, y, seed):
    v = (x * 374761393 + y * 668265263 + seed * 2246822519) & 0xFFFFFFFF
    v = ((v ^ (v >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((v ^ (v >> 16)) & 0xFFFF) / 65535.0

def vnoise(x, y, cell, seed):
    gx, gy = x / cell, y / cell; x0, y0 = int(gx), int(gy); fx, fy = gx - x0, gy - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = h(x0, y0, seed), h(x0 + 1, y0, seed); c, d = h(x0, y0 + 1, seed), h(x0 + 1, y0 + 1, seed)
    top = a + (b - a) * fx
    return top + ((c + (d - c) * fx) - top) * fy

DARK, MID, LIGHT = (14, 24, 12), (30, 48, 24), (58, 82, 40)
POPS = ((0, 229, 255), (234, 255, 0), (255, 106, 0), (180, 92, 255))

def disc(x, y, seed):
    g = 0.55 * vnoise(x, y, 40, seed) + 0.30 * vnoise(x, y, 11, seed + 1) + 0.15 * h(x, y, seed + 2)
    col = [DARK[i] + (MID[i] - DARK[i]) * min(1, g * 1.4) for i in range(3)]
    s = h(x // 3, y // 3, seed + 3)
    if s > 0.93:
        col = [LIGHT[i] * (0.7 + 0.3 * h(x, y, 9)) for i in range(3)]
    elif s < 0.05:
        col = [c * 0.45 for c in col]
    cx, cy = x // 9, y // 9
    if h(cx, cy, seed + 4) > 0.975 and 1 <= x % 9 <= 6 and 1 <= y % 9 <= 6:
        col = list(POPS[int(h(cx, cy, seed + 5) * len(POPS)) % len(POPS)])
    return col

def draw(logo, seed):
    out = Image.new("RGBA", im.size); o = out.load()
    for y in range(H):
        for x in range(W):
            r_, g_, b_, a = p[x, y]
            t = min(1.0, max(0.0, (min(r_, g_, b_) - 120) / 135)); t = t * t * (3 - 2 * t)
            if math.hypot(x + .5 - CX, y + .5 - CY) < R - 1.5:
                a = 255
            bk = disc(x, y, seed)
            o[x, y] = tuple(int(bk[i] + (logo[i] - bk[i]) * t) for i in range(3)) + (a,)
    return out

for name, img in (("h96-steam-arm", draw((156, 200, 101), 11)), ("steam-arm-desktop", draw((196, 186, 160), 23))):
    for sz in (16, 32, 48, 64, 128, 256):
        d = os.path.join(dest, "%dx%d" % (sz, sz), "apps"); os.makedirs(d, exist_ok=True)
        img.resize((sz, sz), Image.LANCZOS).save(os.path.join(d, name + ".png"))
if os.path.isfile(os.path.join(dest, "index.theme")):
    subprocess.run(["gtk-update-icon-cache", "-q", "-f", "-t", dest], stderr=subprocess.DEVNULL)
ICONPY
  chmod 755 /usr/local/bin/h96-steam-arm-icon
  rm -f /usr/share/icons/hicolor/*/apps/h96-steam-arm.png /usr/share/icons/hicolor/*/apps/steam-arm-desktop.png
  if /usr/local/bin/h96-steam-arm-icon "$S" /usr/share/icons/hicolor; then
    say "     menu icons made from client's own icon"
  else
    say "     menu icons: made at first start, once client has downloaded its files"
  fi
}

# One function per entry, shared by the menu and the desktop icons.
bp_entry(){ cat > "$1" <<'DESK'
[Desktop Entry]
Type=Application
Name=Steam ARM
GenericName=Steam client, native ARM64
Comment=Native ARM64 Steam client; games run through the client's emulation tool on the Mali GPU
Exec=/usr/local/bin/steam-arm
Icon=h96-steam-arm
Terminal=false
Categories=Game;
Keywords=steam;arm;native;big picture;
StartupNotify=false
Actions=desktop;bigpicture;

[Desktop Action desktop]
Name=Open in desktop mode
Exec=/usr/local/bin/steam-arm --desktop

[Desktop Action bigpicture]
Name=Open in Big Picture
Exec=/usr/local/bin/steam-arm --bigpicture
DESK
}
dm_entry(){ cat > "$1" <<'DMDESK'
[Desktop Entry]
Type=Application
Name=Steam ARM (Desktop mode)
GenericName=Steam client, native ARM64, desktop interface
Comment=Opens native ARM64 Steam client in its desktop interface; restarts it there if it runs in Big Picture
Exec=/usr/local/bin/steam-arm --desktop
Icon=steam-arm-desktop
Terminal=false
Categories=Game;
Keywords=steam;arm;desktop;desktop mode;sign in;login;
StartupNotify=false
DMDESK
}
# desktop icon: entry written to the game user's Desktop, executable, owned by that user
desk_icon(){ install -d -o "$GAMEUSER" -g "$GAMEUSER" "$UHOME/Desktop"; "$1" "$2"; chmod 755 "$2"; chown "$GAMEUSER:$GAMEUSER" "$2"; }
BP_ICON="$UHOME/Desktop/Steam ARM.desktop"; DM_ICON="$UHOME/Desktop/Steam ARM (Desktop mode).desktop"

if want_icons; then
  steam_arm_icon
else
  rm -f /usr/share/icons/hicolor/*/apps/h96-steam-arm.png /usr/share/icons/hicolor/*/apps/steam-arm-desktop.png \
        /usr/local/bin/h96-steam-arm-icon
  for n in h96-steam-arm steam-arm-desktop; do rm -f "$UHOME"/.local/share/icons/hicolor/*/apps/"$n".png; done
fi

# "Steam ARM" menu entry, and the window frame rule for the desktop interface
if opt desktop; then
  bp_entry /usr/share/applications/h96-steam-arm.desktop
  # Client draws its own undraggable frame; this rule gives normal windows the WM's frame instead (Big Picture is fullscreen, unaffected).
  RID=h96-steam-arm-frame
  kw() { su - "$GAMEUSER" -c "kwriteconfig6 --file kwinrulesrc --group $1 --key $2 '$3'" 2>/dev/null; }
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kw "$RID" Description "Steam ARM: window manager frame"
    kw "$RID" wmclass steam; kw "$RID" wmclassmatch 1; kw "$RID" wmclasscomplete false
    kw "$RID" types 1; kw "$RID" noborder false; kw "$RID" noborderrule 2
    cur=$(su - "$GAMEUSER" -c "kreadconfig6 --file kwinrulesrc --group General --key rules" 2>/dev/null)
    case ",$cur," in *",$RID,"*) new="$cur";; *) new="${cur:+$cur,}$RID";; esac
    kw General rules "$new"; kw General count "$(printf '%s' "$new" | awk -F, '{print NF}')"
    kwin_reload
  fi
else
  rm -f /usr/share/applications/h96-steam-arm.desktop
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    cur=$(su - "$GAMEUSER" -c "kreadconfig6 --file kwinrulesrc --group General --key rules" 2>/dev/null)
    new=$(printf '%s' "$cur" | tr ',' '\n' | grep -vx h96-steam-arm-frame | paste -sd, -)
    n=$(printf '%s' "$new" | awk -F, 'NF{print NF} !NF{print 0}')
    su - "$GAMEUSER" -c "kwriteconfig6 --file kwinrulesrc --group General --key rules '$new'; kwriteconfig6 --file kwinrulesrc --group General --key count $n; kwriteconfig6 --file kwinrulesrc --group h96-steam-arm-frame --key Description --delete" 2>/dev/null
    kwin_reload
  fi
fi

# Desktop-mode menu entry; opening it while Big Picture runs restarts the client into desktop mode.
if opt desktop-mode; then dm_entry /usr/share/applications/h96-steam-arm-desktop.desktop
else rm -f /usr/share/applications/h96-steam-arm-desktop.desktop; fi

# desktop icons, each on its own
if opt icon-bigpicture; then desk_icon bp_entry "$BP_ICON"; else rm -f "$BP_ICON"; fi
if opt icon-desktop; then desk_icon dm_entry "$DM_ICON"; else rm -f "$DM_ICON"; fi

# panel tray icon
if opt tray; then
# Deck build registers no tray icon; this supplies one (Open, desktop mode, Stop, Quit), autostarted per session.
cat > /usr/local/bin/h96-steam-tray <<'TRAYPY'
#!/usr/bin/env python3
"""Plasma system tray icon for the native ARM64 Steam client.

Valve's Deck build of Steam (the aarch64 client used on this box) registers
no status-notifier item of its own, so the panel's tray never shows it. This
script supplies that item: a Steam icon, a menu to open the client in either
interface or stop it, and a title that reports whether it is running.
"""

import fcntl
import os
import signal
import subprocess
import sys

try:
    import gi

    gi.require_version("AyatanaAppIndicator3", "0.1")
    gi.require_version("Gtk", "3.0")
    from gi.repository import AyatanaAppIndicator3, GLib, Gtk
except (ImportError, ValueError):
    print("h96-steam-tray: install gir1.2-ayatanaappindicator3-0.1", file=sys.stderr)
    sys.exit(1)

STEAM_ARM_BIN = "/usr/local/bin/steam-arm"
CONF_PATH = "/etc/h96/steam-arm.conf"
ARMHOME_DIR = ".local/share/h96-steam-arm"


def load_conf(path):
    """Parse simple KEY=VALUE shell-style lines, ignoring comments and blanks."""
    values = {}
    try:
        with open(path, "r") as handle:
            lines = handle.readlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def resolve_armhome():
    """Mirror the launcher's ARMHOME resolution so the tray finds the same install.

    The config file lets a site override where the ARM Steam install lives
    without editing this script or the launcher; the environment variable
    lets a single session override it without touching the config file.
    """
    armhome_dir = ARMHOME_DIR
    armhome_override = None
    conf = load_conf(CONF_PATH)
    if "ARMHOME_DIR" in conf:
        armhome_dir = conf["ARMHOME_DIR"]
    if "H96_STEAM_ARM_HOME" in conf:
        armhome_override = conf["H96_STEAM_ARM_HOME"]
    if os.environ.get("H96_STEAM_ARM_HOME"):
        armhome_override = os.environ["H96_STEAM_ARM_HOME"]
    return armhome_override or os.path.join(os.path.expanduser("~"), armhome_dir)


def comm_matches(pid, name):
    try:
        with open("/proc/%s/comm" % pid, "r") as handle:
            return handle.read().strip() == name
    except OSError:
        return False


def pids_by_comm(name):
    """Read /proc/*/comm directly instead of shelling out to pgrep."""
    return [
        int(entry) for entry in os.listdir("/proc")
        if entry.isdigit() and comm_matches(entry, name)
    ]


def steam_running():
    return len(pids_by_comm("steam")) > 0


def signal_processes(name, sig):
    for pid in pids_by_comm(name):
        try:
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass


def launch(args):
    subprocess.Popen(
        [STEAM_ARM_BIN] + args,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def acquire_single_instance_lock():
    """Hold an flock for the process lifetime so a second tray exits quietly
    instead of showing a duplicate icon."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    lock_file = open(os.path.join(runtime_dir, "h96-steam-tray.lock"), "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(0)
    return lock_file  # kept alive on the caller's stack for the lock's duration


class SteamTray:
    def __init__(self):
        armhome = resolve_armhome()
        # Indicator API wants a theme icon name, not a path; point the theme dir at the client's own icon.
        icon_dir = os.path.join(armhome, ".local/share/Steam/public")
        self.indicator = AyatanaAppIndicator3.Indicator.new(
            "h96-steam-arm", "input-gaming-symbolic",
            AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        if os.path.isfile(os.path.join(icon_dir, "steam_tray_mono.png")):
            self.indicator.set_icon_theme_path(icon_dir)
            self.indicator.set_icon_full("steam_tray_mono", "Steam")
        self.indicator.set_title("Steam")
        self.indicator.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)

        self.menu = Gtk.Menu()
        self.open_item = Gtk.MenuItem(label="Open Steam")
        self.open_item.connect("activate", lambda *_: launch([]))
        self.desktop_item = Gtk.MenuItem(label="Open in desktop mode")
        self.desktop_item.connect("activate", lambda *_: launch(["--desktop"]))
        self.stop_item = Gtk.MenuItem(label="Stop Steam")
        self.stop_item.connect("activate", self.on_stop)
        quit_item = Gtk.MenuItem(label="Quit tray")
        quit_item.connect("activate", lambda *_: Gtk.main_quit())
        for item in (self.open_item, self.desktop_item, Gtk.SeparatorMenuItem(),
                     self.stop_item, Gtk.SeparatorMenuItem(), quit_item):
            self.menu.append(item)
        self.menu.show_all()
        self.indicator.set_menu(self.menu)

        self.update_state()
        GLib.timeout_add_seconds(3, self.on_poll)

    def on_stop(self, *_):
        # SIGTERM only: SIGKILL on a fullscreen title leaves the display in a misplaced/wrong-resolution state.
        signal_processes("steam", signal.SIGTERM)
        signal_processes("steamwebhelper", signal.SIGTERM)

    def on_poll(self):
        self.update_state()
        return True

    def update_state(self):
        running = steam_running()
        self.open_item.set_sensitive(not running)
        self.desktop_item.set_sensitive(True)   # the launcher restarts a running client
        self.stop_item.set_sensitive(running)
        self.indicator.set_title("Steam (running)" if running else "Steam")


def main():
    lock_file = acquire_single_instance_lock()  # noqa: F841
    SteamTray()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: Gtk.main_quit())
    Gtk.main()


if __name__ == "__main__":
    main()
TRAYPY
chmod 755 /usr/local/bin/h96-steam-tray
install -d -o "$GAMEUSER" -g "$GAMEUSER" "$UHOME/.config/autostart"
cat > "$UHOME/.config/autostart/h96-steam-tray.desktop" <<'TRAYDESK'
[Desktop Entry]
Type=Application
Name=Steam tray
Comment=Steam icon in the system tray for the ARM64 client
Exec=/usr/local/bin/h96-steam-tray
Icon=input-gaming-symbolic
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=KDE;GNOME;XFCE;
TRAYDESK
chown "$GAMEUSER:$GAMEUSER" "$UHOME/.config/autostart/h96-steam-tray.desktop"
say "     tray helper installed; it appears in the panel when the client starts"
else
  rm -f /usr/local/bin/h96-steam-tray "$UHOME/.config/autostart/h96-steam-tray.desktop"
  pkill -TERM -u "$GAMEUSER" -f /usr/local/bin/h96-steam-tray 2>/dev/null || true
fi

say "11/11  done"
cat <<EOM
  Client home:   $ARMHOME   (library under .local/share/Steam/steamapps)
  Games kept:    installed games, sign-in and settings were not touched
  Launch:        steam-arm   as $GAMEUSER, or the "Steam ARM" menu entry
  First start:   downloads the client package and restarts itself; sign in from Big Picture.
  Games:         x86 Linux titles run through the client's emulation tool; Windows titles through
                 the ARM64 Proton build the client downloads. A title with a Linux build on
                 record but Windows files installed needs: h96-steam-arm-compatmap <appid> proton-stable-arm64
  Optional:     $(for c in $COMPONENTS; do opt "$c" && printf ' %s' "$c" || printf ' [no %s]' "$c"; done)
  (re-run with --select or --skip to change; see --help)
EOM
