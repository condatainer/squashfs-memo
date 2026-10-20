#!/bin/bash
# Mount an ext3 image with each fuse2fs built by build.sh and overwrite files by truncating opens.
# Run inside a user namespace where root mounts /dev/fuse directly, after ./build.sh:
#   apptainer exec --fakeroot --bind <dir containing this script> <image with e2fsprogs> bash compare.sh
#   ./compare.sh                 every binary in work/bin
# Output: a table on stdout and work/results-<job id or pid>.tsv
set -u
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
WORK=${WORK:-$HERE/work}
BIN=$WORK/bin
for tool in mke2fs debugfs; do command -v $tool >/dev/null || { echo "$tool is required" >&2; exit 1; }; done
[ -d "$BIN" ] || { echo "run ./build.sh first" >&2; exit 1; }

N=6
RUN=${SLURM_JOB_ID:-$$}   # every run has its own images, mount points and results file, so runs can overlap
TSV=$WORK/results-$RUN.tsv
printf 'variant\tversion\tlibfuse\tin-session\ton-disk\tverdict\n' > "$TSV"

# sizes <dir-listing-name-prefix> -> distinct sizes of files whose name starts with the prefix
group_sizes() { awk -v p="$1" '$2 ~ "^"p {print $1}' | sort -un | tr '\n' ',' | sed 's/,$//'; }

run_case() {   # run_case <label> <fuse2fs binary>
  local label=$1 bin=$2 img="$WORK/t-$RUN-$1.img" mnt="$WORK/m-$RUN-$1"
  local ver lib
  ver=$("$bin" --version 2>&1 | sed -n 's/^fuse2fs //p' | head -1)
  lib=$(ldd "$bin" 2>/dev/null | grep -oE 'libfuse3?\.so[.0-9]*' | head -1)
  rm -rf "$img" "$mnt"; mkdir -p "$mnt"
  truncate -s 128M "$img"; mke2fs -q -t ext3 -F "$img"
  if ! "$bin" "$img" "$mnt" 2> "$WORK/m-$RUN-$label.err"; then
    printf '%s\t%s\t%s\t-\t-\tMOUNT FAILED\n' "$label" "$ver" "$lib" >> "$TSV"; return
  fi
  local t=$mnt/t; mkdir -p "$t"
  head -c 1058 /dev/zero | tr '\0' L > "$t/small"
  for i in $(seq $N); do
    head -c 62383 /dev/urandom > "$t/sh$i"; cat "$t/small" > "$t/sh$i"            # open(O_TRUNC) by shell
    head -c 62383 /dev/urandom > "$t/cp$i"; cp "$t/small" "$t/cp$i"               # open(O_TRUNC) by cp
    head -c 62383 /dev/urandom > "$t/zr$i"; : > "$t/zr$i"                          # open(O_TRUNC), no write
    head -c 62383 /dev/urandom > "$t/ft$i"; truncate -s 1058 "$t/ft$i"            # ftruncate, no O_TRUNC
  done
  sync; sleep 2
  local ins
  ins=$(cd "$t" && stat -c '%s %n' sh* cp* zr* ft*)
  umount "$mnt"; sleep 1
  local dsk
  dsk=$(debugfs -R 'ls -l /t' "$img" 2>/dev/null | awk 'NF>=7 {print $6, $NF}')
  fmt() { printf 'sh=%s cp=%s zr=%s ft=%s' "$(echo "$1" | group_sizes sh)" "$(echo "$1" | group_sizes cp)" \
                                          "$(echo "$1" | group_sizes zr)" "$(echo "$1" | group_sizes ft)"; }
  local a b verdict
  a=$(fmt "$ins"); b=$(fmt "$dsk")
  want='sh=1058 cp=1058 zr=0 ft=1058'
  if [ "$a" = "$want" ] && [ "$b" = "$want" ]; then verdict=OK
  elif [ "$b" = "$want" ]; then verdict="OK (in-session differs)"
  else verdict=TRUNCATE-LOST; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$ver" "$lib" "$a" "$b" "$verdict" >> "$TSV"
  rm -rf "$img" "$mnt"
}

for b in "$BIN"/fuse2fs-*; do [ -x "$b" ] && run_case "$(basename "$b" | sed 's/^fuse2fs-//')" "$b"; done

column -t -s $'\t' "$TSV"
