#!/bin/bash
# Stub-root tests for h96-kernel-switch: try, confirm, revert, rollback, low space, power loss at every cut point.
# Boot result is decided from all three files U-Boot loads (Image, uInitrd, dtb/<fdtfile>); a mixed set fails.
# No root, no systemd, no host /boot; mkinitramfs and mkimage are stubs.
# shellcheck disable=SC2016,SC2034  # checks are eval strings
set -u
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
KS=${KS:-$HERE/../../packages/h96-kernel-switch/root/usr/sbin/h96-kernel-switch}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export H96KS_ROOT=$W/root
R=$H96KS_ROOT
OLDK=6.1.172-h96v58-7.1 NEWK=6.1.172-h96v58-8.0 DN=rockchip/rk3588-h96-max-v58-panthor.dtb
DB=$(basename $DN)
SK=$R/usr/lib/h96-kernel/$NEWK
STD=$R/var/lib/h96-kernel-switch
pass=0 fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1 ($2)"; fi; }

mkdir -p "$W/bin"
cat > "$W/bin/mkinitramfs" <<'EOF'
#!/bin/sh
# stub: mkinitramfs -o OUT KREL
[ -d "$H96KS_ROOT/usr/lib/modules/$3" ] || exit 1
echo "initrd for $3${SALT:-}" > "$2"
EOF
cat > "$W/bin/mkimage" <<'EOF'
#!/bin/sh
# stub: last two args are -d IN OUT
for a; do o=$p; p=$a; done
{ echo "uboot-header"; cat "$o"; } > "$p"
EOF
chmod +x "$W/bin/mkinitramfs" "$W/bin/mkimage"
export PATH="$W/bin:$PATH"

setup() {  # [dtbdir-link]
    rm -rf "$R"
    mkdir -p "$R/boot" "$SK/dtb/rockchip" "$R/usr/lib/modules/$NEWK" "$R/usr/lib/modules/$OLDK" "$R/etc" "$R/var/lib"
    if [ "${1:-}" = dtbdir-link ]; then
        mkdir -p "$R/boot/dtb-$OLDK/rockchip"; ln -s "dtb-$OLDK" "$R/boot/dtb"
    else
        mkdir -p "$R/boot/dtb/rockchip"
    fi
    echo old-image > "$R/boot/Image-$OLDK"
    echo old-initrd > "$R/boot/uInitrd-$OLDK"
    ln -s "Image-$OLDK" "$R/boot/Image"
    ln -s "uInitrd-$OLDK" "$R/boot/uInitrd"
    echo old-dtb > "$R/boot/dtb/$DN"
    printf 'verbosity=1\nfdtfile=%s\nrootdev=UUID=x\n' "$DN" > "$R/boot/armbianEnv.txt"
    echo 'load ${prefix}Image' > "$R/boot/boot.cmd"
    echo scr > "$R/boot/boot.scr"
    echo INITRD_ARCH=arm64 > "$R/etc/armbian-release"
    echo new-image > "$SK/Image"; echo map > "$SK/System.map"; echo cfg > "$SK/config"
    (cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel)
    echo new-dtb > "$SK/dtb/$DN"
    (cd "$SK/dtb" && sha256sum "$DN" > SHA256SUMS.dtb)
    echo dep > "$R/usr/lib/modules/$NEWK/modules.dep"
    PROT=$(cd "$R/boot" && sha256sum armbianEnv.txt boot.cmd boot.scr)
    KEEP=0
}
ks() { H96KS_UNAME=${U:-$OLDK} H96KS_BOOTID=${B:-b1} bash "$KS" "$@"; }
img() { readlink "$R/boot/Image"; }
ini() { readlink "$R/boot/uInitrd"; }
dtl() { readlink "$R/boot/dtb/$DN"; }
cur() { readlink "$R/boot/h96ks/cur"; }
phase() { sed -n 's/^PHASE=//p' "$STD/trial" 2>/dev/null; }
# what U-Boot boots: Image, uInitrd and DTB read through links; kernel name, or MIXED
boot_as() {
    local i n d
    i=$(cat "$R/boot/Image" 2>/dev/null); n=$(cat "$R/boot/uInitrd" 2>/dev/null); d=$(cat "$R/boot/dtb/$DN" 2>/dev/null)
    if [ "$i" = old-image ] && [ "$n" = old-initrd ] && [ "$d" = old-dtb ]; then echo "$OLDK"; return; fi
    if [ "$i" = new-image ] && [[ $n == "uboot-header"$'\n'"initrd for $NEWK"* ]] &&
        { [ "$d" = "$(cat "$SK/dtb/$DN")" ] || { [ "$KEEP" = 1 ] && [ "$d" = old-dtb ]; }; }; then echo "$NEWK"; return; fi
    echo MIXED
}
via_cur() { [ "$(img)" = h96ks/cur/Image ] && [ "$(ini)" = h96ks/cur/uInitrd ]; }
on_old() { [ "$(boot_as)" = "$OLDK" ]; }
on_new() { [ "$(boot_as)" = "$NEWK" ]; }
# boot.scr, boot.cmd, armbianEnv unchanged; no extlinux; no tmp files left
invariant() {
    [ "$(cd "$R/boot" && sha256sum armbianEnv.txt boot.cmd boot.scr)" = "$PROT" ] &&
        [ ! -e "$R/boot/extlinux" ] && [ ! -e "$R/boot/boot/extlinux" ] && [ ! -e "$R/extlinux" ] &&
        [ -z "$(find "$R/boot" -name '*.h96ks-tmp')" ]
}
blist() { (cd "$R/boot" && find . -printf '%y %p %l\n' | sort && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
# per-entry state: path, type, link target, content sha
entries() { (cd "$R/boot" && find . ! -type d | sort | while read -r f; do
    if [ -L "$f" ]; then echo "$f L $(readlink "$f")"; else echo "$f F $(sha256sum < "$f" | cut -c1-16)"; fi; done); }
changed() { diff <(echo "$1") <(entries) | sed -n 's/^> \([^ ]*\) .*/\1/p' | sort -u | tr "\n" " "; }
# boot until no trial record is left (at most 3 boots), each boot runs kernel that files name
settle() {  # first boot id number
    local n=$1 b
    while [ -e "$STD/trial" ] && [ "$n" -lt $(($1 + 3)) ]; do
        b=$(boot_as); [ "$b" != MIXED ] || return 1
        U=$b B=b$n ks guard 2>/dev/null; n=$((n + 1))
    done
}
cutpoints() {  # command...: cut points one run reaches
    rm -f "$W/cuts"; H96KS_CUTLOG=$W/cuts "$@" > /dev/null 2>&1; sort -u "$W/cuts" 2>/dev/null | tr '\n' ' '
}

echo "== 1 list and status"
setup
ok "list shows staged kernel" '[ "$(ks list)" = "$NEWK" ]'
ok "status shows no trial" 'ks status | grep -qx "trial: none"'
ok "default reads flat Image link" '[ "$(ks default)" = $OLDK ]'
ok "in-use: old kernel default, new kernel unused (rc 1)" '[ "$(ks in-use $OLDK)" = default ] && ! ks in-use $NEWK'

echo "== 2 refusals leave /boot unchanged"
setup; before=$(blist)
ok "unknown KREL refused" '! ks try 6.1.999 2>/dev/null'
ok "traversal KREL refused" '! ks try ../x 2>/dev/null'
echo bad > "$SK/config"
ok "sha mismatch refused" '! ks try $NEWK 2>/dev/null'
setup; rm "$R/usr/lib/modules/$NEWK/modules.dep"
ok "missing modules.dep refused" '! ks try $NEWK 2>/dev/null'
setup; mkdir "$R/boot/extlinux"
ok "existing extlinux refused" 'ks try $NEWK 2>&1 | grep -q "extlinux exists" && ! ks try $NEWK 2>/dev/null && [ ! -e $R/boot/h96ks ] && [ "$(img)" = Image-$OLDK ]'
rmdir "$R/boot/extlinux"
ok "running KREL refused" '! U=$NEWK ks try $NEWK 2>/dev/null'
setup; rm "$R/boot/Image"; cp "$R/boot/Image-$OLDK" "$R/boot/Image"
ok "plain Image file refused" '! ks try $NEWK 2>/dev/null'
setup; rm "$SK/dtb/$DN"
ok "missing staged DTB refused without --keep-dtb" '! ks try $NEWK 2>/dev/null'
setup; printf 'x\0Linux version 6.1.99-other (gcc) #1\0' > "$SK/Image"; (cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel)
ok "staged Image reporting other release refused" 'ks try $NEWK 2>&1 | grep -q "reports release 6.1.99-other"'
setup; printf 'x\0Linux version %s (gcc) #1\0' "$NEWK" > "$R/boot/Image-$OLDK"
ok "current Image reporting trial release refused" 'ks try $NEWK 2>&1 | grep -q "already reports release $NEWK"'
setup; printf 'x\0Linux version %s (gcc) #1\0' "$NEWK" > "$SK/Image"; (cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel)
ok "staged Image reporting own release accepted" 'ks try $NEWK > /dev/null && [ "$(phase)" = armed ]'
setup; before=$(blist)
ks try 6.1.999 2>/dev/null; ks try ../x 2>/dev/null
ok "refusals: /boot byte-identical, no trial record" '[ "$(blist)" = "$before" ] && [ ! -e $STD/trial ]'

echo "== 3 low space"
setup; before=$(blist)
out=$(H96KS_AVAIL_KB=1000 ks try $NEWK 2>&1); rc=$?
ok "low space refused" '[ $rc != 0 ] && echo "$out" | grep -q "KiB free, needs"'
ok "low space: /boot byte-identical, no trial" '[ "$(blist)" = "$before" ] && [ ! -e $STD/trial ] && invariant'
ok "low space: temp initramfs dir removed" '[ -z "$(ls -A $R/var/tmp 2>/dev/null)" ]'
out=$(H96KS_AVAIL_KB=16387 ks try $NEWK 2>&1); rc=$?
ok "free space 1 KiB short of files (4 KiB) plus reserve refused" '[ $rc != 0 ] && [ ! -e $STD/trial ] && [ "$(blist)" = "$before" ]'
out=$(H96KS_AVAIL_KB=16388 ks try $NEWK 2>&1); rc=$?
ok "free space equal to files plus reserve accepted" '[ $rc = 0 ] && [ "$(phase)" = armed ]'

echo "== 4 try, healthy trial boot, confirm"
setup; e0=$(entries)
ks try $NEWK > /dev/null; rc=$?
ok "try rc 0" '[ $rc = 0 ]'
ok "boot files resolve to new set; Image, uInitrd, DTB link through h96ks/cur" 'on_new && via_cur && [ "$(dtl)" = ../../h96ks/cur/fdt ] && [ "$(cur)" = $NEWK.g1 ]'
ok "generation equals staged files" 'cmp -s $R/boot/h96ks/$NEWK.g1/Image $SK/Image && cmp -s $R/boot/h96ks/$NEWK.g1/fdt $SK/dtb/$DN && grep -q "initrd for $NEWK" $R/boot/h96ks/$NEWK.g1/uInitrd'
ok "previous generation: hard links to previous files, DTB copy" '[ $(stat -c %i $R/boot/h96ks/$OLDK.g1/Image) = $(stat -c %i $R/boot/Image-$OLDK) ] && [ $(stat -c %i $R/boot/h96ks/$OLDK.g1/uInitrd) = $(stat -c %i $R/boot/uInitrd-$OLDK) ] && [ "$(cat $R/boot/h96ks/$OLDK.g1/fdt)" = old-dtb ]'
ok "phase armed" '[ "$(phase)" = armed ]'
ok "writes limited to boot links and h96ks" '[ "$(changed "$e0")" = "./Image ./dtb/rockchip/$DB ./h96ks/$OLDK.g1/Image ./h96ks/$OLDK.g1/fdt ./h96ks/$OLDK.g1/uInitrd ./h96ks/$NEWK.g1/Image ./h96ks/$NEWK.g1/fdt ./h96ks/$NEWK.g1/uInitrd ./h96ks/cur ./uInitrd " ]'
ok "previous flat files untouched" '[ "$(cat $R/boot/Image-$OLDK)" = old-image ] && [ "$(cat $R/boot/uInitrd-$OLDK)" = old-initrd ]'
ok "invariant after try" 'invariant'
ok "armed: default names trial kernel (next boot), in-use names trial and previous" '[ "$(ks default)" = $NEWK ] && [ "$(ks in-use $NEWK)" = "default trial" ] && [ "$(ks in-use $OLDK)" = trial-previous ]'
ok "second try refused while trial recorded" '! ks try $NEWK 2>/dev/null'
B=b1 ks guard
ok "guard in arming boot: no action" 'on_new && [ "$(phase)" = armed ]'
U=$NEWK B=b2 ks guard; rc=$?
ok "trial boot: guard rc 0, h96ks/cur back on previous at once" '[ $rc = 0 ] && on_old && [ "$(phase)" = trial ] && [ "$(ks default)" = $OLDK ]'
U=$NEWK B=b2 ks guard
ok "guard rerun in same boot keeps fallback" 'on_old && [ "$(phase)" = trial ]'
ok "confirm from foreign boot refused" '! U=$NEWK B=b9 ks confirm 2>/dev/null && on_old'
ok "confirm on wrong kernel refused" '! U=$OLDK B=b2 ks confirm 2>/dev/null && on_old'
U=$NEWK B=b2 ks confirm > /dev/null
ok "confirm: new set, trial cleared, last recorded" 'on_new && [ ! -e $STD/trial ] && grep -q "^NEW=$NEWK.g1" $STD/last && grep -q "^PREV=$OLDK.g1" $STD/last'
ok "result line confirmed" 'grep -q "confirmed-manual $NEWK" $STD/result'
ok "in-use after confirm: new default, old rollback target" '[ "$(ks in-use $NEWK)" = default ] && [ "$(ks in-use $OLDK)" = rollback-target ]'
U=$NEWK B=b3 ks guard
ok "next boot after confirm: no action" 'on_new && invariant'
ok "list flags" 'U=$NEWK ks list | grep -qx "$NEWK \[running default in-boot\]"'

echo "== 5 trial boot not confirmed, reboot or hang lands on previous"
setup; ks try $NEWK > /dev/null
U=$NEWK B=b2 ks guard
ok "hang during trial boot: files already on previous set" 'on_old'
U=$(boot_as) B=b3 ks guard; rc=$?
ok "next boot runs previous kernel, guard rc 0" '[ $rc = 0 ] && on_old'
ok "guard records revert and clears trial" 'grep -q "reverted $NEWK: boot b2 not confirmed" $STD/result && [ ! -e $STD/trial ] && invariant'
SALT=-2 ks try $NEWK > /dev/null
ok "retry after revert with rebuilt initramfs arms new generation, drops unused earlier one" '[ "$(phase)" = armed ] && on_new && [ "$(cur)" = $NEWK.g2 ] && [ ! -e $R/boot/h96ks/$NEWK.g1 ] && [ -d $R/boot/h96ks/$OLDK.g1 ]'
setup; ks try $NEWK > /dev/null; ks rollback > /dev/null
cp "$R/boot/h96ks/$NEWK.g1/uInitrd" "$W/ini.keep"
ok "identical generation of earlier attempt reused" 'ks try $NEWK > /dev/null && [ "$(cur)" = $NEWK.g1 ] && [ ! -e $R/boot/h96ks/$NEWK.g2 ] && cmp -s $W/ini.keep $R/boot/h96ks/$NEWK.g1/uInitrd'

echo "== 6 armed but other kernel booted"
setup; ks try $NEWK > /dev/null
U=$OLDK B=b2 ks guard; rc=$?
ok "not-booted: guard rc 0, previous set, trial cleared" '[ $rc = 0 ] && on_old && [ ! -e $STD/trial ] && grep -q "not-booted $NEWK" $STD/result'

echo "== 7 auto-confirm"
setup; ks try $NEWK > /dev/null
U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks auto-confirm
ok "auto-confirm not chosen: no confirm" 'on_old && [ "$(phase)" = trial ]'
setup; ks try $NEWK --auto-confirm > /dev/null
U=$NEWK B=b2 ks guard; rc=$?
ok "auto trial boot: guard rc 0" '[ $rc = 0 ] && on_old'
U=$NEWK B=b2 H96KS_HEALTHY=0 ks auto-confirm
ok "auto-confirm, unhealthy: no confirm" 'on_old && [ "$(phase)" = trial ]'
U=$NEWK B=b2 H96KS_HEALTHY=1 ks auto-confirm > /dev/null
ok "auto-confirm, healthy: confirmed" 'on_new && [ ! -e $STD/trial ] && grep -q "confirmed-auto $NEWK" $STD/result'
ok "auto-confirm with nothing recorded: rc 0, no change" 'U=$NEWK B=b3 ks auto-confirm && on_new'

echo "== 8 rollback"
setup; ks try $NEWK > /dev/null
ks rollback > /dev/null
ok "rollback before reboot cancels trial" 'on_old && [ ! -e $STD/trial ] && grep -q "cancelled $NEWK" $STD/result'
ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard
U=$NEWK B=b2 ks rollback > /dev/null
ok "rollback during trial boot clears trial, previous set" 'on_old && [ ! -e $STD/trial ]'
ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
U=$NEWK B=b3 ks rollback > /dev/null
ok "rollback after confirm: previous set incl. previous DTB" 'on_old && invariant && grep -q "rollback $OLDK" $STD/result'
U=$OLDK B=b4 ks rollback > /dev/null
ok "rollback again returns to confirmed set" 'on_new'
ln -sfn "$OLDK.g1" "$R/boot/h96ks/cur"
ok "rollback refused when h96ks/cur differs from last set" '! ks rollback 2>/dev/null'
setup
ok "rollback with nothing recorded refused" '! ks rollback 2>/dev/null'

echo "== 9 keep-dtb, identical DTB, DTB directory link"
setup; KEEP=1; ks try $NEWK --keep-dtb > /dev/null
ok "--keep-dtb: DTB stays plain file, generation holds current DTB" '[ ! -L $R/boot/dtb/$DN ] && [ "$(cat $R/boot/dtb/$DN)" = old-dtb ] && [ "$(cat $R/boot/h96ks/$NEWK.g1/fdt)" = old-dtb ] && on_new'
U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
ok "--keep-dtb confirm: kernel links only" 'on_new && [ ! -L $R/boot/dtb/$DN ]'
KEEP=0
ok "later try with differing DTB after --keep-dtb: DTB link added, previous generation DTB matches" 'U=$NEWK ks rollback >/dev/null; [ "$(cur)" = $OLDK.g1 ] && rm -f $STD/last && U=$OLDK ks try $NEWK > /dev/null && on_new && [ "$(dtl)" = ../../h96ks/cur/fdt ] && [ "$(cat $R/boot/h96ks/$(sed -n "s/^PREV=//p" $STD/trial)/fdt)" = old-dtb ]'
setup; echo old-dtb > "$SK/dtb/$DN"
(cd "$SK/dtb" && sha256sum "$DN" > SHA256SUMS.dtb)
ks try $NEWK > /dev/null
ok "identical DTB: no DTB write" '[ ! -L $R/boot/dtb/$DN ] && on_new && [ "$(ls $R/boot/dtb/rockchip)" = $DB ]'
setup; KEEP=1; ks try $NEWK --keep-dtb > /dev/null; ks rollback > /dev/null; KEEP=0
echo old-dtb-x > "$R/boot/dtb/$DN"
ks try $NEWK > /dev/null; ks rollback > /dev/null
ok "plain DTB changed outside tool: layout generation copies current DTB before DTB becomes link" '[ "$(dtl)" = ../../h96ks/cur/fdt ] && [ "$(cat $R/boot/dtb/$DN)" = old-dtb-x ] && [ "$(cat $R/boot/Image)" = old-image ]'
setup dtbdir-link
ks try $NEWK > /dev/null
ok "dtb as directory link: DTB link relative to physical directory, resolves to new DTB" '[ "$(dtl)" = ../../h96ks/cur/fdt ] && on_new && invariant'
U=$NEWK B=b2 ks guard
ok "dtb as directory link: fallback resolves to old DTB" 'on_old'

echo "== 10 prune"
setup; ks try $NEWK > /dev/null
ok "prune of trial kernel refused" '! ks prune $NEWK 2>/dev/null'
ok "prune of previous kernel refused" '! ks prune $OLDK 2>/dev/null'
U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
ok "prune of last-confirm previous refused" '! U=$NEWK ks prune $OLDK 2>/dev/null'
setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$OLDK B=b3 ks guard
ok "prune of reverted kernel removes its generation only" 'ks prune $NEWK > /dev/null && [ ! -e $R/boot/h96ks/$NEWK.g1 ] && on_old && invariant && [ -d $R/boot/h96ks/$OLDK.g1 ]'
setup; ks prune $NEWK > /dev/null 2>&1
ok "prune with nothing to remove leaves /boot as is" 'on_old && [ ! -e $R/boot/h96ks ]'

echo "== 11 unreadable record and leftovers"
setup; ks try $NEWK > /dev/null
echo 'PHASE=armed; rm -rf /' > "$STD/trial"
U=$NEWK B=b2 ks guard
ok "unreadable trial moved aside, links left as found" 'on_new && ls $STD/ | grep -q "^trial.bad-" && [ ! -e $STD/trial ]'

echo "== 12 power loss at every cut point of try: boot after cut never mixed, guard settles on previous"
setup; cps=$(cutpoints ks try $NEWK)
ok "try reaches layout, copy and switch cut points" '[ "$cps" = "conv-cur conv-dtb conv-gen conv-img conv-ini copy-0 copy-1 switch-0 switch-1 " ]'
for cp in $cps; do
    setup
    H96KS_DIE_AT=$cp ks try $NEWK > /dev/null 2>&1; rc=$?
    first=$(boot_as)
    if [ "$cp" = switch-0 ]; then ok "cut at switch-0: armed record written before h96ks/cur moves" '[ "$(phase)" = armed ]'; fi
    settle 2; src=$?
    ok "cut at $cp: rc 99, first boot $first not mixed, settles on previous set, no record, no tmp" '[ $rc = 99 ] && [ "$first" != MIXED ] && [ $src = 0 ] && on_old && [ ! -e $STD/trial ] && invariant'
    ks try $NEWK > /dev/null 2>&1
    ok "cut at $cp: retry arms trial" '[ "$(phase)" = armed ] && on_new && via_cur'
done
setup; KEEP=1; cps=$(cutpoints ks try $NEWK --keep-dtb)
for cp in $cps; do
    setup; KEEP=1
    H96KS_DIE_AT=$cp ks try $NEWK --keep-dtb > /dev/null 2>&1; rc=$?
    first=$(boot_as); settle 2; src=$?
    ok "keep-dtb cut at $cp: first boot $first not mixed, settles on previous" '[ $rc = 99 ] && [ "$first" != MIXED ] && [ $src = 0 ] && on_old && [ ! -e $STD/trial ] && invariant'
done
KEEP=0

echo "== 13 power loss in guard, confirm and rollback"
setup; ks try $NEWK > /dev/null
cps=$(U=$NEWK B=b2 cutpoints ks guard)
ok "guard trial boot reaches guard-0" '[ "$cps" = "guard-0 " ]'
setup; ks try $NEWK > /dev/null
U=$NEWK B=b2 H96KS_DIE_AT=guard-0 ks guard 2>/dev/null
ok "cut after trial record, before fallback: next boot is trial kernel again, not mixed" '[ "$(boot_as)" = $NEWK ]'
U=$NEWK B=b3 ks guard
ok "guard then reverts (unconfirmed boot b2)" 'on_old && grep -q "reverted $NEWK: boot b2" $STD/result'
setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard
cps=$(U=$NEWK B=b2 cutpoints ks confirm)
ok "confirm reaches confirm-0 commit-1 commit-2" '[ "$cps" = "commit-1 commit-2 confirm-0 " ]'
for cp in $cps; do
    setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard
    U=$NEWK B=b2 H96KS_DIE_AT=$cp ks confirm > /dev/null 2>&1
    first=$(boot_as); settle 3; src=$?
    ok "cut in confirm at $cp: first boot $first not mixed; confirm completed by guard, new set default" '[ "$first" != MIXED ] && [ $src = 0 ] && on_new && [ ! -e $STD/trial ] && grep -q "^NEW=$NEWK.g1" $STD/last && invariant'
done
setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
cps=$(U=$NEWK B=b3 cutpoints ks rollback)
ok "rollback reaches rollback-0 commit-1 commit-2" '[ "$cps" = "commit-1 commit-2 rollback-0 " ]'
for cp in $cps; do
    setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
    U=$NEWK B=b3 H96KS_DIE_AT=$cp ks rollback > /dev/null 2>&1
    first=$(boot_as); settle 4; src=$?
    ok "cut in rollback at $cp: first boot $first not mixed; rollback completed, previous set, last swapped" '[ "$first" != MIXED ] && [ $src = 0 ] && on_old && [ ! -e $STD/trial ] && grep -q "^NEW=$OLDK.g1" $STD/last && invariant'
done
setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard
U=$NEWK B=b2 H96KS_DIE_AT=confirm-0 ks confirm > /dev/null 2>&1
ok "unfinished commit: rollback refused, guard finishes it" '! ks rollback 2>/dev/null && ks guard && on_new && [ ! -e $STD/trial ]'

echo "kernel-switch stub tests: $pass pass, $fail fail"
[ "$fail" = 0 ]
