#!/usr/bin/env bash
#
# compare.sh — times build.sh's v1.47.4 and v1.47.1 builds reading the same
# ext3 image, same unshare + mount + walk harness as
# ../singlethread_fuse2fs.sh. Found automatically under the same -w build.sh
# was run with; -t label=path adds another binary if you want one.
#
#   ./compare.sh -w /tmp/version-bench
#
# -w must be on a local filesystem, same reason as freeze_bench.sh's -w.
#
set -uo pipefail

WORK=""
N=5000
declare -a LABELS=()
declare -a BINS=()

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

while getopts "w:n:t:h" opt; do
	case "$opt" in
	w) WORK="$OPTARG" ;;
	n) N="$OPTARG" ;;
	t)
		LABELS+=("${OPTARG%%=*}")
		BINS+=("${OPTARG#*=}")
		;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

die() { printf 'compare: %s\n' "$*" >&2; exit 1; }

[[ -n "$WORK" ]] || die "-w is required; point it at a directory on a local filesystem"
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd)"

# build.sh's two builds, found by their fixed layout under the same -w.
for version in v1.47.4 v1.47.1; do
	bin="$(find "$WORK/build-$version" -type f -name fuse2fs -perm -u+x 2>/dev/null | head -n1)"
	[[ -n "$bin" ]] || continue
	LABELS+=("$version")
	BINS+=("$bin")
done
[[ ${#BINS[@]} -ge 1 ]] ||
	die "no build.sh output under $WORK, and no -t label=path given; run build.sh -w $WORK first, or pass -t"

FSTYPE="$(stat -f -c %T "$WORK")"
case "$FSTYPE" in
nfs | nfs4 | autofs | cifs | lustre | gpfs)
	die "$WORK is $FSTYPE; this measures local read cost, so it needs a local filesystem"
	;;
esac

for tool in mke2fs unshare mountpoint fusermount3; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
for i in "${!BINS[@]}"; do
	[[ -x "${BINS[$i]}" ]] || die "${LABELS[$i]}: no executable at ${BINS[$i]}"
done

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

run() { # run <label> <binary>
	local label="$1" bin="$2" mnt start t
	mnt="$(mktemp -d)"
	start=$(now)
	unshare --user --map-root-user --mount -- bash -c '
		set -o pipefail
		"$0" -f -o ro "$1" "$2" &
		fusepid=$!
		for _ in $(seq 1 200); do mountpoint -q "$2" && break; sleep 0.1; done
		mountpoint -q "$2" || { echo "$0: mount timed out" >&2; exit 1; }
		cd "$2" || exit 1
		'"$WALK_TAIL"'
		cd /
		fusermount3 -u "$2" 2>/dev/null
		wait "$fusepid" 2>/dev/null
	' "$bin" "$IMG" "$mnt" >/dev/null 2>&1
	t=$(elapsed "$start")
	printf '  %-16s %-50s  %8ss\n' "$label" "$bin" "$t"
	rm -rf "$mnt"
}

printf 'work  %s (%s)\nimg   %s (%s files, %s MB)\n\n' "$WORK" "$FSTYPE" "$IMG" "$N" "$MB"

for i in "${!BINS[@]}"; do
	run "${LABELS[$i]}" "${BINS[$i]}"
done
