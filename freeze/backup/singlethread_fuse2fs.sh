#!/usr/bin/env bash
#
# singlethread_fuse2fs.sh — times two fuse2fs builds, each with and without -s
# (single-threaded), reading the same ext3 image. strace_fuse2fs.sh's per-call
# syscall costs came back nearly identical between builds, so if a gap between
# them is thread/lock contention rather than raw I/O cost, -s should collapse
# it; if the gap survives -s on both, threading is not the cause.
#
#   ./singlethread_fuse2fs.sh -w /tmp/stbench
#   ./singlethread_fuse2fs.sh -w /tmp/stbench -a /path/to/one/fuse2fs -b /path/to/other/fuse2fs
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

die() { printf 'singlethread_fuse2fs: %s\n' "$*" >&2; exit 1; }

[[ -n "$WORK" ]] || die "-w is required; point it at a directory on a local filesystem"
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd)"

FSTYPE="$(stat -f -c %T "$WORK")"
case "$FSTYPE" in
nfs | nfs4 | autofs | cifs | lustre | gpfs)
	die "$WORK is $FSTYPE; this measures local read cost, so it needs a local filesystem"
	;;
esac

for tool in mke2fs unshare mountpoint fusermount3; do
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

now() { date +%s%N; }
elapsed() { awk -v ns="$(($(now) - $1))" 'BEGIN { printf "%.3f", ns / 1000000000 }'; }

run() { # run <label> <binary> <extra-flags>
	local label="$1" bin="$2" extra="$3" mnt start t
	mnt="$(mktemp -d)"
	start=$(now)
	unshare --user --map-root-user --mount -- bash -c '
		set -o pipefail
		"$0" -f '"$extra"' -o ro "$1" "$2" &
		fusepid=$!
		for _ in $(seq 1 200); do mountpoint -q "$2" && break; sleep 0.1; done
		mountpoint -q "$2" || { echo "$0: mount timed out" >&2; exit 1; }
		cd "$2" || exit 1
		'"$WALK_TAIL"'
		cd /
		fusermount3 -u "$2" 2>/dev/null
		wait "$fusepid" 2>/dev/null
	' "$bin" "$IMG" "$mnt"
	t=$(elapsed "$start")
	printf '  %-8s %-8s %-40s  %8ss\n' "$label" "${extra:-default}" "$bin" "$t"
	rm -rf "$mnt"
}

printf 'work  %s (%s)\nimg   %s (%s files, %s MB)\n\n' "$WORK" "$FSTYPE" "$IMG" "$N" "$MB"

run bundled "$BIN_A" ""
run bundled "$BIN_A" "-s"
run path "$BIN_B" ""
run path "$BIN_B" "-s"
