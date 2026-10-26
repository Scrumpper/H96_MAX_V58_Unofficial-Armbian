#!/bin/bash
# Input stage for v8.0 Ubuntu image build. Never touches /boot.
# Usage: stage.sh dryrun [--repin] | loader | pack
#   dryrun    validate inputs, shas, debs, scripts, repo; build repo index (signed or published signature); write stage/
#   loader    pinned loader set H96_LOADER into image raw loader area, read back + preflight_check.py (after build.sh splice)
#   pack      xz, round trip, sums into OUT/release (heavy; needs loader step for current H96_LOADER)
# H96_INPUTS: flat folder with pinned input debs (inputs.sha256); f5-rows.sh and h96-selftest.py come from repo
# H96_BASE_PACKAGES: /opt/h96-pkgs/Packages of v7.2 image (sha pinned); H96_REPO_ADDS: offline-repo add debs + SHA256SUMS
# H96_REPO_KEYDIR: signing key folder (owner only) or H96_REPO_SIG_FROM: folder with published Release, InRelease, Release.gpg
# H96_V72_XZ: v7.2 .img.xz (.sha256 beside it); H96_V72_ROOTFS_TAR (optional): v7.2 rootfs .tar.zst for Depends closure
# H96_UBUNTU_IDX (optional): Ubuntu resolute index files for adds provenance; H96_LOADER_DIR: runbook-files/ with loader blobs
# H96_RC_KREL: default kernel release (6.12.69-h96v58-8.0; 6.1.172-h96v58-8.0 = 6.1 default, no fallback)
# H96_RC_FBKREL: fallback kernel (6.1.172-h96v58-8.0; none drops it)
# H96_WORK, H96_RC_OUT: work and output folders; H96_HEAVY_LOCK=0: skip heavy lock
# H96_LOADER: old | A1 (default) | B1 | B2 (B sets refused)
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$H/../.." && pwd); W=${H96_INPUTS:-$H/inputs}
C=${XDG_CACHE_HOME:-$HOME/.cache}; WK=${H96_WORK:-$C/h96-v80-work}
ST=$WK/stage; EV=$WK/evidence
V72XZ=${H96_V72_XZ:-}
V72IMG=9f366f0945667a753f227cff9a93b33571a1e250f74802435f2ad0e57ecc2b2d
TARBALL=${H96_V72_ROOTFS_TAR:-/nonexistent}
BASEPKG=${H96_BASE_PACKAGES:-/nonexistent}; BASEPKGSHA=639fe1c864d0b9fe5f1d9d2d678ddf1fde40b01c3ed37a7ff23a2d06622a6274
R9REPO=${H96_REPO_NOADDS_REF:-/nonexistent}
ADDS=${H96_REPO_ADDS:-/nonexistent}
KEYRING=$REPO/keys/offline-repo-public.gpg
SA_SHA=0662920439f3cd0b1ea366a131b9e3c9e98ee41636d56cba3c23e0d157e04200
# H96-built adds (Maintainer MAINT): pinned to their build output instead of Ubuntu index provenance
H96ADDPIN="h96-vulkan-wsi_8.0.0~r25_arm64.deb 6988458bc26d9e71fa3f6f0863b4f8a67fd7fe18f00f98ca3d439502649f5828"
UIDX=${H96_UBUNTU_IDX:-/nonexistent}
MAINT='Scrumpper <190908034+Scrumpper@users.noreply.github.com>'
VERS="8.0.0~r10 8.0.0~r11 8.0.0~r12 8.0.0~r13 8.0.0~r14 8.0.0~r15 8.0.0~r16 8.0.0~r17 8.0.0~r18 8.0.0~r19 8.0.0~r20 8.0.0~r21 8.0.0~r22 8.0.0~r23 8.0.0~r24 8.0.0~r25 8.0.0~r26 8.0.0~r27 8.0.0~r28 8.0.0~r29 8.0.0~r30 8.0.0~r31 8.0.0~r32 8.0.0~r33 8.0.0~r34 8.0.0~r35 8.0.0~r36 8.0.0~r37 8.0.0~r38 8.0.0~r39"
NAME=H96-MAX-V58_Unofficial-Armbian_v8.0
OUT=${H96_RC_OUT:-$C/h96-v80-out}
KREL=${H96_RC_KREL:-6.12.69-h96v58-8.0}
case "$KREL" in
  6.12.69-h96v58-8.0) FBKREL=${H96_RC_FBKREL:-6.1.172-h96v58-8.0} ;;
  6.1.172-h96v58-8.0) FBKREL=${H96_RC_FBKREL:-none} ;;
  *) echo "H96_RC_KREL $KREL not a known kernel release" >&2; exit 2 ;;
esac
case "$FBKREL" in
  none|6.1.172-h96v58-8.0) ;;
  *) echo "H96_RC_FBKREL $FBKREL not a known fallback release" >&2; exit 2 ;;
esac
[ "$FBKREL" != "$KREL" ] || { echo "fallback equals default kernel" >&2; exit 2; }
LDR=${H96_LOADER_DIR:-/nonexistent}; LOADER=${H96_LOADER:-A1}
SCRIPTS="box-run.sh ns-up.sh ns-down.sh host-snap.sh repo-apply.sh f5-chroot.sh stage-kernel.sh image-brand.sh final-check.sh image-clean.sh repo-closure.py"
heavy() { if [ "${H96_HEAVY_LOCK:-1}" = 1 ]; then flock "$C/h96-heavy.lock" systemd-run --user --scope -q -p MemoryMax=20G nice -n10 "$@"
  else systemd-run --user --scope -q -p MemoryMax=20G nice -n10 "$@"; fi; }
fail=0; warn=0
ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }; wn() { echo "WARN $*"; warn=$((warn + 1)); }
noboot() { case "$(realpath -m "$1")" in /boot|/boot/*) echo "refuse /boot path $1" >&2; exit 2 ;; esac; }
bootsnap() { ls -la --time-style=full-iso /boot 2>/dev/null | md5sum | cut -d' ' -f1; }
ctl() { dpkg-deb -f "$1" "$2"; }
# stage must come from a passing dryrun of this folder's pins with this KREL
okstage() { [ -f "$ST/DRYRUN-OK" ] && [ "$(cut -d' ' -f3- "$ST/DRYRUN-OK")" = "$H/inputs.sha256" ] && [ "$(cat "$ST/krel" 2>/dev/null)" = "$KREL" ] &&
  [ "$(cat "$ST/fbkrel" 2>/dev/null)" = "$FBKREL" ] &&
  sha256sum -c --status "$ST/DRYRUN-OK" && (cd "$ST" && sha256sum -c --quiet inputs.sha256 scripts.sha256) || { echo "stage not from a passing dryrun of current pins (folder $H, kernel $KREL)"; exit 1; }; }

# highest Version among files matching glob
pick() {
  local best="" bv="" f v
  while IFS= read -r f; do
    case "$f" in *.deb) v=$(ctl "$f" Version) ;; *) v=0 ;; esac
    if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$bv"; then best=$f; bv=$v; fi
  done < <(case "$1" in @REPO@/*) compgen -G "$REPO/${1#@REPO@/}" ;; *) compgen -G "$W/$1" ;; esac)
  [ -n "$best" ] && echo "$best"
}

dryrun() {
  local repin=${1:-} b0 n f base name sha
  # unfilled pin refuses dryrun
  grep -q PLACEHOLDER "$H/inputs.sha256" && { bad "inputs.sha256 holds a PLACEHOLDER pin: $(grep PLACEHOLDER "$H/inputs.sha256")"; echo "dryrun fail=$fail"; return 1; }
  b0=$(bootsnap)
  for t in dpkg-deb dpkg-scanpackages gpg gpgv xz zstd shellcheck python3 sha256sum; do command -v "$t" >/dev/null || bad "tool $t missing"; done
  echo "== inputs"
  declare -A SRC
  while IFS=$'\t' read -r name glob; do
    case "$name" in ''|'#'*) continue ;; esac
    case "$name" in *-fb) [ "$FBKREL" = none ] && continue ;; esac
    glob=${glob//@KREL@/$KREL}; glob=${glob//@FBKREL@/$FBKREL}
    f=$(pick "$glob") || { bad "no source for $name ($glob)"; continue; }
    SRC[$name]=$f
  done < "$H/inputs.src"
  if [ "$repin" = --repin ]; then
    for name in "${!SRC[@]}"; do f=${SRC[$name]}; echo "$(sha256sum < "$f" | cut -d' ' -f1)  $(basename "$f")"; done | sort -k2 > "$H/inputs.sha256"
    echo "repinned $(wc -l < "$H/inputs.sha256") inputs"
  fi
  n=0
  for name in "${!SRC[@]}"; do
    f=${SRC[$name]}; base=$(basename "$f")
    sha=$(awk -v b="$base" '$2 == b {print $1}' "$H/inputs.sha256")
    if [ -z "$sha" ]; then bad "$base (newest $name) not pinned in inputs.sha256"; continue; fi
    [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$sha" ] && n=$((n + 1)) || bad "$base sha differs from pin"
  done
  [ "$(grep -c . "$H/inputs.sha256")" = "${#SRC[@]}" ] && ok "inputs pinned and matching: $n of ${#SRC[@]}" || bad "inputs.sha256 has $(grep -c . "$H/inputs.sha256") lines, sources ${#SRC[@]}"

  echo "== debs"
  local uv="" p v
  for p in h96-base h96-boot h96-net h96-audio h96-desktop h96-media h96-tools h96-gaming h96-kernel h96-dtb h96-kernel-fb h96-dtb-fb h96-kernel-switch steam-arm-setup; do
    f=${SRC[$p]:-}; [ -n "$f" ] || continue
    v=$(ctl "$f" Version)
    case $p in
      h96-kernel|h96-dtb) [ "$(ctl "$f" Package)" = "$p-$KREL" ] && ok "$p package for $KREL" || bad "$p package $(ctl "$f" Package), want $p-$KREL" ;;
      h96-kernel-fb|h96-dtb-fb) [ "$(ctl "$f" Package)" = "${p%-fb}-$FBKREL" ] && ok "$p package for $FBKREL" || bad "$p package $(ctl "$f" Package), want ${p%-fb}-$FBKREL" ;;
    esac
    case "$(basename "$f")" in *"_${v}_"*) ;; *) bad "$p file name vs Version $v" ;; esac
    if [ "$p" = steam-arm-setup ]; then
      [ "$v" = 3.1 ] && ok "steam-arm-setup 3.1" || bad "steam-arm-setup $v"
      [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$SA_SHA" ] && ok "steam-arm-setup = 3.1 final sha" || bad "steam-arm-setup sha vs Steam ARM 3.1 release asset"
      continue
    fi
    case " $VERS " in *" $v "*) ;; *) bad "$p Version $v not in $VERS" ;; esac
    [ "$(ctl "$f" Maintainer)" = "$MAINT" ] || bad "$p Maintainer $(ctl "$f" Maintainer)"
    case $p in h96-kernel*|h96-dtb*) ;; *) [ -z "$uv" ] && uv=$v; [ "$v" = "$uv" ] || bad "userland versions mixed ($p $v vs $uv)" ;; esac
    echo "  $p $v $(sha256sum < "$f" | cut -c1-16)"
  done
  ok "maintainer and version fields checked (userland $uv)"
  # never one version for two contents: compare against every earlier deb and pin on disk
  local led; led=$(mktemp)
  for f in "$W"/*.deb ${H96_LEDGER_DIRS:+$(for d in $H96_LEDGER_DIRS; do echo "$d"/*.deb; done)}; do
    [ -f "$f" ] && echo "$(sha256sum < "$f" | cut -d' ' -f1)  $(basename "$f")"
  done >> "$led"
  sort -u "$led" | awk '{c[$2]++; if (c[$2]==2) print $2}' > "$led.dup"
  # known, recorded reuse outside RC inputs (kernel-deb RESULTS r17: superseded first debs in out-r17-attempt1)
  local known="h96-kernel-6.12.69-h96v58-8.0r17_8.0.0~r17_arm64.deb"
  while read -r d; do
    case " $known " in *" $d "*) grep -q "  $d$" "$H/inputs.sha256" && bad "RC input $d has two contents" || wn "known recorded reuse (not an RC input): $d" ;;
      *) bad "version reused with different content: $d" ;; esac
  done < "$led.dup"
  ok "deb ledger: $(sort -u "$led" | wc -l) known files, $(wc -l < "$led.dup") names with two contents"
  rm -f "$led" "$led.dup"

  echo "== deb content"
  local x; x=$(mktemp -d); noboot "$x"
  for p in h96-base h96-audio h96-gaming h96-tools h96-kernel-switch steam-arm-setup; do mkdir -p "$x/$p"; dpkg-deb -x "${SRC[$p]}" "$x/$p"; dpkg-deb -e "${SRC[$p]}" "$x/$p/DEBIAN"; done
  REL=$(sed -n 's/^H96_RELEASE=//p' "$x/h96-base/etc/h96-release")
  echo "  H96_RELEASE=$REL; issue seed: $(head -1 "$x/h96-base/usr/lib/h96/seed/h96-issue")"
  case "$REL" in v8.0) ok "h96-base brands $REL" ;; *) bad "H96_RELEASE $REL (RC needs v8.0)" ;; esac
  grep -q "Unofficial Port v8\.0)" "$x/h96-base/usr/lib/h96/seed/h96-issue" && ! grep -q beta "$x/h96-base/usr/lib/h96/seed/h96-issue" "$x/h96-base/usr/lib/h96/seed/h96-issue.net" && ok "issue seeds name v8.0" || bad "issue seeds not v8.0"
  grep -q 'journalctl --header' "$x/h96-base/usr/lib/h96/h96-journal-orphans" && ok "journal orphan fix in h96-base" || bad "journal orphan fix missing"
  grep -qx 'Storage=persistent' "$x/h96-base/etc/systemd/journald.conf.d/limits.conf" && ok "journald drop-in Storage=persistent" || bad "journald drop-in"
  [ -f "$x/h96-base/etc/systemd/system/h96-firstboot-reboot.service.d/zz-h96-journal-orphans.conf" ] && ok "journal-orphans ExecStartPre drop-in" || bad "journal-orphans drop-in"
  x2=$(grep -h '^ *priority.session' "$x"/h96-audio/etc/pipewire/pipewire.conf.d/95-h96-silence-source.conf)
  echo "  silence source: $(echo "$x2" | tr -s ' ')"
  echo "$x2" | grep -q '= *2001' && wn "silence priority.session 2001 (r10 audit blocker unfixed)"
  echo "  h96-tools Depends: $(ctl "${SRC[h96-tools]}" Depends)"
  # r16: steam-arm-setup moved to Recommends (apt remove of it keeps h96-gaming); F5 installs it by name
  grep -q '^steam-arm-setup' <<< "$(ctl "${SRC[h96-gaming]}" Recommends | tr ',' '\n' | sed 's/^ *//')" && ok "h96-gaming Recommends steam-arm-setup: $(ctl "${SRC[h96-gaming]}" Recommends | tr ',' '\n' | grep steam-arm | xargs)" || bad "h96-gaming Recommends lacks steam-arm-setup"
  ctl "${SRC[h96-gaming]}" Depends | grep -q steam-arm && bad "h96-gaming Depends steam-arm-setup (r16 moved it to Recommends)"
  hk=$(sed -n 's/^H96_KERNEL=//p' "$x/h96-base/etc/h96-release")
  [ "$hk" = "$KREL" ] && ok "h96-release H96_KERNEL $hk" || wn "h96-release H96_KERNEL $hk, default kernel $KREL (conffile text only; consumer migrate-preflight on old boxes)"
  # install.sh sha follows the pinned deb; final-check compares image copy with deb
  si=$x/steam-arm-setup/usr/share/steam-arm-setup/install.sh
  [ -f "$si" ] && grep -qx 'SA_VERSION=3.1' "$si" && ok "Steam ARM install.sh in deb, SA_VERSION=3.1 ($(sha256sum < "$si" | cut -c1-8))" || bad "install.sh in steam-arm-setup deb"
  ks=$x/h96-kernel-switch
  [ ! -e "$ks/DEBIAN/postinst" ] && ok "kernel switch has no postinst (nothing enabled at install)" || { grep -q 'enable\|deb-systemd-helper' "$ks/DEBIAN/postinst" && bad "kernel switch postinst enables units" || ok "kernel switch postinst enables nothing"; }
  [ -z "$(find "$ks" -path '*.wants/*')" ] && ok "kernel switch ships no wants link" || bad "kernel switch wants link"
  if [ -n "$(find "$ks" -path '*system-preset*' -type f)" ]; then
    grep -hv '^#' "$ks"/usr/lib/systemd/system-preset/* | grep -q '^enable' && bad "kernel switch preset enables" || ok "kernel switch preset: $(grep -h '^disable' "$ks"/usr/lib/systemd/system-preset/* | wc -l) disable lines"
  else wn "kernel switch has no disable preset (preset-all would enable guard and timer)"; fi
  grep -q 'ConditionPathExists=/var/lib/h96-kernel-switch/trial' "$ks/usr/lib/systemd/system/h96-kernel-switch-guard.service" && ok "guard inert without trial record" || bad "guard condition"
  rm -rf "$x"

  echo "== Depends closure (v7.2 base status, offline repo, inputs)"
  local bs="" tmpb; tmpb=$(mktemp -d)
  if [ -f "$TARBALL" ]; then
    tar --zstd -xf "$TARBALL" -C "$tmpb" ./var/lib/dpkg/status ./opt/h96-pkgs/Packages ./usr/share/keyrings/h96-local-archive-keyring.gpg 2>/dev/null
    bs=$tmpb/var/lib/dpkg/status
    cmp -s "$tmpb/opt/h96-pkgs/Packages" "$BASEPKG" && ok "tarball repo Packages = r9 repo-pre Packages" || bad "tarball Packages differs"
    cmp -s "$tmpb/usr/share/keyrings/h96-local-archive-keyring.gpg" "$KEYRING" && ok "image keyring = repo keys/offline-repo-public.gpg" || bad "keyring differs"
  else wn "tarball $TARBALL absent: closure and rehearse skipped"; fi
  [ "$(sha256sum < "$BASEPKG" | cut -d' ' -f1)" = "$BASEPKGSHA" ] && ok "base Packages sha (v7.2 image index)" || bad "base Packages sha"
  local adddebs=()
  if [ -d "$ADDS" ]; then
    mapfile -t adddebs < <(find "$ADDS" -maxdepth 1 -name '*.deb' | sort)
    if [ -f "$ADDS/SHA256SUMS" ]; then (cd "$ADDS" && sha256sum -c --quiet SHA256SUMS) && ok "offline-repo-adds SHA256SUMS" || bad "offline-repo-adds SHA256SUMS"
      [ "$(grep -c '\.deb$' "$ADDS/SHA256SUMS")" = "${#adddebs[@]}" ] || bad "offline-repo-adds: SHA256SUMS lines vs debs"
    else wn "offline-repo-adds has no SHA256SUMS (debs unpinned)"; fi
    for f in "${adddebs[@]}"; do case "$(ctl "$f" Architecture)" in arm64|all) ;; *) bad "add $(basename "$f") arch $(ctl "$f" Architecture)" ;; esac; done
    echo "  adds: ${#adddebs[@]} ($(for f in "${adddebs[@]}"; do ctl "$f" Package; done | xargs))"
    printf '%s\n' "${adddebs[@]##*/}" | grep -q '^python3-tk_' && ok "python3-tk in adds" || wn "python3-tk not in offline-repo-adds"
  else wn "offline-repo-adds absent: python3-tk not added (h96-backup-gui needs it)"; fi
  local ubadds=() h96adds=()
  for f in "${adddebs[@]}"; do if [ "$(ctl "$f" Maintainer)" = "$MAINT" ]; then h96adds+=("$f"); else ubadds+=("$f"); fi; done
  for f in "${h96adds[@]}"; do
    [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$(awk -v b="$(basename "$f")" '$1 == b {print $2}' <<< "$H96ADDPIN")" ] &&
      ok "H96 add $(basename "$f") matches build pin" || bad "H96 add $(basename "$f") not pinned or sha differs"
  done
  if [ "${#ubadds[@]}" -gt 0 ]; then
    if [ -d "$UIDX" ]; then python3 -I "$H/adds-provenance.py" "$UIDX" "${ubadds[@]}" | sed 's/^/  /'; [ "${PIPESTATUS[0]}" = 0 ] && ok "adds listed in signed Ubuntu resolute arm64 index" || bad "adds provenance"
    else wn "no Ubuntu index at $UIDX: adds provenance unchecked"; fi
  fi

  echo "== offline repo index"
  rm -rf "$ST"; mkdir -p "$ST/repo"; noboot "$ST"
  python3 -I "$H/repo-build.py" "$BASEPKG" "$ST/repo" "${adddebs[@]}" || bad "repo-build"
  python3 -I "$H/repo-sign.py" "$ST/repo" || bad "repo-sign"
  if [ "${#adddebs[@]}" = 0 ] || ! [ -s "$ST/repo/add.sha256" ]; then
    for f in Release InRelease Release.gpg; do cmp -s "$ST/repo/$f" "$R9REPO/$f" && ok "no adds: $f byte-equal to r9" || bad "no adds: $f differs from r9"; done
  fi
  for f in "${adddebs[@]}"; do grep -q "  $(basename "$f")$" "$ST/repo/add.sha256" && cp -p "$f" "$ST/repo/"; done
  echo "$BASEPKGSHA  Packages" > "$ST/repo/base.sha256"
  (cd "$ST/repo" && sha256sum Packages Packages.gz Release InRelease Release.gpg drop.list base.sha256 > index.sha256)
  gpgv --keyring "$KEYRING" "$ST/repo/InRelease" 2>&1 | grep -q 'Good signature' && ok "staged InRelease gpgv" || bad "staged InRelease gpgv"
  find "$ST" -path '*gnupg*' -o -name '*.key' -o -name 'secring*' | grep -q . && bad "key material in stage" || ok "no key material in stage"
  if [ -n "$bs" ]; then
    # as F5 sees it: base status + staged repo index; prints what F5 preinstalls from repo
    local deblist=() p a
    for p in h96-base h96-boot h96-net h96-audio h96-desktop h96-media h96-tools h96-gaming steam-arm-setup h96-kernel h96-dtb h96-kernel-fb h96-dtb-fb h96-kernel-switch; do [ -n "${SRC[$p]:-}" ] && deblist+=("${SRC[$p]}"); done
    out=$(python3 -I "$H/repo-closure.py" "$bs" "$ST/repo/Packages" --deb "${deblist[@]}") && ok "input Depends resolvable from base + staged repo${out:+; F5 preinstalls: $(echo "$out" | xargs)}" || { echo "$out"; bad "unresolved Depends"; }
    for f in "${adddebs[@]}"; do
      a=$(ctl "$f" Package)
      if [ "$(ctl "$f" Maintainer)" = "$MAINT" ]; then   # H96 add: installed after image packages (h96-base)
        out=$(python3 -I "$H/repo-closure.py" "$bs" "$ST/repo/Packages" --deb "${deblist[@]}" --want "$a") && ok "H96 add $a installable offline after image packages: $(echo "$out" | grep -c .) repo packages ($(echo "$out" | grep -oE '^(mesa-vulkan-drivers|libvulkan1) [^ ]+' | xargs))" || { echo "$out"; bad "add $a not installable offline"; }
      else
        out=$(python3 -I "$H/repo-closure.py" "$bs" "$ST/repo/Packages" --want "$a") || { echo "$out"; bad "add $a not installable offline"; }
      fi
    done
    [ "${#adddebs[@]}" -gt 0 ] && ok "each add installable from base + staged repo"
    # mpv r18 (h96-video-setup PKGS) links libpipewire and libpulse: offline install on console first boot
    local vx vp; vx=$(mktemp -d); dpkg-deb -x "${SRC[h96-media]}" "$vx"
    vp=$(sed -n '/^PKGS="/,/"/p' "$vx/usr/lib/h96/h96-video-setup.sh" | tr -d '\\"' | sed 's/^PKGS=//' | xargs); rm -rf "$vx"
    echo "  h96-video-setup PKGS: $vp"
    for p in libpipewire-0.3-0t64 libpulse0; do case " $vp " in *" $p "*) ;; *) wn "h96-video-setup PKGS lacks $p" ;; esac; done
    # shellcheck disable=SC2086
    out=$(python3 -I "$H/repo-closure.py" "$bs" "$ST/repo/Packages" --want $vp libspa-0.2-modules) && ok "h96-video-setup PKGS + libspa-0.2-modules installable offline ($(echo "$out" | grep -c .) repo packages)" || { echo "$out"; bad "h96-video-setup PKGS not installable offline"; }
  fi
  rm -rf "$tmpb"

  echo "== scripts"
  for s in $SCRIPTS repo-build.py repo-sign.py loader-pin.py stage.sh; do
    case "$s" in *.sh) bash -n "$H/$s" || bad "bash -n $s" ;; *.py) python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$H/$s" || bad "parse $s" ;; esac
  done
  (cd "$H" && shellcheck -S warning -e SC1090,SC1091 ./*.sh) > "$EV/shellcheck.txt" 2>&1 && ok "shellcheck -S warning clean" || bad "shellcheck: $(grep -c '^In ' "$EV/shellcheck.txt") findings ($EV/shellcheck.txt)"
  out=$({ grep -nE '(^|[;&|[:space:]])touch[[:space:]]' "$H/ns-up.sh"; grep -nE '>[[:space:]]*"?/' "$H/ns-up.sh" | grep -v '/dev/null'; } | grep -v '^[0-9]*:#')
  [ -z "$out" ] && ok "ns-up.sh: no probe writes" || { echo "$out"; bad "ns-up.sh writes outside scratch"; }
  [ "$(grep -c 'isro /boot\|isro /' "$H/ns-up.sh")" -ge 2 ] && grep -q 'findmnt -no OPTIONS -M' "$H/ns-up.sh" && ok "ns-up.sh: findmnt ro checks" || bad "ns-up.sh ro checks"
  out=$({ grep -nE '(^|[;&|[:space:](])(update-initramfs|u-boot-update|flash-kernel)([[:space:]);]|$)' "$H"/*.sh; grep -n 'extlinux' "$H"/*.sh | grep -v '! -e /boot/extlinux'; } | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|/stage\.sh:')
  [ -z "$out" ] && ok "no update-initramfs, u-boot-update, flash-kernel or extlinux writes" || { echo "$out"; bad "boot tool call in scripts"; }
  bash -n "${SRC[f5-rows.sh]}" && ok "f5-rows.sh syntax ($(grep -c '^row ' "${SRC[f5-rows.sh]}") rows)" || bad "f5-rows.sh syntax"

  echo "== base image"
  (cd "$(dirname "$V72XZ")" && sha256sum -c --status "$(basename "$V72XZ").sha256") && ok "v7.2 img.xz sha (ad256a21)" || bad "v7.2 img.xz sha"
  if [ "${H96_SKIP_IMGSHA:-0}" != 1 ]; then
    s=$(heavy sh -c 'xz -dc "$1" | sha256sum | cut -d" " -f1' _ "$V72XZ")
    [ "$s" = "$V72IMG" ] && ok "v7.2 img sha (9f366f09)" || bad "v7.2 img sha $s"
  fi

  echo "== stage"
  for name in "${!SRC[@]}"; do cp -p "${SRC[$name]}" "$ST/"; done
  for s in $SCRIPTS; do cp -p "$H/$s" "$ST/"; done
  cp -p "$H/inputs.sha256" "$ST/"
  echo "$KREL" > "$ST/krel"   # read by stage-kernel.sh and final-check.sh
  echo "$FBKREL" > "$ST/fbkrel"
  (cd "$ST" && sha256sum $SCRIPTS krel fbkrel > scripts.sha256 && sha256sum -c --quiet inputs.sha256) && ok "stage inputs match pins (kernel $KREL)" || bad "stage inputs"
  echo "$V72IMG  work.img" > "$ST/base-img.sha256"
  du -sh "$ST" | sed 's/^/  stage size /'
  [ "$(bootsnap)" = "$b0" ] && ok "laptop /boot listing unchanged" || bad "laptop /boot listing changed"
  echo "dryrun fail=$fail warn=$warn"
  # build.sh takes only a stage from a passing dry run
  [ "$fail" = 0 ] && sha256sum "$H/inputs.sha256" > "$ST/DRYRUN-OK"
  [ "$fail" = 0 ]
}

# box image sha kept in .img.box.sha256; .img.sha256 and .img.loader follow the pinned image
loader() {
  [ -f "$OUT/$NAME.img" ] || { echo "build.sh splice first"; exit 1; }
  noboot "$OUT"
  (cd "$OUT" && sha256sum -c --status "$NAME.img.sha256") || { echo "img sha"; exit 1; }
  [ -f "$OUT/$NAME.img.box.sha256" ] || sed "s/  $NAME.img$/  $NAME.img (box)/" "$OUT/$NAME.img.sha256" > "$OUT/$NAME.img.box.sha256"
  (cd "$LDR/runbook-files" && sha256sum -c --quiet --ignore-missing SHA256SUMS) || { echo "runbook-files SHA256SUMS"; exit 1; }
  local s
  heavy python3 -I "$H/loader-pin.py" "$OUT/$NAME.img" "$LOADER" "$LDR/runbook-files" "$H/preflight_check.py" || { echo "loader step FAIL"; exit 1; }
  s=$(sha256sum < "$OUT/$NAME.img" | cut -d' ' -f1)
  echo "$s  $NAME.img" > "$OUT/$NAME.img.sha256"
  printf 'loader %s\nimg %s\n' "$LOADER" "$s" > "$OUT/$NAME.img.loader"
  echo "loader $LOADER rc=0 img $s"
}

pack() {
  local D="$OUT/release" i x
  [ -f "$OUT/$NAME.img" ] || { echo "build.sh splice first"; exit 1; }
  (cd "$OUT" && sha256sum -c --status "$NAME.img.sha256") || { echo "img sha"; exit 1; }
  [ "$(cat "$OUT/$NAME.img.loader" 2>/dev/null)" = "$(printf 'loader %s\nimg %s' "$LOADER" "$(cut -d' ' -f1 "$OUT/$NAME.img.sha256")")" ] ||
    { echo "run loader step first (H96_LOADER=$LOADER)"; exit 1; }
  heavy xz -T12 -9 -k -f "$OUT/$NAME.img" || exit 1
  i=$(cut -d' ' -f1 "$OUT/$NAME.img.sha256"); x=$(sha256sum < "$OUT/$NAME.img.xz" | cut -d' ' -f1)
  [ "$(heavy sh -c 'xz -dc "$1" | sha256sum | cut -d" " -f1' _ "$OUT/$NAME.img.xz")" = "$i" ] && echo "PASS xz round trip" || { echo "FAIL xz round trip"; exit 1; }
  mkdir -p "$D"; cp -p "$OUT/$NAME.img.xz" "$D/"
  echo "$x  $NAME.img.xz" > "$D/$NAME.img.xz.sha256"; echo "$i  $NAME.img" > "$D/$NAME.img.sha256"
  echo "$x  $NAME.img.xz" > "$D/SHA256SUMS"   # files in folder only; .img sum in its sidecar
  (cd "$D" && sha256sum -c SHA256SUMS)
}

mkdir -p "$EV"
case "${1:-}" in
  dryrun) dryrun "${2:-}" 2>&1 | tee "$EV/dryrun.txt"; exit "${PIPESTATUS[0]}" ;;
  pack) pack ;;
  loader) loader 2>&1 | tee "$EV/loader.txt"; exit "${PIPESTATUS[0]}" ;;
  *) sed -n '2,18p' "$0"; exit 2 ;;
esac
