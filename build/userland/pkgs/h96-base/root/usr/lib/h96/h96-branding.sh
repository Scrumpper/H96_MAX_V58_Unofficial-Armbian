#!/bin/bash
# reassert H96 branding after a package overwrites it
#
# /etc/armbian-release, armbian-image-release, issue and issue.net are conffiles
# patched directly at image-build time via raw writes, not through dpkg, so dpkg sees
# them as untouched and a reinstall/upgrade of the owning package overwrites them silently
#
# /etc/h96-issue and h96-issue.net are h96-base seeds, refreshed on each package configure;
# only their Armbian version token follows os-release
for f in /etc/armbian-release /etc/armbian-image-release; do
    [ -f "$f" ] || continue
    grep -q '^BOARD_NAME="H96 Max V58"' "$f" && continue
    chattr -i "$f" 2>/dev/null || true
    sed -i 's/^BOARD_NAME=.*/BOARD_NAME="H96 Max V58"/' "$f" 2>/dev/null || true
done

# Armbian version and codename follow base-files (os-release) after an upgrade: issue, armbian-release, motd
osr=/etc/os-release
[ -e "$osr" ] || osr=/usr/lib/os-release
ver=$(sed -n 's/^ARMBIAN_PRETTY_NAME="\{0,1\}Armbian[^ ]* \([^ "]*\).*/\1/p' "$osr" 2>/dev/null | head -1)
[ -n "$ver" ] || ver=$(sed -n 's/^PRETTY_NAME="\{0,1\}Armbian[^ ]* \([^ "]*\).*/\1/p' "$osr" 2>/dev/null | head -1)
code=$(sed -n 's/^VERSION_CODENAME=//p' "$osr" 2>/dev/null | tr -d '"' | head -1)
printf '%s' "$ver" | grep -Eqx '[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?' || ver=""
printf '%s' "$code" | grep -Eqx '[a-z]+' || code=""
for f in /etc/h96-issue /etc/h96-issue.net; do
    [ -n "$ver" ] && [ -f "$f" ] || continue
    new=$(sed "s/^\(Armbian[^ ]*\) [^ ]* (H96 /\1 $ver (H96 /" "$f"; echo x)
    [ "$new" = "$(cat "$f"; echo x)" ] || printf '%s' "${new%x}" > "$f"
done
if [ -f /etc/armbian-release ]; then
    want=()
    [ -n "$ver" ] && ! grep -Eqx "VERSION=\"?$ver\"?" /etc/armbian-release && want+=(-e "s/^VERSION=.*/VERSION=\"$ver\"/")
    [ -n "$code" ] && grep -q '^DISTRIBUTION_CODENAME=' /etc/armbian-release \
        && ! grep -qx "DISTRIBUTION_CODENAME=$code" /etc/armbian-release \
        && want+=(-e "s/^DISTRIBUTION_CODENAME=.*/DISTRIBUTION_CODENAME=$code/")
    if [ "${#want[@]}" -gt 0 ]; then
        chattr -i /etc/armbian-release 2>/dev/null || true
        sed -i "${want[@]}" /etc/armbian-release
    fi
fi

for pair in "/etc/h96-issue /etc/issue" "/etc/h96-issue.net /etc/issue.net"; do
    set -- $pair
    src="$1"; dst="$2"
    [ -f "$src" ] || continue
    cmp -s "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
done

# os-release: base-files owns PRETTY_NAME/ID/VERSION (tools read them); H96 identity goes in VARIANT
rel=$(sed -n 's/^H96_RELEASE=//p' /etc/h96-release 2>/dev/null)
if [ -n "$rel" ] && [ -e /etc/os-release ]; then
    want_v="VARIANT=\"H96 Max V58 Unofficial Port $rel\""
    want_id='VARIANT_ID=h96-max-v58'
    if ! grep -qxF "$want_v" /etc/os-release || ! grep -qxF "$want_id" /etc/os-release; then
        sed -i --follow-symlinks -e '/^VARIANT=/d' -e '/^VARIANT_ID=/d' /etc/os-release
        printf '%s\n%s\n' "$want_v" "$want_id" >> "$(readlink -f /etc/os-release)"
    fi
fi
