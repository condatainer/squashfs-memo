#!/usr/bin/env bash
#
# procs_bench.sh — mksquashfs pack time and peak RSS, per algorithm/level and
# -processors count, on real payloads. Packing only: no read, no random
# access, no exec. Writes procs_bench.csv.
#
#   --entry NAME=PATH   add PATH as a source for dataset NAME. Repeatable
#                       with the same NAME to give one dataset several
#                       sources.
#
# A PATH ending in .sqf is unsquashfs'd first, into /tmp or --work depending
# on its inode count and size (--tmp-inode-threshold, --tmp-size-threshold);
# anything else is packed as given.
#
#   ./procs_bench.sh --work tmp/procs-bench --procs 8 \
#     --entry genome-fasta=/path/to/genome.fa
#
set -uo pipefail

OUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=""
PROCS=4
COMBOS="lz4 gzip:1 gzip:6 gzip:9 zstd:1 zstd:8 zstd:14 zstd:19" # lz4 gzip:1 gzip:6 gzip:9 zstd:1 zstd:8 zstd:14 zstd:19 zstd:22
KEEP=0
TMP_INODE_THRESHOLD=50000
TMP_SIZE_THRESHOLD=$((2 * 1024 * 1024 * 1024))
NAMES=()
declare -A PATHS
EXTRACT_TMP_DIRS=()

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

die() { printf 'procs_bench: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	--work) WORK="$2"; shift 2 ;;
	--outdir) OUTDIR="$2"; shift 2 ;;
	--procs) PROCS="$2"; shift 2 ;;
	--combos) COMBOS="$2"; shift 2 ;;
	--tmp-inode-threshold) TMP_INODE_THRESHOLD="$2"; shift 2 ;;
	--tmp-size-threshold) TMP_SIZE_THRESHOLD="$2"; shift 2 ;;
	--keep) KEEP=1; shift ;;
	--entry)
		kv="$2"; shift 2
		name="${kv%%=*}"
		path="${kv#*=}"
		[[ "$kv" == *=* && -n "$name" && -n "$path" ]] || die "--entry needs NAME=PATH, got '$kv'"
		if [[ -z "${PATHS[$name]+x}" ]]; then
			NAMES+=("$name")
			PATHS[$name]="$path"
		else
			PATHS[$name]+=" $path"
		fi
		;;
	-h | --help) usage 0 ;;
	*) usage 1 ;;
	esac
done

[[ -n "$WORK" ]] || die "--work is required"
[[ ${#NAMES[@]} -gt 0 ]] || die "at least one --entry NAME=PATH is required"
mkdir -p "$WORK" "$OUTDIR" || die "cannot create $WORK or $OUTDIR"
WORK="$(cd "$WORK" && pwd)"
FSTYPE="$(stat -f -c %T "$WORK")"

for tool in mksquashfs unsquashfs /usr/bin/time; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

CCSV="$OUTDIR/procs_bench.csv"
# Header only on first write, so repeated runs against the same --outdir
# (e.g. one call per dataset x procs pair) append rather than each wiping
# the last.
[[ -f "$CCSV" ]] || printf 'dataset,algo,level,seconds,size_bytes,source_bytes,ratio_pct,peak_rss_kb,procs\n' >"$CCSV"

# sqf_extract_root picks where one .sqf gets extracted to, from its own
# superblock (read with `unsquashfs -stat`, no data touched) — see the header
# for the two rules and why.
sqf_extract_root() {
	local p="$1" info inodes size
	info="$(unsquashfs -stat "$p" 2>/dev/null)"
	inodes="$(awk '/^Number of inodes/ {print $NF}' <<<"$info")"
	size="$(awk '/^Filesystem size/ {print $3}' <<<"$info")"
	if [[ -n "$inodes" && -n "$size" ]] &&
		((inodes > TMP_INODE_THRESHOLD && size < TMP_SIZE_THRESHOLD)); then
		echo "${TMPDIR:-/tmp}/procs-bench"
	else
		echo "$WORK/src"
	fi
}

# resolve_sources turns one dataset's raw --entry paths into what mksquashfs
# should read: a .sqf is unsquashfs'd once (mksquashfs cannot read inside one
# directly), into whichever root sqf_extract_root picks; anything else is
# used in place.
resolve_sources() {
	local name="$1" p resolved=()
	local i=0
	for p in ${PATHS[$name]}; do
		[[ -e "$p" ]] || die "$name: no such path $p"
		if [[ "$p" == *.sqf ]]; then
			local root dir
			root="$(sqf_extract_root "$p")"
			dir="$root/$name-$i"
			if [[ ! -d "$dir" ]]; then
				mkdir -p "$dir"
				printf '  %s: decompressing %s ...\n' "$name" "$p"
				unsquashfs -q -no-progress -no-xattrs -f -d "$dir" "$p" >/dev/null 2>&1 ||
					die "unsquashfs failed for $name ($p)"
				[[ "$root" == "$WORK/src" ]] || EXTRACT_TMP_DIRS+=("$dir")
			fi
			resolved+=("$dir")
		else
			resolved+=("$p")
		fi
		((i++))
	done
	echo "${resolved[*]}"
}

now() { date +%s%N; }
elapsed() { awk -v ns="$(($(now) - $1))" 'BEGIN { printf "%.3f", ns / 1000000000 }'; }

crow() { # crow <dataset> <algo> <level> <seconds> <size> <source_bytes> <rss_kb>
	local ratio
	ratio="$(awk -v a="$5" -v b="$6" 'BEGIN { printf "%.1f", (b > 0) ? a / b * 100 : 0 }')"
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$ratio" "$7" "$PROCS" >>"$CCSV"
	printf '  pack %-20s %-5s %-3s %8ss  %10s  %5s%%  %10s KB\n' "$1" "$2" "${3:--}" "$4" "$5" "$ratio" "$7"
}

printf 'work    %s (%s)\nprocs   %s\ncombos  %s\ndatasets %s\n\n' \
	"$WORK" "$FSTYPE" "$PROCS" "$COMBOS" "${NAMES[*]}"

for name in "${NAMES[@]}"; do
	src="$(resolve_sources "$name")"
	source_bytes=0
	for s in $src; do
		if [[ -d "$s" ]]; then
			source_bytes=$((source_bytes + $(du -sb "$s" | cut -f1)))
		else
			source_bytes=$((source_bytes + $(stat -c%s "$s")))
		fi
	done
	printf '%s: %s bytes\n' "$name" "$source_bytes"

	for combo in $COMBOS; do
		algo="${combo%%:*}"
		level=""
		extra="-comp $algo"
		[[ "$combo" == *:* ]] && level="${combo#*:}" && extra="-comp $algo -Xcompression-level $level"

		out="$WORK/out/$name-$algo${level:+-$level}.sqf"
		mkdir -p "$(dirname "$out")"
		tlog="$WORK/tlog"
		printf '  %s: packing %s%s ...\n' "$name" "$algo" "${level:+:$level}"
		start=$(now)
		# shellcheck disable=SC2086
		/usr/bin/time -f '%M' -o "$tlog" \
			mksquashfs $src "$out" -processors "$PROCS" -keep-as-directory \
			-quiet -no-progress -noappend $extra >/dev/null 2>&1 ||
			die "mksquashfs failed for $name $combo"
		seconds="$(elapsed "$start")"
		size="$(stat -c%s "$out")"
		rss="$(cat "$tlog" 2>/dev/null || echo 0)"
		crow "$name" "$algo" "$level" "$seconds" "$size" "$source_bytes" "$rss"

		((KEEP)) || rm -f "$out"
	done
done

if ((KEEP)); then
	:
else
	rm -rf "$WORK/src"
	((${#EXTRACT_TMP_DIRS[@]})) && rm -rf "${EXTRACT_TMP_DIRS[@]}"
fi
printf '\nwrote %s\n' "$CCSV"
