#!/bin/bash
# Same claim as test-freeze-stack.sh -- freezing env2.img (stacked live on
# env1.sqf) into a self-contained env3.sqf preserves both what it added and
# what it deleted -- but packed via the rdump route instead of a live
# fuse2fs/squashfuse/fuse-overlayfs union: freeze already has two pack routes
# (mount a fuse union vs stage both sides to a plain directory first), and
# rdump is the one used when a host can't do the unprivileged FUSE mount at
# all. This checks the new mechanism holds on that route too, not just the
# mount one.
#
# Because nothing here needs a live merged view, this script needs no
# unshare/squashfuse/fuse2fs/fuse-overlayfs at all: every read is a plain
# unsquashfs/debugfs extraction, the merge is done with `cp`+`rm` on disk, and
# the only mounts anywhere are the two real `apptainer exec` calls that create
# the state in the first place -- apptainer does its own mounting for those,
# same as any ordinary condatainer command.
set -uo pipefail

CNT=${CNT:-condatainer}
BASE="${BASE:?BASE=/path/to/base.sqf is required}"
WORK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$WORK"
rm -rf img sqf stage
mkdir -p img sqf stage

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
quiet() { grep -vE '^WARNING: While bind mounting|^INFO:    Ignoring invalid max threads|^WARNING: group: unknown' || true; }

[ -f "$BASE" ] || fail "base image not found: $BASE (pass BASE=/path/to/base.sqf)"
for t in apptainer debugfs unsquashfs mksquashfs; do
    command -v "$t" >/dev/null || fail "$t not found"
done

echo "== 0. env1.img: write, delete a base file, freeze =="
$CNT overlay create img/env1.img -s 200M -p small -S -q
$CNT exec -w -o img/env1.img -q -- bash -euo pipefail -c '
  mkdir -p /cnt_env
  echo stage1-keep > /cnt_env/keep.txt
  echo stage1-delete-me > /cnt_env/willdelete.txt
  rm /etc/hostname
' 2>&1 | quiet
$CNT overlay freeze img/env1.img sqf/env1.sqf -q 2>&1 | quiet
pass "env1.sqf built"

echo "== 1. mount env1.sqf(ro) + a fresh env2.img(rw) together, live, and edit =="
$CNT overlay create img/env2.img -s 200M -p small -S -q
apptainer exec \
  --overlay "$WORK/sqf/env1.sqf:ro" \
  --overlay "$WORK/img/env2.img:rw" \
  "$BASE" bash -euo pipefail -c '
    echo stage2-new > /cnt_env/newfile.txt   # add
    rm /cnt_env/willdelete.txt               # delete something env1.sqf itself provided
    rm /etc/os-release                       # delete something only the base provides
  ' 2>&1 | quiet
pass "env2.img now holds the delta on top of env1.sqf"

echo "== 2. extract both sides, no mount, no unshare =="
echo "-- unsquashfs env1.sqf -> stage/lower (device node warning/exit 2 expected) --"
unsquashfs -d stage/lower -f sqf/env1.sqf > stage/unsquashfs.log 2>&1
rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || { cat stage/unsquashfs.log; fail "unsquashfs failed unexpectedly (exit $rc)"; }
[ -f stage/lower/cnt_env/keep.txt ] || fail "extraction lost real payload"
[ ! -e stage/lower/etc/hostname ] || fail "unsquashfs unexpectedly created the device node"
pass "env1.sqf extracted; its own whiteout is (expectedly) absent from the plain extraction, same as a live union drops it"

echo "-- debugfs rdump env2.img's upper/ -> stage/upper (no mount) --"
mkdir -p stage/upper
debugfs -R "rdump upper stage/upper" img/env2.img > stage/rdump.log 2>&1
UPPER="stage/upper/upper"
[ -f "$UPPER/cnt_env/newfile.txt" ] || fail "rdump did not produce the new file"
[ -f "$UPPER/cnt_env/.wh.willdelete.txt" ] || fail "rdump did not produce the whiteout marker"
[ -f "$UPPER/etc/.wh.os-release" ] || fail "rdump did not produce the base-reaching whiteout marker"
pass "env2.img's delta extracted as plain files and .wh.<name> markers"

echo "== 3. what does env1.sqf's OWN archive already carry as a whiteout? =="
unsquashfs -lls -d "" sqf/env1.sqf | awk '/^c/{print $NF}' | sed 's#^/##' > stage/inherited.txt
cat stage/inherited.txt
pass "inherited whiteout found from the archive listing (same step as the mount-based route -- this part never touches a mount either way)"

echo "== 4. merge on disk (no live overlay to do it for us) =="
cp -a stage/lower/. stage/merged.tmp 2>/dev/null || { mkdir -p stage/merged.tmp; cp -a stage/lower/. stage/merged.tmp/; }
cp -a "$UPPER/." stage/merged.tmp/
find stage/merged.tmp -name '.wh.*' -not -name '.wh..wh..opq' | while read -r marker; do
  dir=$(dirname "$marker"); name=$(basename "$marker"); target="${name#.wh.}"
  rm -f "$dir/$target" "$marker"
done
mv stage/merged.tmp stage/merged
[ -f stage/merged/cnt_env/keep.txt ]     || fail "merge lost unchanged content"
[ -f stage/merged/cnt_env/newfile.txt ]  || fail "merge lost new content"
[ ! -e stage/merged/cnt_env/willdelete.txt ] || fail "merge did not apply the deletion"
[ ! -e stage/merged/etc/os-release ]     || fail "merge did not apply the base-reaching deletion"
pass "plain cp+rm reproduces the union: unchanged kept, new content kept, both deletions applied"

echo "== 5. pack -- entirely mount-free =="
{
  while read -r p; do [ -n "$p" ] && printf '%s c 0 0 0 0 0\n' "$p"; done < stage/inherited.txt
  printf 'cnt_env/willdelete.txt c 0 0 0 0 0\n'
  printf 'etc/os-release c 0 0 0 0 0\n'
} > stage/pseudo.txt
cat stage/pseudo.txt
mksquashfs stage/merged/cnt_env stage/merged/etc sqf/env3.sqf \
  -all-root -no-xattrs -keep-as-directory -pf stage/pseudo.txt -noappend -quiet
[ -f sqf/env3.sqf ] || fail "env3.sqf was not produced"
pass "packed env3.sqf via the rdump route -- no unshare, no squashfuse, no fuse2fs, no fuse-overlayfs anywhere in this step"

echo "-- env3.sqf contents --"
unsquashfs -lls -d "" sqf/env3.sqf

echo "== 6. run env3.sqf for real, against the same base =="
$CNT exec -o sqf/env3.sqf -q -- bash -euo pipefail -c '
  [ "$(cat /cnt_env/keep.txt)" = stage1-keep ]
  [ "$(cat /cnt_env/newfile.txt)" = stage2-new ]
  [ ! -e /cnt_env/willdelete.txt ]
  [ ! -e /etc/hostname ]
  [ ! -e /etc/os-release ]
' 2>&1 | quiet
pass "env3.sqf (rdump route) mounted against the real base reproduces the same combined state as the fuse route"

rm -rf stage
echo
echo "ALL PASS"
