"""Debian edition (H96_EDITION=debian) of the userland debs: version, changelog entry, file overrides by package path.
Each text override replaces exact strings that must occur once in the Ubuntu-edition output (fails loudly otherwise),
so a later change of the Ubuntu text stops the build instead of producing a silent mix."""
import hashlib, os

HERE = os.path.dirname(os.path.abspath(__file__))
ED = os.path.join(os.path.dirname(HERE), "edition-debian")
DEB_VERSION = "8.0.0~r40+deb13.1"
DEB_DIST = "trixie"
DEB_DATE = "Tue, 27 Oct 2026 12:00:00 +0000"  # after Ubuntu r40 DATE (27 Oct 06:00)
WP_DEB = "0.5.18-1~h96.1+deb13.1"
MESA_DEB = "26.1.6-1~bpo13+1"
OSID = '"$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"'
# video stack rebuilt against trixie (debian-edition/video); sha pinned, set by the build of that stack
STACK = os.environ.get("H96_DEB_STACK", "")
STACK_SHA = os.environ.get("H96_DEB_STACK_SHA", "")
# mpv-mpris plugin rebuilt against trixie glib (debian-edition/video/build-mpris-in-container.sh), sha pinned
MPRIS = os.environ.get("H96_DEB_MPRIS", "")
MPRIS_SHA = os.environ.get("H96_DEB_MPRIS_SHA", "")
# libc6 floor of rebuilt stack binaries (highest GLIBC_ symbol version they need)
MEDIA_LIBC = os.environ.get("H96_DEB_MEDIA_LIBC", "2.38")

DEB_CHANGES_COMMON = ["Debian 13 trixie build of 8.0.0~r40 (Debian Edition)."]
DEB_CHANGES = {
    "h96-base": ["Mesa pin also names Debian trixie-backports 26.1.6-1~bpo13+1, every Mesa binary of that build "
                 "(OpenCL, Teflon, drm-shim and dev packages too), so no Mesa package resolves to trixie 25.0.7.",
                 "/etc/h96-release names Debian Edition (H96_EDITION=debian).",
                 "h96-online-extras probes deb.debian.org on Debian; gamescope and libspa-0.2-modules-extra skipped "
                 "there (not in Debian 13).",
                 "Console banner and os-release VARIANT name Debian Edition.",
                 "armbian-firstlogin copy rebased on Armbian BSP 26.8.3; H96 change kept (bounded wait for system "
                 "start).",
                 "COMMANDS.md text names Debian 13 where Ubuntu text named Ubuntu: Chromium, Python 3.13, mpv, "
                 "h96-perf over busctl, gamescope and libspa-0.2-modules-extra absent (deb13.2; Steam ARM 3.1 text from r39).",
                 "COMMANDS.md: ophub update guard text states Debian Edition carries no ophub scripts (no "
                 "armbian-sync); h96-vulkan-wsi section states package is not provided on Debian Edition (Mesa pin "
                 "26.1.4~kisak1~r cannot be met by trixie-backports Mesa)."],
    "h96-gaming": ["h96-gaming-setup: Mesa target from /etc/os-release (Debian: 26.1.6-1~bpo13+1); online extras without "
                   "gamescope on Debian.",
                   "h96-steam-fex-install: FEX package source as Ubuntu noble build with pinned key when "
                   "add-apt-repository is absent (Debian); keyring directory made with install -d."],
    "h96-desktop": ["h96-kde-configure: X11 packages installed one by one, so one missing name no longer voids the "
                    "set; plasma-session-x11 skipped where absent (Plasma 6.3 carries X11 session in "
                    "plasma-workspace); Noto fonts in place of fonts-ubuntu on Debian."],
    "h96-audio": ["h96-wireplumber-offline: wanted version follows distro (Debian: 0.5.18-1~h96.1+deb13.1); header "
                  "names both distro builds."],
    "h96-media": ["Video stack (mpv 0.41.0 with PipeWire and PulseAudio audio outputs, ffmpeg-rockchip 40c412d, same "
                  "patches) rebuilt against Debian 13 libraries; h96-video-setup runtime package list per distro, "
                  "libpipewire-0.3-0t64 and libpulse0 included.",
                  "mpv MPRIS plugin (mpv-mpris 1.2, same patch) rebuilt against Debian 13 glib."],
}


def rep(t, old, new, dst):
    n = t.count(old)
    if n != 1:
        raise SystemExit(f"edition-debian: {dst}: expected 1 match, found {n}: {old[:60]!r}")
    return t.replace(old, new)


def _mesa_pin(t, d):
    t = rep(t, "# (26.1.4~kisak1~r). Stock/newer Mesa does not drive Mali-G610 Panthor here,\n",
            "# (26.1.4~kisak1~r) on Ubuntu, trixie-backports 26.1.6-1~bpo13+1 on Debian.\n"
            "# Stock/newer Mesa does not drive Mali-G610 Panthor here,\n", d)
    # every binary of src:mesa in trixie-backports: an unpinned one would resolve to trixie 25.0.7 (exact Depends fail)
    pk = ("Package: libgl1-mesa-dri mesa-vulkan-drivers libglx-mesa0 libegl-mesa0 libgbm1 mesa-libgallium "
          "libglapi-mesa mesa-va-drivers mesa-vdpau-drivers mesa-opencl-icd mesa-teflon-delegate mesa-drm-shim "
          "libgbm-dev libegl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev mesa-common-dev\n")
    return rep(t, "Pin-Priority: 1001\n",
               f"Pin-Priority: 1001\n\n# Debian 13: same series from trixie-backports (no kisak build for glibc 2.41)\n"
               f"{pk}Pin: version {MESA_DEB}\nPin-Priority: 1001\n", d)


def _release(t, d):
    # kernel keys come from Ubuntu r21 (6.12 default, 6.1 fallback); edition key appended
    rep(t, "H96_KERNEL=6.12.69-h96v58-8.0\nH96_KERNEL_FALLBACK=6.1.172-h96v58-8.0\n", "", d)
    return t + "H96_EDITION=debian\n"


def _extras(t, d):
    t = rep(t, 'PKGS="box64-rk3588 gamescope libspa-0.2-modules-extra"\n',
            'PKGS="box64-rk3588 gamescope libspa-0.2-modules-extra"\n'
            '# Debian 13 carries neither gamescope nor libspa-0.2-modules-extra\n'
            f'[ {OSID} = debian ] && PKGS="box64-rk3588"\n'
            'PROBE=ports.ubuntu.com\n'
            f'[ {OSID} = debian ] && PROBE=deb.debian.org\n', d)
    return rep(t, "  if getent hosts ports.ubuntu.com >/dev/null 2>&1; then ok=1; break; fi\n",
               '  if getent hosts "$PROBE" >/dev/null 2>&1; then ok=1; break; fi\n', d)


def _gaming(t, d):
    t = rep(t, 'MESA_VER="26.1.4~kisak1~r"                        # kisak GL+Vulkan lockstep target\n',
            'MESA_VER="26.1.4~kisak1~r"                        # kisak GL+Vulkan lockstep target\n'
            f'[ {OSID} = debian ] && MESA_VER="{MESA_DEB}"   # Debian 13: trixie-backports build\n', d)
    return rep(t, 'APT_PKGS_ONLINE="box64-rk3588 gamescope"\n',
               'APT_PKGS_ONLINE="box64-rk3588 gamescope"\n'
               f'[ {OSID} = debian ] && APT_PKGS_ONLINE="box64-rk3588"   # no gamescope in Debian 13\n', d)


FEX_DEB = r'''if ! command -v add-apt-repository >/dev/null && [ "$(. /etc/os-release 2>/dev/null; echo "${ID:-}")" = debian ]; then
  # Debian: FEX PPA Ubuntu noble build as deb822 source, signing key fingerprint checked (as steam-arm-setup)
  FEXSRC=/etc/apt/sources.list.d/steam-arm-fex.sources; FEXKEY=/etc/apt/keyrings/steam-arm-fex.gpg
  FEXFPR=EDB98BFE8A2310DC9C4A376E76DBFEBEA206F5AC
  if ! grep -rqs "fex-emu/fex" /etc/apt/sources.list.d/; then
    t=$(mktemp -d)
    curl -fsSL --proto =https "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$FEXFPR" -o "$t/key.asc" || die "FEX key download failed"
    k=$(GNUPGHOME=$t gpg --batch --show-keys --with-colons "$t/key.asc" 2>/dev/null | awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}')
    [ "$k" = "$FEXFPR" ] || die "FEX key fingerprint ${k:-none}, expected $FEXFPR"
    GNUPGHOME=$t gpg --batch --yes --dearmor -o "$t/key.gpg" "$t/key.asc" || die "FEX key convert failed"
    install -d -m 0755 /etc/apt/keyrings && install -m 0644 "$t/key.gpg" "$FEXKEY"
    printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/fex-emu/fex/ubuntu\nSuites: noble\nComponents: main\nArchitectures: arm64\nSigned-By: %s\n' "$FEXKEY" > "$FEXSRC"
    rm -rf "$t"
  fi
else
command -v add-apt-repository >/dev/null || apt-get install -y software-properties-common
grep -rq "fex-emu/fex" /etc/apt/sources.list.d/ 2>/dev/null || add-apt-repository -y "$FEXPPA"
fi
'''


def _fex(t, d):
    return rep(t, 'command -v add-apt-repository >/dev/null || apt-get install -y software-properties-common\n'
               'grep -rq "fex-emu/fex" /etc/apt/sources.list.d/ 2>/dev/null || add-apt-repository -y "$FEXPPA"\n',
               FEX_DEB, d)


def _kde(t, d):
    t = rep(t, "    xserver-xorg dbus-x11 dmz-cursor-theme fonts-ubuntu gtk2-engines \\\n",
            "    xserver-xorg dbus-x11 dmz-cursor-theme $H96_UIFONT gtk2-engines \\\n", d)
    t = rep(t, "KDE_TIER_MARKER=/etc/armbian/desktop/kde-plasma.tier\n",
            "KDE_TIER_MARKER=/etc/armbian/desktop/kde-plasma.tier\n"
            "# fonts-ubuntu is non-free on Debian: Noto there\n"
            f"H96_UIFONT=fonts-ubuntu; [ {OSID} = debian ] && H96_UIFONT=fonts-noto-core\n", d)
    return rep(t, "env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 -o APT::Install-Recommends=1 \\\n"
               "  kwin-x11 lightdm lightdm-gtk-greeter \\\n  xinit x11-xserver-utils plasma-session-x11 2>&1 || true\n",
               "# one package per call: a name the distro lacks (plasma-session-x11 on Plasma 6.3) must not void the rest\n"
               "for p in kwin-x11 lightdm lightdm-gtk-greeter xinit x11-xserver-utils plasma-session-x11; do\n"
               "  LC_ALL=C apt-cache policy \"$p\" 2>/dev/null | grep -q '^  Candidate: [0-9]' || { echo \"  $p: not in apt, skipped\"; continue; }\n"
               "  env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=600 -o APT::Install-Recommends=1 \"$p\" 2>&1 || true\n"
               "done\n", d)


def _wp(t, d):
    t = rep(t, "over the distro 0.5.13 once", "over the distro build (Ubuntu 0.5.13, Debian 0.5.8) once", d)
    return rep(t, "WANT=0.5.18-1~h96.1\n", f"WANT=0.5.18-1~h96.1\n[ {OSID} = debian ] && WANT={WP_DEB}\n", d)


VIDEO_DEB = ("libplacebo349 libass9 liblcms2-2 libxcb-dri2-0 libv4l-rkmpp libluajit-5.1-2 libvulkan1 libegl1 libgles2 "
             "libglvnd0 libgbm1 libwayland-client0 libwayland-cursor0 libwayland-egl1 libdrm2 libfreetype6 libfontconfig1 "
             "libharfbuzz0b libfribidi0 libunibreak6 libgnutls30t64 libxv1 libxss1 libxpresent1 libxrandr2 librockchip-mpp1 "
             "libxfixes3 libdisplay-info2 libdav1d7 libasound2t64 libxkbcommon0 libbz2-1.0 zlib1g libpipewire-0.3-0t64 libpulse0")


def _video(t, d):
    return rep(t, "irqbalance\"\n",
               "irqbalance\"\n# Debian 13 names (libplacebo349, libdisplay-info2): stack rebuilt against trixie\n"
               f'[ {OSID} = debian ] && PKGS="nodejs yt-dlp cage {VIDEO_DEB} irqbalance"\n', d)


def _branding(t, d):
    t = rep(t, 'rel=$(sed -n \'s/^H96_RELEASE=//p\' /etc/h96-release 2>/dev/null)\n',
            'rel=$(sed -n \'s/^H96_RELEASE=//p\' /etc/h96-release 2>/dev/null)\n'
            '# edition suffix (Debian Edition) from /etc/h96-release\n'
            'sfx=; [ "$(sed -n \'s/^H96_EDITION=//p\' /etc/h96-release 2>/dev/null)" = debian ] && sfx=" Debian Edition"\n', d)
    return rep(t, 'want_v="VARIANT=\\"H96 Max V58 Unofficial Port $rel\\""', 'want_v="VARIANT=\\"H96 Max V58 Unofficial Port $rel$sfx\\""', d)


def _issue(t, d):
    return rep(t, "(H96 Max V58 Unofficial Port v8.0)", "(H96 Max V58 Unofficial Port v8.0 Debian Edition)", d)


GUARD_ROW = ("puts refusing `/usr/sbin/armbian-update` back when `armbian-sync` (ophub script sync) replaces it with "
             "ophub kernel updater;")
GUARD_TXT = ("exits 1: ophub updater would write ophub kernel into `/boot` over H96 kernel. `armbian-sync`\n"
             "copies ophub scripts, ophub updater included, into `/usr/sbin`; `h96-armbian-update-guard.path`\n"
             "sees it and puts stub back (copy `/usr/lib/h96/armbian-update-h96`). Other ophub\n"
             "scripts `armbian-sync` updates stay. Kernel arrives with image releases.\n")


def _commands(t, d):
    # Debian base has no ophub scripts (decision 21); line count kept equal to Ubuntu text
    t = rep(t, GUARD_ROW, "puts refusing `/usr/sbin/armbian-update` back when ophub kernel updater replaces it "
            "(Debian Edition: no ophub scripts, no `armbian-sync`);", d)
    return rep(t, GUARD_TXT,
               "exits 1: ophub updater would write ophub kernel into `/boot` over H96 kernel. Debian Edition\n"
               "carries no ophub scripts (no `armbian-sync`); `h96-armbian-update-guard.path` still watches\n"
               "`/usr/sbin/armbian-update` and puts stub back (copy `/usr/lib/h96/armbian-update-h96`) when\n"
               "ophub updater arrives by hand. Kernel arrives with image releases.\n", d)


VWSI_LINE = "other versions.\n\n```bash\nh96-vulkan-wsi status"


# Debian wording for 14 lines of the packaged COMMANDS text (deb13.2 had 16; Steam ARM 3.1 pairs moved to r39); each old string occurs once in the Ubuntu text
COMMANDS_WORDING = [
    ("decoding it in software. Browser video decode itself stays on CPU (Ubuntu's Chromium",
     "decoding it in software. Browser video decode itself stays on CPU (Debian's Chromium"),
    ('`h96-perf` calls `powerprofilesctl set`. Profile service accepts change from root or',
     '`h96-perf` sets profile over D-Bus (`busctl`). Profile service accepts change from root or'),
    ('`powerprofilesctl launch -p performance -r game -- %command%`. Explicit profile change',
     '`powerprofilesctl launch` (needs `powerprofilesctl`, not on Debian 13). Explicit profile change'),
    ('only. `power sync` reads active profile (`powerprofilesctl get`, governors as fallback)',
     'only. `power sync` reads active profile (`powerprofilesctl get` when present, else governors)'),
    ('3.12. This image is Armbian on Ubuntu 26.04 with Python 3.14, so those wheels will not install',
     '3.12. This image is Armbian on Debian 13 with Python 3.13, so those wheels will not install'),
    ('> (`box64-rk3588-fallback.deb`), and `box64-rk3588` plus `gamescope` install from',
     '> (`box64-rk3588-fallback.deb`), and `box64-rk3588` installs from'),
    ('> apt via `h96-online-extras` first time box reaches network, `box64-rk3588` pinned to tested 0.4.3 (with',
     '> apt via `h96-online-extras` first time box reaches network, pinned to tested 0.4.3 (gamescope and'),
    ('> `libspa-0.2-modules-extra`, which Bluetooth AAC needs). `box86` is included as',
     '> `libspa-0.2-modules-extra` are not in Debian 13). `box86` is included as'),
    ('`-c, --compositor cage|gamescope` (default cage), `-r, --res WxH` (gamescope),',
     '`-c, --compositor cage|gamescope` (default cage; gamescope not in Debian 13), `-r, --res WxH` (gamescope),'),
    ('`box64-rk3588`, `gamescope`), validates PanVK and box64, writes',
     '`box64-rk3588`; gamescope not in Debian 13), validates PanVK and box64, writes'),
    ('| `h96-online-extras.service` | retries packages that require internet (`box64-rk3588`, `gamescope`, `libspa-0.2-modules-extra` for Bluetooth AAC) until they install |',
     '| `h96-online-extras.service` | retries packages that require internet (`box64-rk3588`; gamescope and `libspa-0.2-modules-extra` are not in Debian 13) until they install |'),
    ('- Video stack from Ubuntu `mpv`, `libmpv2`, `libmpv-dev`, `ffmpeg` and `librockchip-mpp1`:',
     '- Video stack from Debian `mpv`, `libmpv2`, `libmpv-dev`, `ffmpeg` and `librockchip-mpp1`:'),
    ('  `librockchip_mpp.so.0`, and `/etc/mpv/mpv.conf` (purging Ubuntu `mpv` keeps it).',
     '  `librockchip_mpp.so.0`, and `/etc/mpv/mpv.conf` (purging Debian `mpv` keeps it).'),
    ('Installing Ubuntu `mpv` adds no second menu entry: `/usr/share/applications/mpv.desktop`',
     'Installing Debian `mpv` adds no second menu entry: `/usr/share/applications/mpv.desktop`'),
]


def _commands_all(t, d):
    t = _commands(t, d)
    for old, new in COMMANDS_WORDING:
        t = rep(t, old, new, d)
    # h96-vulkan-wsi needs kisak Mesa 26.1.4; Debian Edition runs backports 26.1.6: package absent, same line count
    return rep(t, VWSI_LINE, "other versions. Debian Edition: package not provided (trixie-backports Mesa cannot meet pin).\n\n"
               "```bash\nh96-vulkan-wsi status", d)


def _firstlogin(t, d):
    return open(os.path.join(ED, "armbian-firstlogin")).read()


TEXT = {
    "/etc/apt/preferences.d/01-h96-protect-mesa": _mesa_pin,
    "/etc/h96-release": _release,
    "/usr/lib/h96/h96-online-extras.sh": _extras,
    "/usr/lib/h96/h96-gaming-setup.sh": _gaming,
    "/usr/lib/h96/steam/h96-steam-fex-install.sh": _fex,
    "/usr/lib/h96/h96-kde-configure.sh": _kde,
    "/usr/lib/h96/h96-wireplumber-offline.sh": _wp,
    "/usr/lib/h96/h96-video-setup.sh": _video,
    "/usr/lib/armbian/armbian-firstlogin": _firstlogin,
    "/usr/lib/h96/h96-branding.sh": _branding,
    "/usr/lib/h96/seed/h96-issue": _issue,
    "/usr/lib/h96/seed/h96-issue.net": _issue,
    "/usr/share/doc/h96-base/COMMANDS.md": _commands_all,
}
USED = set()
STACK_PATH = "/usr/lib/h96/video/h96-video-stack.tar.gz"
MPRIS_PATH = "/usr/lib/h96/mpv-mpris/mpris.so"
BYTES = {STACK_PATH: (lambda: STACK, lambda: STACK_SHA, "H96_DEB_STACK"), MPRIS_PATH: (lambda: MPRIS, lambda: MPRIS_SHA, "H96_DEB_MPRIS")}


def deb_text(dst, txt):
    f = TEXT.get(dst)
    if not f:
        return txt
    USED.add(dst)
    return f(txt, dst)


def deb_bytes(dst, raw):
    if dst not in BYTES:
        return raw
    USED.add(dst)
    path, sha, env = BYTES[dst][0](), BYTES[dst][1](), BYTES[dst][2]
    if not path:
        raise SystemExit(f"edition-debian: {env} not set ({dst})")
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != sha:
        raise SystemExit(f"edition-debian: {dst} sha differs from {env}_SHA")
    return data


def check_all_used():
    miss = (set(TEXT) | set(BYTES)) - USED
    if miss:
        raise SystemExit(f"edition-debian: overrides not applied: {sorted(miss)}")
