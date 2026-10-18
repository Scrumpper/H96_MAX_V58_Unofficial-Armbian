#!/bin/bash
# Stub-root tests for h96-kernel-switch: try, confirm, revert, rollback, low space, power loss between steps.
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
pass=0 fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1 ($2)"; fi; }

mkdir -p "$W/bin"
cat > "$W/bin/mkinitramfs" <<'EOF'
#!/bin/sh
# stub: mkinitramfs -o OUT KREL
[ -d "$H96KS_ROOT/usr/lib/modules/$3" ] || exit 1
echo "initrd for $3" > "$2"
EOF
cat > "$W/bin/mkimage" <<'EOF'
#!/bin/sh
# stub: last two args are -d IN OUT
for a; do o=$p; p=$a; done
{ echo "uboot-header"; cat "$o"; } > "$p"
EOF
chmod +x "$W/bin/mkinitramfs" "$W/bin/mkimage"
export PATH="$W/bin:$PATH"

setup() {
    rm -rf "$R"
    mkdir -p "$R/boot/dtb/rockchip" "$R/usr/lib/h96-kernel/$NEWK/dtb/rockchip" "$R/usr/lib/modules/$NEWK" \
        "$R/usr/lib/modules/$OLDK" "$R/etc" "$R/var/lib"
    echo old-image > "$R/boot/Image-$OLDK"
    echo old-initrd > "$R/boot/uInitrd-$OLDK"
    ln -s "Image-$OLDK" "$R/boot/Image"
    ln -s "uInitrd-$OLDK" "$R/boot/uInitrd"
    echo old-dtb > "$R/boot/dtb/$DN"
    printf 'verbosity=1\nfdtfile=%s\nrootdev=UUID=x\n' "$DN" > "$R/boot/armbianEnv.txt"
    echo 'load ${prefix}Image' > "$R/boot/boot.cmd"
    echo scr > "$R/boot/boot.scr"
    echo INITRD_ARCH=arm64 > "$R/etc/armbian-release"
    local S=$R/usr/lib/h96-kernel/$NEWK
    echo new-image > "$S/Image"; echo map > "$S/System.map"; echo cfg > "$S/config"
    (cd "$S" && sha256sum Image System.map config > SHA256SUMS.kernel)
    echo new-dtb > "$S/dtb/$DN"
    (cd "$S/dtb" && sha256sum "$DN" > SHA256SUMS.dtb)
    echo dep > "$R/usr/lib/modules/$NEWK/modules.dep"
    PROT=$(cd "$R/boot" && sha256sum armbianEnv.txt boot.cmd boot.scr)
}
ks() { H96KS_UNAME=${U:-$OLDK} H96KS_BOOTID=${B:-b1} bash "$KS" "$@"; }
img() { readlink "$R/boot/Image"; }
ini() { readlink "$R/boot/uInitrd"; }
dtl() { readlink "$R/boot/dtb/$DN"; }
phase() { sed -n 's/^PHASE=//p' "$R/var/lib/h96-kernel-switch/trial" 2>/dev/null; }
on_old() { [ "$(img)" = "Image-$OLDK" ] && [ "$(ini)" = "uInitrd-$OLDK" ] && [ "$(dtl)" = "$DB-$OLDK" ]; }
on_new() { [ "$(img)" = "Image-$NEWK" ] && [ "$(ini)" = "uInitrd-$NEWK" ] && [ "$(dtl)" = "$DB-$NEWK" ]; }
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
# booted kernel follows Image link, as U-Boot does
boot_as() { case "$(img)" in "Image-$NEWK") echo "$NEWK" ;; *) echo "$OLDK" ;; esac; }

echo "== 1 list and status"
setup
ok "list shows staged kernel" '[ "$(ks list)" = "$NEWK" ]'
ok "status shows no trial" 'ks status | grep -qx "trial: none"'

echo "== 2 refusals leave /boot unchanged"
setup; before=$(blist)
ok "unknown KREL refused" '! ks try 6.1.999 2>/dev/null'
ok "traversal KREL refused" '! ks try ../x 2>/dev/null'
echo bad > "$R/usr/lib/h96-kernel/$NEWK/config"
ok "sha mismatch refused" '! ks try $NEWK 2>/dev/null'
setup; rm "$R/usr/lib/modules/$NEWK/modules.dep"
ok "missing modules.dep refused" '! ks try $NEWK 2>/dev/null'
setup; mkdir "$R/boot/extlinux"
ok "existing extlinux refused" 'ks try $NEWK 2>&1 | grep -q "extlinux exists" && ! ks try $NEWK 2>/dev/null && [ ! -L $R/boot/dtb/$DN ] && [ "$(img)" = Image-$OLDK ]'
rmdir "$R/boot/extlinux"
ok "running KREL refused" '! U=$NEWK ks try $NEWK 2>/dev/null'
setup; rm "$R/boot/Image"; cp "$R/boot/Image-$OLDK" "$R/boot/Image"
ok "plain Image file refused" '! ks try $NEWK 2>/dev/null'
setup; rm "$R/usr/lib/h96-kernel/$NEWK/dtb/$DN"
ok "missing staged DTB refused without --keep-dtb" '! ks try $NEWK 2>/dev/null'
setup; before=$(blist)
ks try 6.1.999 2>/dev/null; ks try ../x 2>/dev/null
ok "refusals: /boot byte-identical, no trial record" '[ "$(blist)" = "$before" ] && [ ! -e $R/var/lib/h96-kernel-switch/trial ]'

echo "== 3 low space"
setup; before=$(blist)
out=$(H96KS_AVAIL_KB=1000 ks try $NEWK 2>&1); rc=$?
ok "low space refused" '[ $rc != 0 ] && echo "$out" | grep -q "KiB free, needs"'
ok "low space: /boot byte-identical, no trial" '[ "$(blist)" = "$before" ] && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && invariant'
ok "low space: temp initramfs dir removed" '[ -z "$(ls -A $R/var/tmp 2>/dev/null)" ]'
out=$(H96KS_AVAIL_KB=16387 ks try $NEWK 2>&1); rc=$?
ok "free space 1 KiB short of files (4 KiB) plus reserve refused" '[ $rc != 0 ] && [ ! -e $R/var/lib/h96-kernel-switch/trial ]'
out=$(H96KS_AVAIL_KB=16388 ks try $NEWK 2>&1); rc=$?
ok "free space equal to files plus reserve accepted" '[ $rc = 0 ] && [ "$(phase)" = armed ]'

echo "== 4 try, healthy trial boot, confirm"
setup; e0=$(entries)
ks try $NEWK > /dev/null; rc=$?
ok "try rc 0" '[ $rc = 0 ]'
ok "links on new set, DTB link to versioned copy" 'on_new'
ok "versioned copies equal staged files" 'cmp -s $R/boot/Image-$NEWK $R/usr/lib/h96-kernel/$NEWK/Image && cmp -s $R/boot/dtb/rockchip/$DB-$NEWK $R/usr/lib/h96-kernel/$NEWK/dtb/$DN && grep -q "initrd for $NEWK" $R/boot/uInitrd-$NEWK'
ok "previous files kept; old DTB adopted byte-identical" '[ "$(cat $R/boot/Image-$OLDK)" = old-image ] && [ "$(cat $R/boot/dtb/rockchip/$DB-$OLDK)" = old-dtb ]'
ok "phase armed" '[ "$(phase)" = armed ]'
ok "writes limited to versioned files and links" '[ "$(changed "$e0")" = "./Image ./Image-$NEWK ./dtb/rockchip/$DB ./dtb/rockchip/$DB-$OLDK ./dtb/rockchip/$DB-$NEWK ./uInitrd ./uInitrd-$NEWK " ]'
ok "invariant after try" 'invariant'
ok "second try refused while trial recorded" '! ks try $NEWK 2>/dev/null'
B=b1 ks guard
ok "guard in arming boot: no action" 'on_new && [ "$(phase)" = armed ]'
U=$NEWK B=b2 ks guard; rc=$?
ok "trial boot: guard rc 0, points links back at once" '[ $rc = 0 ] && on_old && [ "$(phase)" = trial ]'
U=$NEWK B=b2 ks guard
ok "guard rerun in same boot keeps fallback" 'on_old && [ "$(phase)" = trial ]'
ok "confirm from foreign boot refused" '! U=$NEWK B=b9 ks confirm 2>/dev/null && on_old'
ok "confirm on wrong kernel refused" '! U=$OLDK B=b2 ks confirm 2>/dev/null && on_old'
U=$NEWK B=b2 ks confirm > /dev/null
ok "confirm: links on new set, trial cleared, last recorded" 'on_new && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && grep -q "^NEW_IMG=Image-$NEWK" $R/var/lib/h96-kernel-switch/last'
ok "result line confirmed" 'grep -q "confirmed $NEWK (manual)" $R/var/lib/h96-kernel-switch/result'
U=$NEWK B=b3 ks guard
ok "next boot after confirm: no action" 'on_new && invariant'
ok "list flags" 'U=$NEWK ks list | grep -qx "$NEWK \[running default in-boot\]"'

echo "== 5 trial boot not confirmed, reboot or hang lands on previous"
setup; ks try $NEWK > /dev/null
U=$NEWK B=b2 ks guard
ok "hang during trial boot: links already on previous set" 'on_old'
U=$(boot_as) B=b3 ks guard; rc=$?
ok "next boot runs previous kernel, guard rc 0" '[ $rc = 0 ] && [ "$(boot_as)" = $OLDK ]'
ok "guard records revert and clears trial" 'grep -q "reverted $NEWK: boot b2 not confirmed" $R/var/lib/h96-kernel-switch/result && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && on_old && invariant'
ks try $NEWK > /dev/null
ok "retry after revert allowed, reuses versioned files" '[ "$(phase)" = armed ] && on_new'

echo "== 6 armed but other kernel booted"
setup; ks try $NEWK > /dev/null
U=$OLDK B=b2 ks guard; rc=$?
ok "not-booted: guard rc 0, links reverted, trial cleared" '[ $rc = 0 ] && on_old && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && grep -q "not-booted $NEWK" $R/var/lib/h96-kernel-switch/result'

echo "== 7 auto-confirm"
setup; ks try $NEWK > /dev/null
U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks auto-confirm
ok "auto-confirm not chosen: no confirm" 'on_old && [ "$(phase)" = trial ]'
setup; ks try $NEWK --auto-confirm > /dev/null
U=$NEWK B=b2 ks guard; rc=$?
ok "auto trial boot: guard rc 0" '[ $rc = 0 ] && on_old'
U=$NEWK B=b2 H96KS_HEALTHY=0 ks auto-confirm
ok "auto-confirm, unhealthy: no confirm" 'on_old && [ "$(phase)" = trial ]'
U=$NEWK B=b2 H96KS_HEALTHY=1 ks auto-confirm
ok "auto-confirm, healthy: confirmed" 'on_new && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && grep -q "confirmed $NEWK (auto)" $R/var/lib/h96-kernel-switch/result'
ok "auto-confirm with nothing recorded: rc 0, no change" 'U=$NEWK B=b3 ks auto-confirm && on_new'

echo "== 8 rollback"
setup; ks try $NEWK > /dev/null
ks rollback > /dev/null
ok "rollback before reboot cancels trial" 'on_old && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && grep -q "cancelled $NEWK" $R/var/lib/h96-kernel-switch/result'
ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard
U=$NEWK B=b2 ks rollback > /dev/null
ok "rollback during trial boot clears trial, links on previous" 'on_old && [ ! -e $R/var/lib/h96-kernel-switch/trial ]'
ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
U=$NEWK B=b3 ks rollback > /dev/null
ok "rollback after confirm: previous set incl. adopted DTB" 'on_old && invariant'
U=$OLDK B=b4 ks rollback > /dev/null
ok "rollback again returns to confirmed set" 'on_new'
ln -sfn "Image-$OLDK" "$R/boot/Image"
ok "rollback refused when links differ from last set" '! ks rollback 2>/dev/null'
setup
ok "rollback with nothing recorded refused" '! ks rollback 2>/dev/null'

echo "== 9 keep-dtb and identical DTB"
setup; ks try $NEWK --keep-dtb > /dev/null
ok "--keep-dtb: DTB stays plain file" '[ ! -L $R/boot/dtb/$DN ] && [ "$(cat $R/boot/dtb/$DN)" = old-dtb ] && [ ! -e $R/boot/dtb/rockchip/$DB-$NEWK ]'
U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
ok "--keep-dtb confirm: kernel links only" '[ "$(img)" = Image-$NEWK ] && [ ! -L $R/boot/dtb/$DN ]'
setup; echo old-dtb > "$R/usr/lib/h96-kernel/$NEWK/dtb/$DN"
(cd "$R/usr/lib/h96-kernel/$NEWK/dtb" && sha256sum "$DN" > SHA256SUMS.dtb)
ks try $NEWK > /dev/null
ok "identical DTB: no DTB write" '[ ! -L $R/boot/dtb/$DN ] && [ "$(img)" = Image-$NEWK ] && [ -z "$(ls $R/boot/dtb/rockchip | grep -v "^$DB$")" ]'

echo "== 10 prune"
setup; ks try $NEWK > /dev/null
ok "prune of trial kernel refused" '! ks prune $NEWK 2>/dev/null'
ok "prune of previous kernel refused" '! ks prune $OLDK 2>/dev/null'
U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
ok "prune of last-confirm previous refused" '! U=$NEWK ks prune $OLDK 2>/dev/null'
setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$OLDK B=b3 ks guard
ok "prune of reverted kernel removes its versioned files only" 'ks prune $NEWK > /dev/null && [ ! -e $R/boot/Image-$NEWK ] && [ ! -e $R/boot/uInitrd-$NEWK ] && [ ! -e $R/boot/dtb/rockchip/$DB-$NEWK ] && on_old && invariant'

echo "== 11 unreadable record and leftovers"
setup; ks try $NEWK > /dev/null
echo 'PHASE=armed; rm -rf /' > "$R/var/lib/h96-kernel-switch/trial"
U=$NEWK B=b2 ks guard
ok "unreadable trial moved aside, links left as found" 'on_new && ls $R/var/lib/h96-kernel-switch/ | grep -q "^trial.bad-" && [ ! -e $R/var/lib/h96-kernel-switch/trial ]'

echo "== 12 power loss at each step of try, then boot"
for cp in copy-0 copy-1 copy-2 adopt copy-3 switch-0 switch-a switch-b switch-1; do
    setup
    H96KS_DIE_AT=$cp ks try $NEWK > /dev/null 2>&1; rc=$?
    b=$(boot_as)
    U=$b B=b2 ks guard
    if [ "$(img)" = "Image-$NEWK" ]; then U=$NEWK B=b3 ks guard; fi
    ok "cut at $cp: rc 99, guard leaves consistent previous set, no record, no tmp" '[ $rc = 99 ] && [ "$(img)" = Image-$OLDK ] && [ "$(ini)" = uInitrd-$OLDK ] && { [ ! -L $R/boot/dtb/$DN ] || [ "$(dtl)" = $DB-$OLDK ]; } && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && invariant'
    ks try $NEWK > /dev/null 2>&1
    ok "cut at $cp: retry arms trial" '[ "$(phase)" = armed ] && on_new'
done

echo "== 13 power loss in guard, confirm and rollback"
setup; ks try $NEWK > /dev/null
U=$NEWK B=b2 H96KS_DIE_AT=guard-0 ks guard 2>/dev/null
ok "cut after trial record, before fallback links: next boot is trial kernel again" '[ "$(boot_as)" = $NEWK ]'
U=$NEWK B=b3 ks guard
ok "guard then reverts (unconfirmed boot b2)" 'on_old && grep -q "reverted $NEWK: boot b2" $R/var/lib/h96-kernel-switch/result'
for cp in revert-a revert-b; do
    setup; ks try $NEWK > /dev/null
    U=$NEWK B=b2 H96KS_DIE_AT=$cp ks guard 2>/dev/null
    U=$(boot_as) B=b3 ks guard
    if [ "$(img)" = "Image-$NEWK" ]; then U=$NEWK B=b4 ks guard; fi
    ok "cut in guard fallback at $cp: previous set after next boot" 'on_old && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && invariant'
done
for cp in confirm-0 confirm-a confirm-b confirm-1; do
    setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard
    U=$NEWK B=b2 H96KS_DIE_AT=$cp ks confirm > /dev/null 2>&1
    U=$(boot_as) B=b3 ks guard
    if [ "$(img)" = "Image-$NEWK" ]; then U=$NEWK B=b4 ks guard; fi
    ok "cut in confirm at $cp: consistent previous set, confirm lost" 'on_old && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && invariant'
done
for cp in rollback-a rollback-b; do
    setup; ks try $NEWK > /dev/null; U=$NEWK B=b2 ks guard; U=$NEWK B=b2 ks confirm > /dev/null
    U=$NEWK B=b3 H96KS_DIE_AT=$cp ks rollback > /dev/null 2>&1
    U=$(boot_as) B=b4 ks guard
    ok "cut in rollback at $cp: confirmed set restored at next boot" 'on_new && [ ! -e $R/var/lib/h96-kernel-switch/trial ] && invariant'
done

echo "kernel-switch stub tests: $pass pass, $fail fail"
[ "$fail" = 0 ]
