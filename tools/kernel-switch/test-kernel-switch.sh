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
cat > "$W/bin/depmod" <<'EOF'
#!/bin/sh
# stub: depmod -a -b ROOT -F MAP KREL
echo "depmod $(cat "$3/usr/lib/modules/$6/modules.order" 2>/dev/null)" > "$3/usr/lib/modules/$6/modules.dep"
EOF
chmod +x "$W/bin/depmod"
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
ok "running KREL with staged Image and DTB equal to in-boot files refused" 'cp $R/boot/Image-$OLDK $SK/Image && cp $R/boot/dtb/$DN $SK/dtb/$DN && (cd $SK && sha256sum Image System.map config > SHA256SUMS.kernel) && (cd $SK/dtb && sha256sum $DN > SHA256SUMS.dtb) && U=$NEWK ks try $NEWK 2>&1 | grep -q "is running; staged Image and DTB equal in-boot generation"'
setup
ok "running KREL with differing staged Image accepted (r13: same release, new content)" 'U=$NEWK ks try $NEWK > /dev/null && [ "$(phase)" = armed ]'
setup; rm "$R/boot/Image"; cp "$R/boot/Image-$OLDK" "$R/boot/Image"
ok "plain Image file refused" '! ks try $NEWK 2>/dev/null'
setup; rm "$SK/dtb/$DN"
ok "missing staged DTB refused without --keep-dtb" '! ks try $NEWK 2>/dev/null'
setup; printf 'x\0Linux version 6.1.99-other (gcc) #1\0' > "$SK/Image"; (cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel)
ok "staged Image reporting other release refused" 'ks try $NEWK 2>&1 | grep -q "reports release 6.1.99-other"'
setup; printf 'x\0Linux version %s (gcc) #1\0' "$NEWK" > "$R/boot/Image-$OLDK"
ok "current Image reporting trial release, staged content differs, no saved module tree of in-boot build: refused (r14)" 'ks try $NEWK 2>&1 | grep -q "no saved module tree of in-boot build" && [ ! -e $STD/trial ] && [ "$(img)" = Image-$OLDK ]'
setup; printf 'x\0Linux version %s (gcc) #1\0' "$NEWK" > "$R/boot/Image-$OLDK"; cp "$R/boot/Image-$OLDK" "$SK/Image"; cp "$R/boot/dtb/$DN" "$SK/dtb/$DN"
(cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel); (cd "$SK/dtb" && sha256sum "$DN" > SHA256SUMS.dtb)
ok "current Image reporting trial release, staged content equal: refused" 'ks try $NEWK 2>&1 | grep -q "already reports release $NEWK; staged Image and DTB equal"'
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
ok "try reaches layout, copy, module snapshot and switch cut points" '[ "$cps" = "conv-cur conv-dtb conv-gen conv-img conv-ini copy-0 copy-1 snap-0 snap-1 switch-0 switch-1 " ]'
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

echo "== 14 dtb, dtb-plain, h96-undervolt files"
UVF=$R/var/lib/h96-undervolt-trial UVS=$R/var/lib/h96-undervolt-state
dtbkey() { ks dtb | sed -n "s/^$1=//p"; }
setup
ok "dtb: plain layout, no trial" '[ "$(dtbkey layout)" = plain ] && [ "$(dtbkey trial)" = none ] && [ "$(dtbkey path)" = $R/boot/dtb/$DN ] && [ "$(dtbkey file)" = $R/boot/dtb/$DN ]'
before=$(blist); echo armed > "$UVF"
ok "try refused while undervolt trial recorded, /boot byte-identical" 'ks try $NEWK 2>&1 | grep -q "h96-undervolt trial recorded" && [ "$(blist)" = "$before" ] && [ ! -e $STD/trial ]'
ok "try --keep-dtb refused while undervolt trial recorded" '! ks try $NEWK --keep-dtb 2>/dev/null && [ "$(blist)" = "$before" ]'
rm -f "$UVF"; echo "-10 mV" > "$UVS"
ok "try with differing DTB refused while undervolt change active, /boot byte-identical" 'ks try $NEWK 2>&1 | grep -q "h96-undervolt change active" && [ "$(blist)" = "$before" ] && [ ! -e $STD/trial ]'
KEEP=1
ok "try --keep-dtb accepted while undervolt change active: DTB stays plain" 'ks try $NEWK --keep-dtb > /dev/null && on_new && [ ! -L $R/boot/dtb/$DN ] && [ "$(dtbkey trial)" = armed ]'
KEEP=0
setup; echo old-dtb > "$SK/dtb/$DN"; (cd "$SK/dtb" && sha256sum "$DN" > SHA256SUMS.dtb); echo "-10 mV" > "$UVS"
ok "try with identical DTB accepted while undervolt change active" 'ks try $NEWK > /dev/null && on_new && [ ! -L $R/boot/dtb/$DN ]'
setup; ks try $NEWK > /dev/null
ok "dtb: managed layout, file in trial generation, trial armed" '[ "$(dtbkey layout)" = managed ] && [ "$(dtbkey file)" = $R/boot/h96ks/$NEWK.g1/fdt ] && [ "$(dtbkey trial)" = armed ]'
ok "dtb-plain refused while trial recorded" 'ks dtb-plain 2>&1 | grep -q "trial recorded" && [ "$(dtl)" = ../../h96ks/cur/fdt ]'
U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
g0=$(cd "$R/boot/h96ks" && find . -type f -print0 | sort -z | xargs -0 sha256sum); e0=$(entries)
U=$NEWK ks dtb-plain > /dev/null; rc=$?
ok "dtb-plain: rc 0, DTB plain file with trial generation content, new set boots" '[ $rc = 0 ] && [ ! -L $R/boot/dtb/$DN ] && [ "$(dtbkey layout)" = plain ] && on_new && invariant'
ok "dtb-plain: only DTB name written, generations unchanged" '[ "$(changed "$e0")" = "./dtb/rockchip/$DB " ] && [ "$(cd $R/boot/h96ks && find . -type f -print0 | sort -z | xargs -0 sha256sum)" = "$g0" ]'
ok "dtb-plain on plain DTB refused" 'U=$NEWK ks dtb-plain 2>&1 | grep -q "nothing to do"'
e0=$(entries)
ok "rollback refused while plain DTB differs from previous generation, /boot unchanged" 'U=$NEWK B=b3 ks rollback 2>&1 | grep -q "differs from DTB of $OLDK.g1" && [ -z "$(changed "$e0")" ]'
U=$NEWK B=b3 ks rollback --keep-dtb > /dev/null; rc=$?
ok "rollback --keep-dtb: previous Image and uInitrd, current DTB kept" '[ $rc = 0 ] && [ "$(cat $R/boot/Image)" = old-image ] && [ "$(cat $R/boot/uInitrd)" = old-initrd ] && [ "$(cat $R/boot/dtb/$DN)" = new-dtb ] && [ ! -L $R/boot/dtb/$DN ] && invariant'
ok "rollback with unknown option refused" '! ks rollback --x 2>/dev/null'
setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
cps=$(U=$NEWK cutpoints ks dtb-plain)
ok "dtb-plain reaches plain-0 plain-1" '[ "$cps" = "plain-0 plain-1 " ]'
for cp in $cps; do
    setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
    U=$NEWK H96KS_DIE_AT=$cp ks dtb-plain > /dev/null 2>&1; rc=$?
    first=$(boot_as)
    U=$NEWK ks dtb-plain > /dev/null 2>&1
    ok "cut in dtb-plain at $cp: rc 99, boot $first is new set, rerun leaves plain DTB, no tmp" '[ $rc = 99 ] && [ "$first" = $NEWK ] && [ ! -L $R/boot/dtb/$DN ] && on_new && invariant'
done


echo "== 15 same release, new content (r13): try makes new generation"
B1="Linux version $NEWK (b@h) (gcc 16.1) #1 SMP PREEMPT Tue Oct 20 2026"
B2="Linux version $NEWK (b@h) (gcc 16.1) #2 SMP PREEMPT Thu Oct 22 2026"
stage() {  # banner dtb-text
    printf 'img\0%s\n\0' "$1" > "$SK/Image"; (cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel)
    echo "$2" > "$SK/dtb/$DN"; (cd "$SK/dtb" && sha256sum "$DN" > SHA256SUMS.dtb)
}
kss() { H96KS_UNAME=${U:-$NEWK} H96KS_BOOTID=${B:-b1} H96KS_PROCVER=${PV:-$B1} bash "$KS" "$@"; }
# confirmed default NEWK.g1 (banner B1), running it
same_base() {
    setup; stage "$B1" dtb-1
    ks try $NEWK > /dev/null; U=$NEWK B=b2 PV=$B1 kss guard; U=$NEWK B=b2 PV=$B1 kss confirm > /dev/null
    rm -f "$STD/last"   # earlier confirm forgotten: only same-release history below
    stage "$B2" dtb-2
}
bimg() { kbn "$R/boot/Image"; }
kbn() { grep -a -o -m1 'Linux version [^[:cntrl:]]*' "$1" | head -n1; }
same_base; before=$(blist)
stage "$B1" dtb-1
ok "same release, staged Image and DTB equal in-boot generation: refused, /boot byte-identical" 'B=b3 kss try $NEWK 2>&1 | grep -q "already default.*equal in-boot generation" && [ "$(blist)" = "$before" ] && [ ! -e $STD/trial ]'
stage "$B1" dtb-2
ok "same release, only DTB differs: accepted" 'B=b3 kss try $NEWK > /dev/null && [ "$(phase)" = armed ] && [ "$(cur)" = $NEWK.g2 ]'
same_base
out=$(B=b3 kss try $NEWK 2>&1); rc=$?
ok "same release, Image differs: rc 0, message, new generation g2, previous g1" '[ $rc = 0 ] && echo "$out" | grep -q "same release, new content" && [ "$(cur)" = $NEWK.g2 ] && grep -qx "PREV=$NEWK.g1" $STD/trial && grep -qx "NEW=$NEWK.g2" $STD/trial && [ "$(bimg)" = "$B2" ]'
ok "list: both generations with roles" 'B=b3 kss list > $W/l; grep -qx "  $NEWK.g1 \[trial-previous running\]" $W/l && grep -qx "  $NEWK.g2 \[default trial\]" $W/l'
ok "status: generation lines" 'B=b3 kss status | grep -qx "generation: $NEWK.g2 \[default trial\]"'
ok "in-use per generation" '[ "$(kss in-use $NEWK.g1)" = trial-previous ] && [ "$(kss in-use $NEWK.g2)" = "default trial" ]'
ok "prune of either generation refused during trial" '! B=b3 kss prune $NEWK.g1 2>/dev/null && ! B=b3 kss prune $NEWK.g2 2>/dev/null && ! B=b3 kss prune $NEWK 2>/dev/null'
B=b3 PV=$B1 kss guard
ok "guard in arming boot: no action" '[ "$(phase)" = armed ] && [ "$(cur)" = $NEWK.g2 ]'
U=$NEWK B=b4 PV=$B2 kss guard
ok "trial boot (banner of g2 running): falls back to g1 at once, phase trial" '[ "$(phase)" = trial ] && [ "$(cur)" = $NEWK.g1 ] && [ "$(bimg)" = "$B1" ]'
ok "confirm refused when banner shows g1 running" '! U=$NEWK B=b4 PV=$B1 kss confirm 2>/dev/null'
U=$NEWK B=b4 PV=$B2 kss confirm > /dev/null
ok "confirm: g2 default, last PREV g1" '[ "$(cur)" = $NEWK.g2 ] && [ ! -e $STD/trial ] && grep -qx "PREV=$NEWK.g1" $STD/last && grep -qx "NEW=$NEWK.g2" $STD/last && [ "$(kss in-use $NEWK.g1)" = rollback-target ]'
ok "list after confirm: g2 default running, g1 rollback-target" 'B=b5 PV=$B2 kss list > $W/l; grep -qx "  $NEWK.g2 \[default running\]" $W/l && grep -qx "  $NEWK.g1 \[rollback-target\]" $W/l'
ok "prune of rollback target g1 refused" '! B=b5 PV=$B2 kss prune $NEWK.g1 2>/dev/null'
U=$NEWK B=b5 PV=$B2 kss rollback > /dev/null
ok "rollback after confirmed same-release trial: back to g1" '[ "$(cur)" = $NEWK.g1 ] && [ "$(bimg)" = "$B1" ] && grep -qx "NEW=$NEWK.g1" $STD/last && [ "$(cat $R/boot/dtb/$DN)" = dtb-1 ]'
U=$NEWK B=b6 PV=$B1 kss rollback > /dev/null
ok "rollback again: back to g2" '[ "$(cur)" = $NEWK.g2 ] && [ "$(bimg)" = "$B2" ]'
rm -f "$STD/last"
ok "prune of old generation g1 once nothing names it" 'B=b7 PV=$B2 kss prune $NEWK.g1 > /dev/null && [ ! -e $R/boot/h96ks/$NEWK.g1 ] && [ -d $R/boot/h96ks/$NEWK.g2 ] && invariant'
ok "prune of unknown generation refused" 'B=b7 PV=$B2 kss prune $NEWK.g9 2>&1 | grep -q "no generation $NEWK.g9"'
same_base; B=b3 kss try $NEWK > /dev/null
U=$NEWK B=b4 PV=$B1 kss guard
ok "armed, but g1 booted (banner g1): not-booted, back on g1, trial cleared" '[ ! -e $STD/trial ] && [ "$(cur)" = $NEWK.g1 ] && grep -q "not-booted $NEWK" $STD/result'
same_base; B=b3 kss try $NEWK > /dev/null
U=$NEWK B=b4 PV=$B2 kss guard; U=$NEWK B=b5 PV=$B1 kss guard
ok "trial boot not confirmed: next boot on g1, reverted" '[ "$(cur)" = $NEWK.g1 ] && [ ! -e $STD/trial ] && grep -q "reverted $NEWK: boot b4" $STD/result'
# identical banners: boot id and h96ks/cur decide
setup; stage "$B1" dtb-1; ks try $NEWK > /dev/null; U=$NEWK B=b2 PV=$B1 kss guard; U=$NEWK B=b2 PV=$B1 kss confirm > /dev/null
stage "$B1" dtb-3; printf 'extra' >> "$SK/Image"; (cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel)
B=b3 kss try $NEWK > /dev/null; U=$NEWK B=b4 PV=$B1 kss guard
ok "same banner in both generations: next boot after arming counts as trial boot" '[ "$(phase)" = trial ] && [ "$(cur)" = $NEWK.g1 ]'
U=$NEWK B=b4 PV=$B1 kss confirm > /dev/null
ok "same banner: confirm in trial boot keeps g2" '[ "$(cur)" = $NEWK.g2 ] && [ ! -e $STD/trial ]'
# /boot space
same_base; before=$(blist)
out=$(H96KS_AVAIL_KB=1000 B=b3 kss try $NEWK 2>&1); rc=$?
ok "same release, low /boot space: refused, /boot byte-identical" '[ $rc != 0 ] && echo "$out" | grep -q "KiB free, needs" && [ "$(blist)" = "$before" ] && [ ! -e $STD/trial ]'
# power loss during same-release try and confirm
same_base; cps=$(B=b3 H96KS_PROCVER=$B1 H96KS_UNAME=$NEWK H96KS_BOOTID=b3 cutpoints bash "$KS" try $NEWK)
ok "same-release try reaches copy, module snapshot and switch cut points" 'echo "$cps" | grep -q "copy-0 copy-1 snap-0 snap-1 switch-0 switch-1"'
for cp in $cps; do
    same_base
    H96KS_DIE_AT=$cp B=b3 kss try $NEWK > /dev/null 2>&1; rc=$?
    # boots until settled: each boot runs generation h96ks/cur names
    n=4; while [ -e "$STD/trial" ] && [ $n -lt 8 ]; do
        pv=$(bimg); U=$NEWK B=b$n PV=$pv kss guard 2>/dev/null; n=$((n + 1)); done
    ok "same-release cut at $cp: rc 99, settles on g1 (B1), no record, no tmp" '[ $rc = 99 ] && [ "$(bimg)" = "$B1" ] && [ ! -e $STD/trial ] && invariant'
done
for cp in confirm-0 commit-1 commit-2; do
    same_base; B=b3 kss try $NEWK > /dev/null; U=$NEWK B=b4 PV=$B2 kss guard
    U=$NEWK B=b4 PV=$B2 H96KS_DIE_AT=$cp kss confirm > /dev/null 2>&1
    n=5; while [ -e "$STD/trial" ] && [ $n -lt 9 ]; do pv=$(bimg); U=$NEWK B=b$n PV=$pv kss guard 2>/dev/null; n=$((n + 1)); done
    ok "same-release cut in confirm at $cp: guard completes confirm, g2 default" '[ "$(cur)" = $NEWK.g2 ] && [ "$(bimg)" = "$B2" ] && [ ! -e $STD/trial ] && grep -qx "NEW=$NEWK.g2" $STD/last && invariant'
done

echo "== 16 module trees per kernel build (r14): same-release revert runs with own modules"
NOTE='\x04\x00\x00\x00\x14\x00\x00\x00\x03\x00\x00\x00GNU\x00'
IDA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa IDB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
hexb() { echo "$1" | sed 's/../\\x&/g'; }
notes() { printf "$NOTE$(hexb "$1")" > "$W/notes-$1"; }   # running kernel notes of build ID
notes $IDA; notes $IDB
# package version of NEWK: Image with banner and build id, module tree content
pkg() {  # id banner tree-text
    printf "img\0%s\n\0$NOTE$(hexb "$1")pad" "$2" > "$SK/Image"; (cd "$SK" && sha256sum Image System.map config > SHA256SUMS.kernel)
    rm -f "$R/usr/lib/modules/$NEWK/modules.dep"; echo "$3" > "$R/usr/lib/modules/$NEWK/modules.dep"
}
km() { H96KS_UNAME=$NEWK H96KS_BOOTID=${B:-b1} H96KS_PROCVER=${PV:-$B1} H96KS_NOTES=$W/notes-${ID:-$IDA} bash "$KS" "$@"; }
mnt() { cat "$STD/test-mount" 2>/dev/null; }
mdep() { cat "$R$(mnt)/modules.dep"; }
nsnap() { find "$SD" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l; }
SD=$STD/modules/$NEWK
# confirmed g1 = build A (tree dep-A), then package upgrade to build B (tree dep-B)
mod_base() {
    setup; stage "$B1" dtb-1; pkg $IDA "$B1" dep-A
    ks try $NEWK > /dev/null; B=b2 ID=$IDA km guard; B=b2 ID=$IDA km confirm > /dev/null; rm -f "$STD/last"
    pkg $IDB "$B2" dep-B; echo dtb-2 > "$SK/dtb/$DN"; (cd "$SK/dtb" && sha256sum "$DN" > SHA256SUMS.dtb)
}
mod_base
ok "first try saved package tree of build A (meta with build id, tree content dep-A)" '[ "$(nsnap)" = 1 ] && grep -q "IDS=.*$IDA" $SD/*/meta && [ "$(cat $SD/*/tree/modules.dep)" = dep-A ]'
ok "status: g1 modules saved (package now build B), WARN: running A differs from package tree" 'B=b3 ID=$IDA km status > $W/s; grep -qx "  modules: saved" $W/s && grep -q "^WARN: running kernel build differs" $W/s'
ok "list prints WARN line on mismatch" 'B=b3 ID=$IDA km list | grep -q "^WARN: running kernel build differs"'
st0=$(cd "$STD" && find . | sort)
B=b3 ID=$IDA km modules-mount > "$W/mm" 2>&1
ok "modules-mount (running A, package B): saved tree A mounted, content dep-A" '[ "$(mdep)" = dep-A ] && grep -q "mounted read-only" $W/mm'
ok "modules-mount writes nothing in state dir apart from test mount record" '[ "$(cd $STD && find . | grep -v test-mount | sort)" = "$st0" ]'
ok "status after mount: saved tree mounted, no WARN" 'B=b3 ID=$IDA km status > $W/s; grep -q "^modules: saved tree .* mounted" $W/s && ! grep -q ^WARN $W/s'
ok "snapshot-modules skips package tree while saved tree is mounted" 'B=b3 ID=$IDA km snapshot-modules --quiet 2>/dev/null; [ "$(nsnap)" = 1 ]'
rm -f "$STD/test-mount"
out=$(B=b3 ID=$IDA km try $NEWK 2>&1); rc=$?
ok "same-release try with saved tree of in-boot build: accepted, package tree B saved too" '[ $rc = 0 ] && [ "$(phase)" = armed ] && [ "$(nsnap)" = 2 ] && grep -l "IDS=.*$IDB" $SD/*/meta > /dev/null'
B=b4 ID=$IDB PV=$B2 km guard
B=b4 ID=$IDB PV=$B2 km modules-mount > "$W/mm" 2>&1
ok "trial boot (build B running): package tree matches, nothing mounted" '[ -z "$(mnt)" ] && grep -q "package tree of $NEWK matches" $W/mm'
B=b5 ID=$IDA PV=$B1 km guard
B=b5 ID=$IDA PV=$B1 km modules-mount > /dev/null 2>&1
ok "trial not confirmed, revert boot (build A): saved tree A mounted (dep-A)" '[ ! -e $STD/trial ] && [ "$(cur)" = $NEWK.g1 ] && [ "$(mdep)" = dep-A ]'
rm -f "$STD/test-mount"
# confirm keeps saved tree of rollback target; rollback boots A with its tree; prune drops it
mod_base; B=b3 ID=$IDA km try $NEWK > /dev/null; B=b4 ID=$IDB PV=$B2 km guard; B=b4 ID=$IDB PV=$B2 km confirm > /dev/null
ok "confirm: saved trees of g1 (rollback target) and g2 kept" '[ "$(nsnap)" = 2 ] && B=b4 ID=$IDB PV=$B2 km status | grep -A1 "generation: $NEWK.g1" | grep -qx "  modules: saved"'
B=b5 ID=$IDB PV=$B2 km rollback > /dev/null
B=b6 ID=$IDA PV=$B1 km modules-mount > /dev/null 2>&1
ok "rollback to g1, boot of build A: saved tree A mounted" '[ "$(cur)" = $NEWK.g1 ] && [ "$(mdep)" = dep-A ]'
rm -f "$STD/test-mount"
B=b6 ID=$IDA PV=$B1 km rollback > /dev/null; rm -f "$STD/last"
B=b7 ID=$IDB PV=$B2 km prune $NEWK.g1 > /dev/null
ok "prune of g1: saved tree of build A removed, tree of B (staged) kept" '[ "$(nsnap)" = 1 ] && grep -q "IDS=.*$IDB" $SD/*/meta && [ ! -e $R/boot/h96ks/$NEWK.g1 ]'
# no saved tree: refusal, apt cache deb, repair
mod_base; rm -rf "$STD/modules"; before=$(blist)
out=$(B=b3 ID=$IDA km try $NEWK 2>&1); rc=$?
ok "same-release try without saved tree of in-boot build: refused, /boot byte-identical, no record" '[ $rc != 0 ] && echo "$out" | grep -q "no saved module tree of in-boot build" && [ "$(blist)" = "$before" ] && [ ! -e $STD/trial ]'
mkdeb() {  # id banner: h96-kernel deb of build in apt cache
    local d=$W/deb; rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/lib/h96-kernel/$NEWK" "$d/usr/lib/modules/$NEWK"
    printf "img\0%s\n\0$NOTE$(hexb "$1")pad" "$2" > "$d/usr/lib/h96-kernel/$NEWK/Image"; echo map > "$d/usr/lib/h96-kernel/$NEWK/System.map"
    echo "a.ko" > "$d/usr/lib/modules/$NEWK/modules.order"
    printf 'Package: h96-kernel-%s\nVersion: 8.0.0~r1\nArchitecture: arm64\nMaintainer: t <t@t>\nDescription: t\n' "$NEWK" > "$d/DEBIAN/control"
    mkdir -p "$R/var/cache/apt/archives"; dpkg-deb -b "$d" "$R/var/cache/apt/archives/h96-kernel-${NEWK}_8.0.0~r1_arm64.deb" > /dev/null
}
mkdeb $IDB "$B2"
ok "apt cache deb of other build only: still refused" '! B=b3 ID=$IDA km try $NEWK 2>/dev/null && [ ! -e $STD/trial ]'
mkdeb $IDA "$B1"
out=$(B=b3 ID=$IDA km try $NEWK 2>&1); rc=$?
ok "apt cache deb of in-boot build: tree taken from deb (depmod run), try accepted" '[ $rc = 0 ] && echo "$out" | grep -q "taken from" && [ "$(phase)" = armed ] && [ "$(cat "$(dirname "$(grep -l "IDS=.*$IDA" $SD/*/meta)")/tree/modules.dep")" = "depmod a.ko" ]'
mod_base; rm -rf "$STD/modules" "$R/var/cache/apt/archives"
ok "repair-modules without saved tree or deb: refused with message" 'B=b3 ID=$IDA km repair-modules 2>&1 | grep -q "no module tree of running build" && [ -z "$(mnt)" ]'
mkdeb $IDA "$B1"
ok "repair-modules with matching apt cache deb: tree built and mounted" 'B=b3 ID=$IDA km repair-modules > /dev/null && [ "$(mdep)" = "depmod a.ko" ] && ! B=b3 ID=$IDA km status | grep -q ^WARN'
rm -f "$STD/test-mount"
ok "repair-modules when package tree matches: nothing to do" 'B=b3 ID=$IDB km repair-modules | grep -q "nothing to do"'
# power loss between snapshot and switch
for cp in snap-0 snap-1; do
    mod_base; rm -rf "$STD/modules"; mkdeb $IDA "$B1"; before=$(blist)
    H96KS_DIE_AT=$cp B=b3 ID=$IDA km try $NEWK > /dev/null 2>&1; rc=$?
    ok "cut at $cp (first snapshot of try): rc 99, /boot byte-identical, no record" '[ $rc = 99 ] && [ "$(blist)" = "$before" ] && [ ! -e $STD/trial ]'
    B=b3 ID=$IDA km try $NEWK > /dev/null 2>&1
    ok "cut at $cp: retry arms trial, saved trees complete, no temp dirs" '[ "$(phase)" = armed ] && [ "$(nsnap)" = 2 ] && [ -z "$(for d in $SD/*/; do [ -s $d/tree/modules.dep ] || echo x; done)" ] && [ -z "$(find $STD/modules -name "*.h96ks-tmp")" ]'
done
mod_base; rm -rf "$STD/modules"
ok "mismatch with no saved tree: modules-mount warns, mounts nothing" 'B=b3 ID=$IDA km modules-mount 2>&1 | grep -q "WARN running build" && [ -z "$(mnt)" ]'

echo "== 17 r15: initramfs mount before switch_root, running role by build id, upgrade notice"
IB=${IB:-$HERE/../../packages/h96-kernel-switch/root/usr/share/initramfs-tools/scripts/init-bottom/h96-kernel-switch}
HK=$HERE/../../packages/h96-kernel-switch/root/usr/share/initramfs-tools/hooks/h96-kernel-switch
DI=$HERE/../../packages/h96-kernel-switch/root/usr/lib/systemd/system/modprobe@.service.d/h96-kernel-switch.conf
mkdir -p "$W/ib"
printf '#!/bin/sh\necho "mount $*" >> "%s/ib/mounts"\n' "$W" > "$W/ib/mount"
printf '#!/bin/sh\necho %s\n' "$NEWK" > "$W/ib/uname"
chmod +x "$W/ib/mount" "$W/ib/uname"
ib() { rm -f "$W/ib/mounts"; PATH="$W/ib:$PATH" rootmnt=$R H96KS_NOTES=$W/notes-$1 sh "$IB" > "$W/ib/out" 2>&1; }
mod_base
ok "try saves staged.meta (size, mtime, inode and build ids of staged Image)" 'B=b3 ID=$IDA km snapshot-modules --quiet; grep -q "^SIG=$(stat -c "%s %Y %i" $SK/Image)$" $SD/staged.meta && grep -q "^IDS=.*$IDB" $SD/staged.meta'
ib $IDA
ok "init-bottom, running A, package B, saved A: bind mount of saved tree A, then read-only remount" '[ "$(sed -n 1p $W/ib/mounts)" = "mount -o bind $(dirname "$(grep -l "IDS=.*$IDA" $SD/*/meta)")/tree $R/usr/lib/modules/$NEWK" ] && grep -qx "mount -o remount,bind,ro $R/usr/lib/modules/$NEWK" $W/ib/mounts && grep -q "mounted read-only" $W/ib/out'
ib $IDB
ok "init-bottom, running build B = package: no mount" '[ ! -e $W/ib/mounts ]'
touch -d @1700000000 "$SK/Image"; ib $IDA
ok "init-bottom, staged Image changed since staged.meta: no mount (boot unit decides)" '[ ! -e $W/ib/mounts ]'
B=b3 ID=$IDA km snapshot-modules --quiet
rm -rf "$(dirname "$(grep -l "IDS=.*$IDA" $SD/*/meta)")"; ib $IDA
ok "init-bottom, no saved tree of running build: no mount, message" '[ ! -e $W/ib/mounts ] && grep -q "no saved module tree" $W/ib/out'
rm -rf "$STD/modules"; ib $IDA
ok "init-bottom without staged.meta: no mount, silent" '[ ! -e $W/ib/mounts ] && [ ! -s $W/ib/out ]'
printf 'copy_exec() { echo "copy $*" >> "%s/ib/copies"; }\n' "$W" > "$W/ib/hookfn"
rm -f "$W/ib/copies"; H96KS_HOOKFN=$W/ib/hookfn sh "$HK"
ok "initramfs hook copies tools of init-bottom script into /usr/libexec/h96-kernel-switch" '[ "$(grep -c " /usr/libexec/h96-kernel-switch/" $W/ib/copies)" -ge 7 ] && grep -q "/mount$" $W/ib/copies && grep -q "/od$" $W/ib/copies && grep -q "/stat$" $W/ib/copies'
ok "modprobe@ drop-in orders after modules unit" 'grep -qx "After=h96-kernel-switch-modules.service" "$DI"'
# running role by build id when banners are identical
setup; stage "$B1" dtb-1; pkg $IDA "$B1" dep-A
ks try $NEWK > /dev/null; B=b2 ID=$IDA km guard; B=b2 ID=$IDA km confirm > /dev/null
pkg $IDB "$B1" dep-B
B=b3 ID=$IDA km try $NEWK > /dev/null
ok "same banner, build ids differ: list marks only generation of running build id (A = g1)" 'B=b3 ID=$IDA km list > $W/l; grep -q "^  $NEWK.g1 .*running" $W/l && ! grep -q "^  $NEWK.g2 .*running" $W/l'
ok "same banner: running build B marks g2 only" 'B=b3 ID=$IDB km list > $W/l; grep -q "^  $NEWK.g2 .*running" $W/l && ! grep -q "^  $NEWK.g1 .*running" $W/l'
ok "notice about mounted saved tree printed without --quiet too" 'echo /var/lib/h96-kernel-switch/modules/x/y/tree > $STD/test-mount; B=b3 ID=$IDA km snapshot-modules 2>&1 | grep -q "upgrade of h96-kernel-$NEWK fails until reboot"; r=$?; rm -f $STD/test-mount; [ $r = 0 ]'

echo "kernel-switch stub tests: $pass pass, $fail fail"
[ "$fail" = 0 ]
