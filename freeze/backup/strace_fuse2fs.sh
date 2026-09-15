#!/usr/bin/env bash
#
# strace_fuse2fs.sh — syscall counts for two fuse2fs builds reading the same
# ext3 image, to find where a wall-clock gap between them actually comes from.
#
# Builds one small ext3 image, then for each binary: unshare into a private
# root-mapped namespace, mount it in foreground under `strace -f -c`, run the
# same entry+hash walk freeze_bench.sh uses, unmount, and print the syscall
# summary strace wrote on exit. No Apptainer involved — mount mechanism is
# already known not to matter (img-host and img-host-bundled use the same
# host: mode); this isolates the binary.
#
#   ./strace_fuse2fs.sh -w /tmp/stracebench
#   ./strace_fuse2fs.sh -w /tmp/stracebench -a /path/to/one/fuse2fs -b /path/to/other/fuse2fs
#
# -w must be on a local filesystem, same reason as freeze_bench.sh's -w.
#
set -uo pipefail

WORK=""
N=5000
BIN_A=""
BIN_B=""

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

while getopts "w:n:a:b:h" opt; do
	case "$opt" in
	w) WORK="$OPTARG" ;;
	n) N="$OPTARG" ;;
	a) BIN_A="$OPTARG" ;;
	b) BIN_B="$OPTARG" ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

die() { printf 'strace_fuse2fs: %s\n' "$*" >&2; exit 1; }

[[ -n "$WORK" ]] || die "-w is required; point it at a directory on a local filesystem"
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd)"

FSTYPE="$(stat -f -c %T "$WORK")"
case "$FSTYPE" in
nfs | nfs4 | autofs | cifs | lustre | gpfs)
	die "$WORK is $FSTYPE; this measures local read cost, so it needs a local filesystem"
	;;
esac

for tool in mke2fs strace unshare mountpoint fusermount3; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

if [[ -z "$BIN_A" ]]; then
	LIBEXEC="$(apptainer buildcfg 2>/dev/null | sed -n 's/^LIBEXECDIR=//p')/apptainer/bin"
	BIN_A="$LIBEXEC/fuse2fs"
fi
[[ -z "$BIN_B" ]] && BIN_B="$(command -v fuse2fs 2>/dev/null || true)"
[[ -x "$BIN_A" ]] || die "no fuse2fs at $BIN_A (-a names another)"
[[ -x "$BIN_B" ]] || die "no fuse2fs on PATH (-b names another)"

TREE="$WORK/tree"
IMG="$WORK/env.img"
rm -rf "$TREE" "$IMG"
mkdir -p "$TREE"
for ((i = 0; i < N; i++)); do
	sub="$TREE/d$((i / 100))"
	[[ -d "$sub" ]] || mkdir -p "$sub"
	head -c 4096 /dev/urandom >"$sub/f$i"
done
BYTES="$(du -sb "$TREE" | cut -f1)"
MB=$((BYTES / 1048576 + N / 250 + 16))
mke2fs -q -t ext3 -F -d "$TREE" "$IMG" "${MB}M" >/dev/null 2>&1 ||
	die "mke2fs could not build a ${MB}M image for $N files"

WALK_TAIL='find . -mindepth 1 -printf "E\0%y\0%m\0%p\0%l\0" >/dev/null
find . -mindepth 1 -type f -print0 | xargs -0 -r sha256sum -z >/dev/null
find . -mindepth 1 \( -type c -o -type b \) -print0 |
	xargs -0 -r stat --printf="D\0%n\0%t\0%T\0" >/dev/null'

run() { # run <label> <binary>
	local label="$1" bin="$2" mnt out
	mnt="$(mktemp -d)"
	out="$(mktemp)"
	unshare --user --map-root-user --mount -- bash -c '
		set -o pipefail
		strace -f -c -o "$1" -- "$0" -f -o ro "$2" "$3" &
		fusepid=$!
		for _ in $(seq 1 200); do mountpoint -q "$3" && break; sleep 0.1; done
		mountpoint -q "$3" || { echo "$0: mount timed out" >&2; exit 1; }
		cd "$3" || exit 1
		'"$WALK_TAIL"'
		cd /
		fusermount3 -u "$3" 2>/dev/null
		wait "$fusepid" 2>/dev/null
	' "$bin" "$out" "$IMG" "$mnt"
	printf '\n=== %s: %s ===\n' "$label" "$bin"
	cat "$out"
	rm -rf "$mnt" "$out"
}

printf 'work  %s (%s)\nimg   %s (%s files, %s MB)\n' "$WORK" "$FSTYPE" "$IMG" "$N" "$MB"

run bundled "$BIN_A"
run path "$BIN_B"
