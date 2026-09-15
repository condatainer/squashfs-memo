#!/bin/bash
# Manual end-to-end whiteout test: does a real apptainer-mounted deletion
# actually survive freeze -> run -> unfreeze -> run?
#
# Two cases:
#   A. a single file deleted (plain whiteout: char-dev 0:0 or .wh.<name>)
#   B. a whole base directory replaced (opaque: needs BaseDirLister against
#      the real base to know what the directory used to hold)
set -euo pipefail

CNT=${CNT:-condatainer}
WORK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$WORK"
rm -rf img sqf2 img2
mkdir -p img sqf2 img2

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

echo "== 0. create the overlay =="
$CNT overlay create img/env.img -s 300M -p small -S

echo "== 1. write files, then delete some, in the live overlay =="
$CNT exec -w -o img/env.img -- bash -euo pipefail -c '
  mkdir -p /cnt_env/keep
  echo hi > /cnt_env/keep/file.txt
  echo bye > /etc/hostname                 # case A: delete a base file
  rm /etc/hostname
  ls /etc/logrotate.d > /tmp/before.txt    # case B: replace a base dir wholesale
  rm -rf /etc/logrotate.d
  mkdir /etc/logrotate.d
  echo mine > /etc/logrotate.d/mine.conf
'

echo "== 2. confirm the deletions are visible right now, pre-freeze =="
$CNT exec -w -o img/env.img -- bash -euo pipefail -c '
  [ ! -e /etc/hostname ] || { echo "hostname still there" >&2; exit 1; }
  [ "$(ls /etc/logrotate.d)" = "mine.conf" ] || { echo "logrotate.d not replaced" >&2; exit 1; }
'
pass "deletions visible before freeze"

echo "== 3. freeze =="
$CNT overlay freeze img/env.img sqf2/env.sqf

echo "== 4. run the frozen artifact, check the deletions held =="
$CNT exec -o sqf2/env.sqf -- bash -euo pipefail -c '
  [ -f /cnt_env/keep/file.txt ] || { echo "payload missing" >&2; exit 1; }
  [ ! -e /etc/hostname ] || { echo "hostname came back after freeze" >&2; exit 1; }
  [ "$(ls /etc/logrotate.d)" = "mine.conf" ] || { echo "logrotate.d not opaque after freeze: $(ls /etc/logrotate.d)" >&2; exit 1; }
'
pass "deletions survived freeze"

echo "== 5. unfreeze back to an .img =="
$CNT overlay unfreeze sqf2/env.sqf img2/env.img

echo "== 6. run the rebuilt .img, check the deletions still hold =="
$CNT exec -w -o img2/env.img -- bash -euo pipefail -c '
  [ -f /cnt_env/keep/file.txt ] || { echo "payload missing after unfreeze" >&2; exit 1; }
  [ ! -e /etc/hostname ] || { echo "hostname came back after unfreeze" >&2; exit 1; }
  [ "$(ls /etc/logrotate.d)" = "mine.conf" ] || { echo "logrotate.d not opaque after unfreeze: $(ls /etc/logrotate.d)" >&2; exit 1; }
'
pass "deletions survived the full round trip: img -> sqf -> img"

echo
echo "ALL PASS"
