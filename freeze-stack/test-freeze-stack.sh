#!/bin/bash
# Proves the mechanism behind a not-yet-built feature: mount a fresh env2.img
# live on top of an already-frozen env1.sqf, edit it, then "freeze again" into
# a self-contained env3.sqf that carries both what env2.img added and what it
# deleted -- from its own content and from env1.sqf's.
#
# Nothing here changes condatainer: `overlay freeze` doesn't know how to pack a
# stacked source, and mounting env.sqf + env.img together is refused today
# (both claim /cnt_env). Stage 2 below drives apptainer directly to get past
# that refusal, and stage 3 drives the same fuse2fs/squashfuse/fuse-overlayfs/
# mksquashfs tools freeze already uses, unprivileged, via the same unshare
# --map-root-user trick. A failure here is a fact about the mechanism, not
# about missing Go code.
set -uo pipefail

CNT=${CNT:-condatainer}
BASE="${BASE:?BASE=/path/to/base.sqf is required}"
WORK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$WORK"
rm -rf img sqf
mkdir -p img sqf

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
quiet() { grep -vE '^WARNING: While bind mounting|^INFO:    Ignoring invalid max threads|^WARNING: group: unknown' || true; }

# stop_pid is inlined into every unshare script below (a subshell cannot see a
# function from its parent). TERM alone was seen to leave squashfuse alive
# under this harness's backgrounding for reasons not tracked down, so this
# escalates to KILL after a short grace period rather than trusting one signal.
STOP_PID_FN='stop_pid() {
  kill "$1" 2>/dev/null || true
  for i in $(seq 1 20); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  kill -9 "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}'

[ -f "$BASE" ] || fail "base image not found: $BASE (pass BASE=/path/to/base.sqf)"
for t in apptainer debugfs unsquashfs mksquashfs squashfuse fuse2fs fuse-overlayfs unshare; do
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

$CNT exec -o sqf/env1.sqf -q -- bash -euo pipefail -c '
  [ "$(cat /cnt_env/keep.txt)" = stage1-keep ]
  [ "$(cat /cnt_env/willdelete.txt)" = stage1-delete-me ]
  [ ! -e /etc/hostname ]
' 2>&1 | quiet
pass "env1.sqf carries its own payload and its own whiteout"

echo "== 1. mount env1.sqf(ro) + a fresh env2.img(rw) together, live =="
$CNT overlay create img/env2.img -s 200M -p small -S -q
apptainer exec \
  --overlay "$WORK/sqf/env1.sqf:ro" \
  --overlay "$WORK/img/env2.img:rw" \
  "$BASE" bash -euo pipefail -c '
    [ "$(cat /cnt_env/keep.txt)" = stage1-keep ]
    [ "$(cat /cnt_env/willdelete.txt)" = stage1-delete-me ]
    [ ! -e /etc/hostname ]
  ' 2>&1 | quiet
pass "env1.sqf content is visible through the stack (no opaque /cnt_env problem)"

apptainer exec \
  --overlay "$WORK/sqf/env1.sqf:ro" \
  --overlay "$WORK/img/env2.img:rw" \
  "$BASE" bash -euo pipefail -c '
    echo stage2-new > /cnt_env/newfile.txt   # add
    rm /cnt_env/willdelete.txt               # delete something env1.sqf itself provided
    rm /etc/os-release                       # delete something only the base provides
    [ -f /cnt_env/newfile.txt ]
    [ ! -e /cnt_env/willdelete.txt ]
    [ ! -e /etc/os-release ]
  ' 2>&1 | quiet
pass "additions and both kinds of deletion land correctly in env2.img"

echo "== 2. inspect env2.img's raw upper/ -- what did it actually delete? =="
MARKERS=$(debugfs -R "ls -p upper/cnt_env" img/env2.img 2>/dev/null; debugfs -R "ls -p upper/etc" img/env2.img 2>/dev/null)
echo "$MARKERS" | grep -q '\.wh\.willdelete\.txt' || fail "expected .wh.willdelete.txt marker not found"
echo "$MARKERS" | grep -q '\.wh\.os-release' || fail "expected .wh.os-release marker not found"
pass "both deletions show up as .wh.<name> markers in the raw ext3 upper/ (no mount needed to find them)"

echo "== 3. does env1.sqf's OWN whiteout survive a live overlay union, for free? =="
# This is the one surprise this experiment exists to catch: a char 0:0 device
# node sitting in the LOWER layer of a fuse-overlayfs union is not exposed as
# an ordinary device node -- fuse-overlayfs recognizes the kernel whiteout
# convention on read in any layer, not just the upper one it writes, and
# swallows the entry instead of passing it through. So "mount env1.sqf+env2.img
# and read the merged view" is NOT a free way to carry an inherited whiteout;
# it must be found and re-injected explicitly, exactly like a new one.
STAGE=$(mktemp -d)
mkdir -p "$STAGE/mnt_sqf"
export WORK STAGE STOP_PID_FN
cat > "$STAGE/probe.sh" <<'INNER'
set -euo pipefail
eval "$STOP_PID_FN"
squashfuse -f "$WORK/sqf/env1.sqf" "$STAGE/mnt_sqf" &
p1=$!
for i in $(seq 1 50); do grep -qF " $STAGE/mnt_sqf " /proc/mounts && break; sleep 0.1; done
# ls, not stat/[ -e ]: those were observed to hang indefinitely against a
# device-node inode read through squashfuse inside this mount+user namespace,
# while a directory listing (readdir+getattr) reads the same inode type fine.
ls "$STAGE/mnt_sqf/etc" > "$STAGE/probe.out"
stop_pid $p1
INNER
rm -f "$STAGE/probe.out"
unshare --mount --user --map-root-user -- /bin/bash "$STAGE/probe.sh" > "$STAGE/probe.log" 2>&1
grep -q hostname "$STAGE/probe.out" 2>/dev/null || fail "a bare squashfuse mount of env1.sqf should list the device node directly: $(cat "$STAGE/probe.log")"
pass "env1.sqf's existing char 0:0 node is real and visible on its own (confirms the source, not a measurement artifact)"

echo "== 4. what does the base itself already have, of what env1.sqf's archive records as a whiteout? =="
unsquashfs -lls -d "" sqf/env1.sqf | grep '^c' | awk '{print $NF}' | sed 's#^/##' > "$STAGE/inherited.txt"
cat "$STAGE/inherited.txt"
pass "existing whiteouts enumerated straight from env1.sqf's own listing (unsquashfs -lls, no mount)"

echo "== 5. freeze env2.img (stacked on env1.sqf) into a self-contained env3.sqf =="
mkdir -p "$STAGE/mnt_img" "$STAGE/mnt_merged"
{
  while read -r p; do printf '%s c 0 0 0 0 0\n' "$p"; done < "$STAGE/inherited.txt"
  printf 'cnt_env/willdelete.txt c 0 0 0 0 0\n'
  printf 'etc/os-release c 0 0 0 0 0\n'
} > "$STAGE/pseudo.txt"
echo "-- pseudo-file definitions for the merged pack --"
cat "$STAGE/pseudo.txt"

cat > "$STAGE/combine.sh" <<'INNER'
set -euo pipefail
eval "$STOP_PID_FN"
squashfuse -f "$WORK/sqf/env1.sqf" "$STAGE/mnt_sqf" &
p1=$!
for i in $(seq 1 50); do grep -qF " $STAGE/mnt_sqf " /proc/mounts && break; sleep 0.1; done
grep -qF " $STAGE/mnt_sqf " /proc/mounts || { echo "squashfuse mount never appeared" >&2; exit 1; }

fuse2fs -f "$WORK/img/env2.img" "$STAGE/mnt_img" &
p2=$!
for i in $(seq 1 50); do grep -qF " $STAGE/mnt_img " /proc/mounts && break; sleep 0.1; done
grep -qF " $STAGE/mnt_img " /proc/mounts || { echo "fuse2fs mount never appeared" >&2; exit 1; }

fuse-overlayfs -f -o lowerdir="$STAGE/mnt_sqf",upperdir="$STAGE/mnt_img/upper",workdir="$STAGE/mnt_img/work" "$STAGE/mnt_merged" &
p3=$!
for i in $(seq 1 50); do grep -qF " $STAGE/mnt_merged " /proc/mounts && break; sleep 0.1; done
grep -qF " $STAGE/mnt_merged " /proc/mounts || { echo "fuse-overlayfs mount never appeared" >&2; exit 1; }

mksquashfs "$STAGE/mnt_merged/cnt_env" "$STAGE/mnt_merged/etc" "$WORK/sqf/env3.sqf" \
  -all-root -no-xattrs -keep-as-directory -pf "$STAGE/pseudo.txt" -noappend -quiet
rc=$?

stop_pid $p3
stop_pid $p2
stop_pid $p1
exit $rc
INNER
unshare --mount --user --map-root-user -- /bin/bash "$STAGE/combine.sh" > "$STAGE/combine.log" 2>&1
cat "$STAGE/combine.log" | quiet
[ -f sqf/env3.sqf ] || fail "env3.sqf was not produced"
pass "packed env3.sqf from the live env1.sqf+env2.img union, plus injected whiteouts"

echo "-- env3.sqf contents --"
unsquashfs -lls -d "" sqf/env3.sqf

echo "== 6. run env3.sqf for real, against the same base =="
$CNT exec -o sqf/env3.sqf -q -- bash -euo pipefail -c '
  [ "$(cat /cnt_env/keep.txt)" = stage1-keep ]        # unchanged content, from env1.sqf
  [ "$(cat /cnt_env/newfile.txt)" = stage2-new ]      # new content, from env2.img
  [ ! -e /cnt_env/willdelete.txt ]                    # deleted content that was env1.sqf'"'"'s own
  [ ! -e /etc/hostname ]                              # inherited whiteout, from env1.sqf
  [ ! -e /etc/os-release ]                            # new whiteout, reaching the base
' 2>&1 | quiet
pass "env3.sqf mounted against the real base reproduces exactly the combined state: additions kept, both kinds of deletion still hidden"

rm -rf "$STAGE"
echo
echo "ALL PASS"
