#!/bin/bash
# Rootless v8.0 Ubuntu image build. v7.2 partitions to trees (debugfs rdump in user namespace), this
# folder's chroot steps under qemu-user binfmt, trees back to ext4 (mke2fs -d, base geometry/UUID/label), spliced into copy of v7.2 image.
# No sudo, no /boot writes. Run stage.sh dryrun first (writes stage/); after splice: stage.sh loader, stage.sh pack.
# Env: H96_V72_XZ (v7.2 .img.xz, .sha256 beside it), H96_WORK, H96_RC_OUT, H96_HEAVY_LOCK=0, BOXIMG (parity), H96_REF_LOG (gates INFO)
# Usage: build.sh base | extract | chroot | mkfs | splice | pack | all | null
#   base     v7.2 image sha, GPT, superblocks, debugfs listings (with content sha)
#   extract  rdump p1/p2 into trees, fix up owner/mode/links/xattrs/times, tree = base listing
#   chroot   image steps (repo-apply, f5, kernel, brand, final-check, clean) on trees, then gates
#   gates    re-read chroot logs: six steps rc=0 fail=0, chroot /dev and unmount, INFO compare with box r15 logs
#   mkfs     final trees to ext4 with base parameters, fsck, superblock diff, image listing = tree listing
#   splice   new filesystems into copy of base image; loader, GPT, gap, tail byte-equal to base
#   pack     xz, round trip, sums in OUT (release packs with stage.sh loader + pack instead)
#   parity   compare with another image (BOXIMG, read only): loader, listings incl. content
#   null     extract + mkfs without chroot: round trip must reproduce base listing (pipeline self test)
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
V72XZ=${H96_V72_XZ:-}
V72IMG=9f366f0945667a753f227cff9a93b33571a1e250f74802435f2ad0e57ecc2b2d
C=${XDG_CACHE_HOME:-$HOME/.cache}
W=${H96_WORK:-$C/h96-v80-work}; ST=$W/stage; EV=$W/evidence/build
OUT=${H96_RC_OUT:-$C/h96-v80-out}; NAME=H96-MAX-V58_Unofficial-Armbian_v8.0
P1_OFF=16777216; P1_SZ=$((1046528 * 512)); P2_OFF=553648128; P2_SZ=$((6141952 * 512))
STEPS="repo-apply.sh f5-chroot.sh stage-kernel.sh image-brand.sh final-check.sh image-clean.sh repo-closure.py"
X=(python3 -I "$H/ext4list.py")
export E4L_TMP=$W
heavy() { if [ "${H96_HEAVY_LOCK:-1}" = 1 ]; then flock "$C/h96-heavy.lock" systemd-run --user --scope -q -p MemoryMax=20G -p CPUQuota=600% nice -n10 "$@"
  else systemd-run --user --scope -q -p MemoryMax=20G -p CPUQuota=600% nice -n10 "$@"; fi; }
ns() { unshare --map-auto --map-root-user "$@"; }
fail=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fail=1; }
bootsnap() { ls -la --time-style=full-iso /boot 2>/dev/null | md5sum | cut -d' ' -f1; }
sbv() { sed -n "s/^$2: *//p" "$1"; }
case "$(realpath -m "$W")" in /|/boot|/boot/*) echo "refuse work dir $W"; exit 2 ;; esac
# unfilled pin refuses the build
grep -q PLACEHOLDER "$H/inputs.sha256" && { echo "FAIL inputs.sha256 holds a PLACEHOLDER pin: $(grep PLACEHOLDER "$H/inputs.sha256")"; exit 2; }

base() {
  mkdir -p "$W" "$EV"
  [ -f "$V72XZ" ] || { bad "set H96_V72_XZ to H96-MAX-V58_Unofficial-Armbian_v7.2.img.xz"; return 1; }
  if [ ! -f "$W/base.img" ] || [ "$(sha256sum < "$W/base.img" | cut -d' ' -f1)" != "$V72IMG" ]; then
    (cd "$(dirname "$V72XZ")" && sha256sum -c --status "$(basename "$V72XZ").sha256") || { bad "v7.2 img.xz sha"; return 1; }
    xz -T0 -dc "$V72XZ" > "$W/base.img" || return 1
  fi
  [ "$(sha256sum < "$W/base.img" | cut -d' ' -f1)" = "$V72IMG" ] && ok "v7.2 base img sha 9f366f09" || { bad "base img sha"; return 1; }
  sfdisk -d "$W/base.img" | grep -v '^device:' | sed 's#^.*\.img\([0-9]\) :#p\1 :#' > "$EV/gpt-base.txt"
  grep -q "start= *$((P1_OFF / 512)), size= *$((P1_SZ / 512))," "$EV/gpt-base.txt" && grep -q "start= *$((P2_OFF / 512)), size= *$((P2_SZ / 512))," "$EV/gpt-base.txt" \
    && ok "GPT p1/p2 offsets and sizes = ns-up.sh constants" || bad "GPT layout"
  dd if="$W/base.img" of="$W/p1.base" bs=4M skip=$P1_OFF count=$P1_SZ iflag=skip_bytes,count_bytes status=none
  dd if="$W/base.img" of="$W/p2.base" bs=4M skip=$P2_OFF count=$P2_SZ iflag=skip_bytes,count_bytes status=none
  for n in 1 2; do
    dumpe2fs -h "$W/p$n.base" > "$EV/sb-p$n-base.txt" 2>/dev/null || bad "dumpe2fs p$n"
    [ "$(( $(sbv "$EV/sb-p$n-base.txt" 'Block count') * $(sbv "$EV/sb-p$n-base.txt" 'Block size') ))" = "$(stat -c %s "$W/p$n.base")" ] \
      && ok "p$n filesystem fills partition" || bad "p$n filesystem size vs partition"
    rm -rf "$W/x-p$n"
    "${X[@]}" img "$W/p$n.base" "$W/l-p$n-base.tsv" --content --xattr-dir "$W/x-p$n" || bad "listing p$n"
    echo "  p$n types: $(awk -F'\t' 'NR>1{t[$2]++} END{for(k in t) printf "%s=%d ", k, t[k]}' "$W/l-p$n-base.tsv")xattr=$(awk -F'\t' 'NR>1 && $11!="-"' "$W/l-p$n-base.tsv" | wc -l) hardlinked=$(awk -F'\t' 'NR>1 && $10!="-"' "$W/l-p$n-base.tsv" | wc -l) maxuid=$(awk -F'\t' 'NR>1 && $4>m{m=$4} END{print m+0}' "$W/l-p$n-base.tsv")"
    [ "$(awk -F'\t' 'NR>1 && ($4>65535 || $5>65535)' "$W/l-p$n-base.tsv" | wc -l)" = 0 ] && ok "p$n ids inside namespace map (0-65535)" || bad "p$n ids beyond map"
    awk -F'\t' 'NR>1 && $11 ~ /trusted\./' "$W/l-p$n-base.tsv" | grep -q . && bad "p$n trusted.* xattr (not settable in user namespace)"
    gzip -9nc "$W/l-p$n-base.tsv" > "$EV/l-p$n-base.tsv.gz"
  done
}

extract() {
  local n src
  [ -f "$W/l-p2-base.tsv" ] || { bad "run base first"; return 1; }
  rm -f "$W/extract.ok" "$W/chroot.done"
  ns rm -rf "$W/p1" "$W/p2" || return 1
  for n in 1 2; do
    src=$W/p$n.base; mkdir -p "$W/p$n"
    debugfs -R 'ls -p /' "$src" 2>/dev/null | awk -F/ 'NF>=6 && $6!="." && $6!=".." && $2!=0 {print $6}' \
      | while IFS= read -r e; do printf 'rdump "/%s" "%s"\n' "$e" "$W/p$n"; done > "$W/rdump-p$n.cmds"
    ns debugfs -f "$W/rdump-p$n.cmds" "$src" > "$W/rdump-p$n.log" 2>&1 || bad "rdump p$n"
    grep -v '^debugfs' "$W/rdump-p$n.log" | grep -q . && { head "$W/rdump-p$n.log"; bad "rdump p$n messages"; }
    ns "${X[@]}" fixup "$W/p$n" "$W/l-p$n-base.tsv" "$W/x-p$n" "$W/dev-p$n.tsv" || bad "fixup p$n"
    ns "${X[@]}" tree "$W/p$n" "$W/l-p$n-extract.tsv" --content || bad "tree listing p$n"
    "${X[@]}" cmp "$W/l-p$n-base.tsv" "$W/l-p$n-extract.tsv" --quiet > "$EV/cmp-p$n-base-extract.txt"; tail -1 "$EV/cmp-p$n-base-extract.txt"
    grep -q 'bad=0$' "$EV/cmp-p$n-base-extract.txt" && ok "p$n tree = base listing (type mode setuid owner size target mtime.ns links xattrs content)" || bad "p$n extract differs ($EV/cmp-p$n-base-extract.txt)"
  done
  [ "$fail" = 0 ] && sha256sum "$W/l-p1-base.tsv" "$W/l-p2-base.tsv" > "$W/extract.ok"
}

okstage() {
  [ -f "$ST/DRYRUN-OK" ] && sha256sum -c --status "$ST/DRYRUN-OK" && (cd "$ST" && sha256sum -c --quiet inputs.sha256 scripts.sha256) \
    || { bad "stage not from a passing dryrun of current pins"; return 1; }
}

chroot_steps() {
  local s
  okstage || return 1
  [ -f "$W/extract.ok" ] && [ ! -e "$W/chroot.done" ] || { bad "chroot needs fresh extract (extract.ok, no chroot.done)"; return 1; }
  for s in $STEPS; do cmp -s "$H/$s" "$ST/$s" || bad "stage $s differs from folder copy"; done
  [ "$fail" = 0 ] && ok "staged chroot scripts = folder scripts"
  rm -rf "$W/in" "$W/log"; cp -a "$ST" "$W/in"; mkdir -p "$W/log"
  # as box-run.sh check
  (cd "$W/in" && sha256sum -c --quiet inputs.sha256 && sha256sum -c --quiet scripts.sha256) && ok "inputs and scripts" || bad "inputs or scripts"
  (cd "$W/in/repo" && sha256sum -c --quiet index.sha256 && sha256sum -c --quiet add.sha256) && ok "repo stage" || bad "repo stage"
  find "$W/in" -path '*gnupg*' -o -name '*.key' -o -name 'secring*' -o -name '*.sec' | grep -q . && bad "key material in staged inputs" || ok "no key material in staged inputs"
  [ "$fail" = 0 ] || return 1
  rm -f "$W/extract.ok"; echo started > "$W/chroot.done"
  ns -m -p -f -n --propagation private bash "$H/chroot-ns.sh" "$W" 2>&1 | tee "$EV/chroot-ns.txt"
  local rc=${PIPESTATUS[0]}
  rm -rf "$EV/log"; cp -a "$W/log" "$EV/log"
  [ "$rc" = 0 ] && ok "chroot-ns rc=0" || bad "chroot-ns rc=$rc"
  chroot_gates
}

chroot_gates() {  # reads chroot logs only
  local s f BL=${H96_REF_LOG:-}
  for s in repo-apply f5-chroot stage-kernel image-brand final-check image-clean; do
    grep -qx "$s.sh rc=0" "$EV/chroot-ns.txt" && tail -3 "$W/log/$s-run.txt" 2>/dev/null | grep -qx 'fail=0' && ok "$s.sh rc=0 fail=0" || bad "$s.sh not rc=0 fail=0"
  done
  grep -qx 'root UUID resolves to ext4 in chroot' "$EV/chroot-ns.txt" && grep -qx 'chroot-ns rc=0' "$EV/chroot-ns.txt" && ok "chroot /dev root UUID resolved, unmounted clean" || bad "chroot-ns setup or unmount"
  # optional compare with reference chroot logs (H96_REF_LOG): INFO, diffs kept for review
  [ -n "$BL" ] && [ -d "$BL" ] || { [ "$fail" = 0 ] && echo ok > "$W/chroot.done"; return; }
  mkdir -p "$EV/vs-r15"
  for f in kernel/initrd-6.1.172-h96v58-8.0.lst dpkg-V-pre.txt dpkg-V-post.txt divert-post.txt statoverride-post.txt final/enabled-units.txt repo-deps.txt saved-left.txt usr-local-new.txt final/dpkg-V-all.txt; do
    if cmp -s "$BL/$f" "$W/log/$f"; then echo "INFO $f = box r15"; else diff "$BL/$f" "$W/log/$f" > "$EV/vs-r15/$(echo "$f" | tr / _).diff"; echo "INFO $f differs from box r15 ($(grep -c '^[<>]' "$EV/vs-r15/$(echo "$f" | tr / _).diff") lines)"; fi
  done
  [ "$fail" = 0 ] && echo ok > "$W/chroot.done"
}

mkfs_one() {  # n src-tree out
  local n=$1 tree=$2 out=$3 sb=$EV/sb-p$1-base.txt conf=$W/mke2fs-p$1.conf feats jmb
  feats=$(sbv "$sb" 'Filesystem features' | tr ' ' ',')
  jmb=$(( $(sbv "$sb" 'Total journal blocks') * $(sbv "$sb" 'Block size') / 1048576 ))
  printf '[defaults]\n\tbase_features = %s\n\tdefault_mntopts = %s\n\tenable_periodic_fsck = 0\n\tblocksize = %s\n\tinode_size = %s\n\treserved_ratio = 0\n\thash_alg = %s\n\terrors = remount-ro\n\tflex_bg_size = %s\n[fs_types]\n\text4 = {\n\t\tfeatures = has_journal\n\t}\n' \
    "$feats" "$(sbv "$sb" 'Default mount options' | tr ' ' ',')" "$(sbv "$sb" 'Block size')" "$(sbv "$sb" 'Inode size')" \
    "$(sbv "$sb" 'Default directory hash')" "$(sbv "$sb" 'Flex block group size')" > "$conf"
  rm -f "$out"; truncate -s "$(stat -c %s "$W/p$n.base")" "$out"
  MKE2FS_CONFIG=$conf E2FSPROGS_FAKE_TIME=$(date -d "$(sbv "$sb" 'Filesystem created')" +%s) mke2fs -F -q -t ext4 -T default \
    -b "$(sbv "$sb" 'Block size')" -I "$(sbv "$sb" 'Inode size')" -N "$(sbv "$sb" 'Inode count')" -g "$(sbv "$sb" 'Blocks per group')" \
    -G "$(sbv "$sb" 'Flex block group size')" -m 0 -J "size=$jmb" -L "$(sbv "$sb" 'Filesystem volume name')" -U "$(sbv "$sb" 'Filesystem UUID')" \
    -E "hash_seed=$(sbv "$sb" 'Directory Hash Seed'),lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0" \
    -d "$tree" "$out" "$(sbv "$sb" 'Block count')" || return 1
  # box ns-down.sh: last-mounted cleared, mount count as base
  tune2fs -M "" -C "$(sbv "$sb" 'Mount count')" -c -1 -i 0 -e remount-ro -r "$(sbv "$sb" 'Reserved block count')" "$out" > /dev/null || return 1
}

mkfs() {
  local n
  if [ "${1:-}" != null ]; then [ "$(cat "$W/chroot.done" 2>/dev/null)" = ok ] || { bad "chroot steps not complete"; return 1; }
  else [ -f "$W/extract.ok" ] || { bad "null needs fresh extract"; return 1; }; fi
  for n in 1 2; do
    ns "${X[@]}" tree "$W/p$n" "$W/l-p$n-tree.tsv" --content || bad "tree listing p$n"
    [ -s "$W/dev-p$n.tsv" ] && bad "p$n device nodes need mkdev (none expected)"
    ns "$0" _mkfs1 "$n" || { bad "mke2fs p$n"; continue; }
    "${X[@]}" settimes "$W/p$n.new" "$W/l-p$n-tree.tsv" || bad "settimes p$n"
    e2fsck -fn "$W/p$n.new" > "$EV/e2fsck-p$n.txt" 2>&1 && ok "e2fsck -fn p$n rc=0" || { tail -5 "$EV/e2fsck-p$n.txt"; bad "e2fsck p$n"; }
    dumpe2fs -h "$W/p$n.new" > "$EV/sb-p$n-new.txt" 2>/dev/null
    diff "$EV/sb-p$n-base.txt" "$EV/sb-p$n-new.txt" | grep '^[<>]' > "$EV/sb-p$n-diff.txt"
    sed 's/^[<>] //; s/:.*//' "$EV/sb-p$n-diff.txt" | sort -u \
      | grep -vxE 'Last mounted on|Free blocks|Free inodes|Overhead clusters|Last mount time|Last write time|Last checked|Lifetime writes|Checksum|Journal sequence|Journal checksum|Journal start|Journal features|Journal checksum type' \
      | sed "s/^/p$n sb field differs: /" | tee "$EV/sb-p$n-unexpected.txt"
    [ ! -s "$EV/sb-p$n-unexpected.txt" ] && ok "p$n superblock = base apart from: $(sed 's/^[<>] //; s/:.*//' "$EV/sb-p$n-diff.txt" | sort -u | paste -sd,)" || bad "p$n superblock fields"
    [ "$(sbv "$EV/sb-p$n-new.txt" 'Last mounted on')" = "<not available>" ] && ok "p$n last-mounted cleared" || bad "p$n last-mounted"
    # fresh journal: kernel sets revoke/64bit/csum v3 journal features at first mount
    [ "$(sbv "$EV/sb-p$n-new.txt" 'Journal features')" = "(none)" ] && ok "p$n journal features unset until first mount (base: $(sbv "$EV/sb-p$n-base.txt" 'Journal features'))" || bad "p$n journal features"
    for k in UUID LABEL TYPE; do [ "$(blkid -p -s $k -o value "$W/p$n.base")" = "$(blkid -p -s $k -o value "$W/p$n.new")" ] || bad "p$n blkid $k"; done
    ok "p$n blkid UUID LABEL TYPE = base ($(blkid -p -s UUID -o value "$W/p$n.new") $(blkid -p -s LABEL -o value "$W/p$n.new"))"
    "${X[@]}" img "$W/p$n.new" "$W/l-p$n-new.tsv" --content || bad "image listing p$n"
    "${X[@]}" cmp "$W/l-p$n-tree.tsv" "$W/l-p$n-new.tsv" --quiet > "$EV/cmp-p$n-tree-image.txt"; tail -1 "$EV/cmp-p$n-tree-image.txt"
    grep -q 'bad=0$' "$EV/cmp-p$n-tree-image.txt" && ok "p$n image = tree (debugfs listing incl. content sha)" || bad "p$n image differs from tree"
    if [ "${1:-}" = null ]; then
      "${X[@]}" cmp "$W/l-p$n-base.tsv" "$W/l-p$n-new.tsv" --quiet > "$EV/null-cmp-p$n.txt"; tail -1 "$EV/null-cmp-p$n.txt"
      grep -q 'bad=0$' "$EV/null-cmp-p$n.txt" && ok "null round trip p$n = base listing" || bad "null round trip p$n"
    fi
    echo "  p$n free $(( $(sbv "$EV/sb-p$n-new.txt" 'Free blocks') * 4096 )) B (base $(( $(sbv "$EV/sb-p$n-base.txt" 'Free blocks') * 4096 ))), inodes free $(sbv "$EV/sb-p$n-new.txt" 'Free inodes')"
    gzip -9nc "$W/l-p$n-new.tsv" > "$EV/l-p$n-new.tsv.gz"
  done
  # final-check.sh df gate sees laptop disk in chroot; same gate on image rootfs
  [ $(( ($(sbv "$EV/sb-p2-new.txt" 'Free blocks') - $(sbv "$EV/sb-p2-new.txt" 'Reserved block count')) * 4096 )) -gt 67108864 ] && ok "image rootfs free > 64 MiB" || bad "image rootfs free space"
  # kernel switch saved trees: hard links into /usr/lib/modules must survive mke2fs -d (same inode, link count 2)
  local ks=/var/lib/h96-kernel-switch/modules d k pi si nh=0
  if [ -d "$W/p2$ks" ] && [ "${1:-}" != null ]; then
    for d in "$W/p2$ks"/*/*/tree; do
      k=$(basename "$(dirname "$(dirname "$d")")")
      while read -r f; do
        pi=$(debugfs -R "stat /usr/lib/modules/$k/$f" "$W/p2.new" 2>/dev/null | sed -n 's/^Inode: *\([0-9]*\).*/\1/p')
        si=$(debugfs -R "stat ${d#"$W/p2"}/$f" "$W/p2.new" 2>/dev/null | sed -n 's/^Inode: *\([0-9]*\).*/\1/p')
        if [ -n "$pi" ] && [ "$pi" = "$si" ]; then nh=$((nh + 1)); else bad "saved tree $k/$f not hard-linked in image (inode $pi vs $si)"; fi
      done < <(cd "$d" && find . -name '*.ko*' | sed 's#^\./##' | sort | sed -n '1p;100p;500p;$p')
    done
    ok "image: $nh sampled saved-tree .ko files share inode with /usr/lib/modules"
  fi
  [ "$fail" = 0 ] && echo ok > "$W/mkfs.ok"
}

splice() {
  local n off sz end
  [ -f "$W/mkfs.ok" ] || { bad "mkfs not complete"; return 1; }
  rm -f "$W/out.img"; cp --sparse=always "$W/base.img" "$W/out.img" || return 1
  dd if="$W/p1.new" of="$W/out.img" bs=4M seek=$P1_OFF oflag=seek_bytes conv=notrunc,fsync status=none || return 1
  dd if="$W/p2.new" of="$W/out.img" bs=4M seek=$P2_OFF oflag=seek_bytes conv=notrunc,fsync status=none || return 1
  end=$(stat -c %s "$W/base.img")
  [ "$(stat -c %s "$W/out.img")" = "$end" ] && ok "image size = base ($end)" || bad "image size"
  for r in "0 $P1_OFF loader+GPT" "$((P1_OFF + P1_SZ)) $((P2_OFF - P1_OFF - P1_SZ)) gap" "$((P2_OFF + P2_SZ)) $((end - P2_OFF - P2_SZ)) tail+backup-GPT"; do
    read -r off sz n <<< "$r"
    cmp -s -i "$off:$off" -n "$sz" "$W/base.img" "$W/out.img" && ok "$n byte-equal to base ($sz B at $off)" || bad "$n differs"
  done
  cmp -s <(sfdisk -d "$W/out.img" | grep -v '^device:' | sed 's#^.*\.img\([0-9]\) :#p\1 :#') "$EV/gpt-base.txt" && ok "partition table = base" || bad "partition table"
  for n in 1 2; do
    if [ $n = 1 ]; then off=$P1_OFF; sz=$P1_SZ; else off=$P2_OFF; sz=$P2_SZ; fi
    cmp -s -i "$off:0" -n "$sz" "$W/out.img" "$W/p$n.new" && [ "$(stat -c %s "$W/p$n.new")" = "$sz" ] && ok "p$n in image = built filesystem" || bad "p$n splice"
  done
  [ "$fail" = 0 ] || return 1
  mkdir -p "$OUT"; mv -f "$W/out.img" "$OUT/$NAME.img"
  (cd "$OUT" && sha256sum "$NAME.img" > "$NAME.img.sha256"); cat "$OUT/$NAME.img.sha256"
  cp -p "$OUT/$NAME.img.sha256" "$EV/"
}

pack() {
  local i x
  (cd "$OUT" && sha256sum -c --status "$NAME.img.sha256") || { bad "img sha"; return 1; }
  xz -T0 -9 -k -f "$OUT/$NAME.img" || return 1
  i=$(cut -d' ' -f1 "$OUT/$NAME.img.sha256"); x=$(sha256sum < "$OUT/$NAME.img.xz" | cut -d' ' -f1)
  [ "$(xz -dc "$OUT/$NAME.img.xz" | sha256sum | cut -d' ' -f1)" = "$i" ] && ok "xz round trip" || { bad "xz round trip"; return 1; }
  echo "$x  $NAME.img.xz" > "$OUT/$NAME.img.xz.sha256"
  printf '%s  %s\n%s  %s\n' "$x" "$NAME.img.xz" "$i" "$NAME.img" > "$OUT/SHA256SUMS"; cp -p "$OUT/SHA256SUMS" "$EV/"
  ls -l "$OUT/$NAME.img.xz"
}

parity() {  # box-built image (read only): same partition layout, file tree diff by debugfs listings
  local B=${BOXIMG:?set BOXIMG} n off sz
  (cd "$(dirname "$B")" && sha256sum -c --status "$(basename "$B").sha256") && ok "box image sha $(cut -c1-8 "$B.sha256")" || { bad "box image sha"; return 1; }
  cmp -s -n "$P1_OFF" "$B" "$OUT/$NAME.img" && ok "loader+GPT = box image" || bad "loader+GPT vs box image"
  for n in 1 2; do
    if [ $n = 1 ]; then off=$P1_OFF; sz=$P1_SZ; else off=$P2_OFF; sz=$P2_SZ; fi
    dd if="$B" of="$W/p$n.box" bs=4M skip="$off" count="$sz" iflag=skip_bytes,count_bytes status=none
    dumpe2fs -h "$W/p$n.box" > "$EV/sb-p$n-box.txt" 2>/dev/null
    "${X[@]}" img "$W/p$n.box" "$W/l-p$n-box.tsv" --content || bad "listing box p$n"
    "${X[@]}" cmp "$W/l-p$n-box.tsv" "$W/l-p$n-new.tsv" > "$EV/parity-p$n.txt"; tail -1 "$EV/parity-p$n.txt"
    echo "  p$n differing fields: $(grep -o '^DIFF [^ ]* .*' "$EV/parity-p$n.txt" | sed 's/^DIFF [^ ]* //; s/:[^ ]*//g' | tr ' ' '\n' | sort | uniq -c | xargs)"
    echo "  p$n content differs: $(grep '^DIFF' "$EV/parity-p$n.txt" | grep -c ' sha:')  only-box: $(grep -c '^ONLY-A' "$EV/parity-p$n.txt")  only-laptop: $(grep -c '^ONLY-B' "$EV/parity-p$n.txt")"
    rm -f "$W/p$n.box"
  done
}

run() {  # step: inside heavy scope, laptop /boot listing checked around it
  local b0 t0 cg; b0=$(bootsnap); mkdir -p "$EV"; t0=$(date +%s)
  case "$1" in
    base) base ;; extract) extract ;; chroot) chroot_steps ;; gates) chroot_gates ;; parity) parity ;; mkfs) mkfs ;; splice) splice ;; pack) pack ;;
    null) extract && mkfs null ;;
  esac
  [ "$(bootsnap)" = "$b0" ] && ok "laptop /boot listing unchanged" || bad "laptop /boot listing changed"
  # wall time and scope cgroup memory.peak (all children incl. namespaces)
  cg=/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)
  printf '%s\t%s\t%ss\tpeak=%s\tfail=%s\n' "$(date -Is)" "$1" "$(( $(date +%s) - t0 ))" "$(cat "$cg/memory.peak" 2>/dev/null || echo ?)" "$fail" | tee -a "$EV/timings.tsv"
  echo "$1 fail=$fail"; [ "$fail" = 0 ]
}

case "${1:-}" in
  _run) run "$2" ;;
  _mkfs1) mkfs_one "$2" "$W/p$2" "$W/p$2.new" ;;
  base|extract|chroot|gates|mkfs|splice|pack|null|parity) mkdir -p "$EV"; heavy "$0" _run "$1" 2>&1 | tee "$EV/$1.txt"; exit "${PIPESTATUS[0]}" ;;
  all) for s in base extract chroot mkfs splice; do "$0" "$s" || { echo "STOP at $s"; exit 1; }; done ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
