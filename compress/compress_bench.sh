#!/usr/bin/env bash
#
# compress_bench.sh — compression ratio, mksquashfs memory cost, and read
# speed, across algorithms and levels, on real payloads rather than one
# synthetic tree. Writes compress_bench.csv and read_bench.csv. Replaces
# squash_bench.sh/.csv/.png, which timed only pack time and size, for one
# real dataset (Cellranger).
#
# Every dataset is given on the command line, not baked in — this only
# records the shape of what was tried, not where it lives on any one machine:
#
#   --entry NAME=PATH   add PATH as a source for dataset NAME. Repeatable
#                       with the same NAME to give one dataset several
#                       sources (e.g. a STAR build's Genome and SAindex
#                       files, packed together as one archive).
#
# A PATH ending in .sqf is unsquashfs'd once first — mksquashfs cannot read
# inside one directly — and the extracted tree is packed instead; any other
# file or directory is packed as given. Datasets run in the order their first
# --entry appeared.
#
# Where a .sqf gets extracted depends on its own superblock, read with
# `unsquashfs -stat` before extraction:
#
#   many inodes, small archive   /tmp (or $TMPDIR) — a packed conda env is
#                                 thousands of small files, and --work is
#                                 often a filesystem charged per inode; /tmp
#                                 rarely is.
#   few inodes, large archive    --work — a genome or index is one or a few
#                                 huge files, and /tmp is rarely sized for
#                                 that much data.
#   anything else                --work, same as before this distinction
#                                 existed.
#
#   --tmp-inode-threshold N      inode count above which the "many inodes"
#                                 rule applies (default 50000).
#   --tmp-size-threshold BYTES   archive size below which the "small archive"
#                                 rule applies (default 2147483648, 2 GiB).
#
# For each dataset × combo, mksquashfs runs once and /usr/bin/time captures
# elapsed seconds and peak RSS alongside the archive it produces. The archive
# is then read before it is discarded, twice per mode. Every read — sequential
# or random — also runs squashfuse_ll in the foreground under /usr/bin/time,
# so read_bench.csv's peak_rss_kb is the mount+read process's own footprint,
# not just the pack side's:
#
#   cold  drop_caches attempted first, so the .sqf is read from storage.
#         Labelled cold-unverified when drop_caches isn't permitted (needs
#         root) — the number is still a first read, just not provably cold.
#   warm  read immediately again, benefiting from whatever page cache the
#         first read left behind.
#
# Two read modes:
#
#   sequential  every file, start to end — always run.
#   random      --random-reads fixed-size reads at scattered offsets, timed
#               together — only for datasets given --random. A full
#               sequential read says how fast the archive streams; it says
#               nothing about a seek-heavy access pattern (a genome index
#               queried by coordinate, not read front to back), which is
#               what --random is for:
#
#   --random NAME        scatter offsets across every regular file under that
#                        dataset's sources, walked recursively and weighted
#                        by size — the whole tree is the candidate pool, not
#                        a subset of it, since real access can land on any
#                        file in an environment, not just the largest ones.
#                        A synthetic random-I/O proxy, not driven by any real
#                        query.
#   --random NAME=FAI     scatter offsets using a samtools-style .fai index:
#                        pick a sequence (weighted by length), a position
#                        within it, and convert to a byte offset the same way
#                        `samtools faidx` would. FAI must index the one file
#                        in NAME's --entry list that the offsets apply to.
#
# Offsets are drawn once per dataset, before any combo, and reused for every
# combo's random read — otherwise a faster algorithm could just as well have
# drawn an easier set of offsets, and the comparison would mean nothing.
#
# A third, separate measurement — exec_bench.csv — is for datasets that are a
# program rather than data: --random's synthetic offsets don't resemble how a
# program is actually loaded (a dynamic linker resolving shared libraries, a
# Python import walking sys.path, a JVM reading a jar's central directory).
# --exec instead runs the real thing:
#
#   --exec NAME=CMD      after mounting, run CMD (a path relative to that
#                        dataset's single source, plus any arguments, e.g.
#                        "bin/samtools --version") inside the mount, under
#                        /usr/bin/time. Only meaningful for a dataset packed
#                        from exactly one source.
#   --exec-runs N        run CMD N times per combo (default 10) and report
#                        the min and median seconds and the peak RSS across
#                        them. There is no cold/warm pair here: on this HPC,
#                        drop_caches never actually works, and the archive was
#                        just written by mksquashfs moments earlier anyway —
#                        the "cold" row was never colder than "warm" to begin
#                        with. N repeats and a min/median instead absorbs
#                        scheduling noise, the way `hyperfine` would.
#
# The read mounts the archive itself with squashfuse_ll, wrapped in
# `unshare --user --map-root-user --mount` so the mount and the read run in
# one unprivileged user+mount namespace — no Apptainer, no base image. A bare
# squashfuse_ll fails unprivileged wherever fusermount's setuid escalation is
# blocked (e.g. NoNewPrivs=1); unshare gets the same namespace root Apptainer
# itself uses internally, without needing a container to run one in.
#
# Unlike freeze_bench.sh, --work is not required to be local: the compression
# pass only measures mksquashfs's own CPU and memory cost, which a network
# filesystem does not change, and a real build's .sqf usually lands on one
# anyway (Lustre and friends); the read pass measures the .sqf freshly
# written into --work, wherever that is, which is exactly what matters.
#
#   ./assets/memo/compress/compress_bench.sh --work tmp/compress-bench \
#     --entry genome-fasta=/path/to/genome.fa \
#     --random genome-fasta=/path/to/genome.fa.fai \
#     --entry genome-index-star=/path/to/Genome \
#     --entry genome-index-star=/path/to/SAindex \
#     --random genome-index-star
#
#   ./assets/memo/compress/compress_bench.sh --work tmp/compress-bench --combos "lz4 zstd:14" \
#     --entry os=images/ubuntu24--base.sqf
#
set -uo pipefail

OUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=""
PROCS=4
COMBOS="lz4 gzip:1 gzip:6 gzip:9 zstd:1 zstd:8 zstd:14 zstd:19 zstd:22"
KEEP=0
RANDOM_BLOCK=65536
RANDOM_READS=50
EXEC_RUNS=10
TMP_INODE_THRESHOLD=50000
TMP_SIZE_THRESHOLD=$((2 * 1024 * 1024 * 1024))
NAMES=()
declare -A PATHS
RAND_NAMES=()
declare -A RAND_FAI
declare -A EXEC_CMD
EXTRACT_TMP_DIRS=()

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

die() { printf 'compress_bench: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
	--work) WORK="$2"; shift 2 ;;
	--outdir) OUTDIR="$2"; shift 2 ;;
	--procs) PROCS="$2"; shift 2 ;;
	--combos) COMBOS="$2"; shift 2 ;;
	--random-block) RANDOM_BLOCK="$2"; shift 2 ;;
	--random-reads) RANDOM_READS="$2"; shift 2 ;;
	--exec-runs) EXEC_RUNS="$2"; shift 2 ;;
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
	--random)
		kv="$2"; shift 2
		if [[ "$kv" == *=* ]]; then
			name="${kv%%=*}"
			RAND_FAI[$name]="${kv#*=}"
		else
			name="$kv"
			RAND_FAI[$name]=""
		fi
		RAND_NAMES+=("$name")
		;;
	--exec)
		kv="$2"; shift 2
		name="${kv%%=*}"
		cmd="${kv#*=}"
		[[ "$kv" == *=* && -n "$name" && -n "$cmd" ]] || die "--exec needs NAME=CMD, got '$kv'"
		EXEC_CMD[$name]="$cmd"
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

for tool in mksquashfs unsquashfs /usr/bin/time unshare squashfuse_ll mountpoint fusermount3; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# Best-effort: dropping the page cache needs root, which a bench on a shared
# HPC login/compute node rarely has. Rows still get written either way — see
# the cold-unverified label above — this only decides which label they get.
DROP_OK=0
if sync 2>/dev/null && echo 3 2>/dev/null >/proc/sys/vm/drop_caches; then
	DROP_OK=1
fi

CCSV="$OUTDIR/compress_bench.csv"
RCSV="$OUTDIR/read_bench.csv"
ECSV="$OUTDIR/exec_bench.csv"
# Header only on first write, so repeated runs against the same --outdir
# (e.g. one call per dataset) append rather than each wiping the last.
[[ -f "$CCSV" ]] || printf 'dataset,algo,level,seconds,size_bytes,source_bytes,ratio_pct,peak_rss_kb,procs\n' >"$CCSV"
[[ -f "$RCSV" ]] || printf 'dataset,algo,level,mode,run,seconds,bytes_read,size_bytes,source_bytes,mbps,peak_rss_kb,procs\n' >"$RCSV"
[[ -f "$ECSV" ]] || printf 'dataset,algo,level,cmd,runs,min_seconds,median_seconds,peak_rss_kb,procs\n' >"$ECSV"

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
		echo "${TMPDIR:-/tmp}/compress-bench"
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

rrow() { # rrow <dataset> <algo> <level> <mode> <run> <seconds> <bytes_read> <size> <source_bytes> <rss_kb>
	local mbps
	mbps="$(awk -v b="$7" -v s="$6" 'BEGIN { printf "%.1f", (s > 0) ? b / 1048576 / s : 0 }')"
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "$mbps" "${10}" "$PROCS" >>"$RCSV"
	printf '  read %-20s %-5s %-3s %-10s %-15s %8ss  %8s MB/s  %10s KB\n' \
		"$1" "$2" "${3:--}" "$4" "$5" "$6" "$mbps" "${10}"
}

erow() { # erow <dataset> <algo> <level> <cmd> <runs> <min_s> <median_s> <rss_kb>
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$PROCS" >>"$ECSV"
	printf '  exec %-20s %-5s %-3s %2sx  min %7ss  median %7ss  %10s KB  %s\n' \
		"$1" "$2" "${3:--}" "$5" "$6" "$7" "$8" "$4"
}

# read_once mounts one archive with squashfuse_ll and reads every file under
# it, all inside one unshare'd namespace — see the header for why. squashfuse_ll
# runs in the foreground (-f) and backgrounded by the shell instead of
# daemonizing, specifically so /usr/bin/time is timing the actual mount+serve
# process rather than an orphaned double-fork it can't see the RSS of; the
# script polls for the mount instead of blocking on squashfuse_ll's own exit.
# Prints "<seconds> <peak_rss_kb>".
read_once() {
	local archive="$1"
	shift
	local mnt="$WORK/mnt"
	rm -rf "$mnt"
	mkdir -p "$mnt"
	local names=()
	local b
	for b in "$@"; do
		names+=("$mnt/$(basename "$b")")
	done
	local tlog="$WORK/read_rss"
	rm -f "$tlog"
	local start
	start=$(now)
	unshare --user --map-root-user --mount -- bash -c '
		set -e
		tlog="$1" archive="$2" mnt="$3"
		shift 3
		/usr/bin/time -f "%M" -o "$tlog" squashfuse_ll -f -o ro "$archive" "$mnt" &
		mount_pid=$!
		tries=0
		until mountpoint -q "$mnt" 2>/dev/null; do
			tries=$((tries + 1))
			if [ "$tries" -ge 100 ]; then
				kill "$mount_pid" 2>/dev/null
				exit 1
			fi
			sleep 0.05
		done
		find "$@" -mindepth 0 -type f -print0 | xargs -0 -r cat >/dev/null
		fusermount3 -u "$mnt"
		wait "$mount_pid" || true
	' _ "$tlog" "$archive" "$mnt" "${names[@]}" >/dev/null 2>&1 ||
		die "read failed for $archive"
	printf '%s %s\n' "$(elapsed "$start")" "$(cat "$tlog" 2>/dev/null || echo 0)"
}

# random_offsets_fai draws --random-reads offsets from a .fai index the same
# way `samtools faidx` would: pick a sequence weighted by length, a position
# within it, then convert (offset, linebases, linewidth) to a byte offset.
# Every line names $fname, the one file all these offsets apply to.
random_offsets_fai() {
	local fai="$1" fname="$2"
	awk -v n="$RANDOM_READS" -v fname="$fname" '
		{ len[NR] = $2; off[NR] = $3; lb[NR] = $4; lw[NR] = $5; total += $2; cum[NR] = total; nseq = NR }
		END {
			srand()
			for (i = 0; i < n; i++) {
				r = rand() * total
				lo = 1; hi = nseq
				while (lo < hi) { mid = int((lo + hi) / 2); if (cum[mid] < r) lo = mid + 1; else hi = mid }
				s = lo
				maxpos = len[s] > 1 ? len[s] - 1 : 1
				pos = int(rand() * maxpos)
				line = int(pos / lb[s]); col = pos % lb[s]
				printf "%s\t%d\n", fname, off[s] + line * lw[s] + col
			}
		}' "$fai"
}

# random_offsets_walk draws --random-reads offsets across every regular file
# under a dataset's resolved sources, walked recursively and weighted by
# size — the whole tree is the candidate pool, not a subset (real access can
# land on any file in an environment, not just the largest few). A file
# source is its own mount-root entry; a directory source's files sit under
# <basename(source)>/<relative path>, matching where mksquashfs's
# -keep-as-directory actually puts them — see the pack step below.
random_offsets_walk() {
	local s root
	{
		for s in "$@"; do
			if [[ -d "$s" ]]; then
				root="$(basename "$s")"
				find "$s" -type f -printf "%s\t${root}/%P\n"
			elif [[ -f "$s" ]]; then
				printf '%s\t%s\n' "$(stat -c%s "$s")" "$(basename "$s")"
			fi
		done
	} | awk -F'\t' -v n="$RANDOM_READS" -v block="$RANDOM_BLOCK" '
		{ sz[NR] = $1; nm[NR] = $2; total += $1; cum[NR] = total; nf = NR }
		END {
			srand()
			for (i = 0; i < n; i++) {
				r = rand() * total
				lo = 1; hi = nf
				while (lo < hi) { mid = int((lo + hi) / 2); if (cum[mid] < r) lo = mid + 1; else hi = mid }
				f = lo
				maxoff = sz[f] - block; if (maxoff < 1) maxoff = 1
				printf "%s\t%d\n", nm[f], int(rand() * maxoff)
			}
		}'
}

# random_once mounts one archive and, in the same namespace, reads
# --random-reads fixed-size blocks at the offsets in $offsets_file (lines of
# "mount-relative-path<TAB>byte-offset", drawn once per dataset — see the
# header on why they are reused rather than redrawn per combo). Same
# foreground-mount-under-time approach as read_once, for the same reason.
# Prints "<seconds> <peak_rss_kb>".
random_once() {
	local archive="$1" offsets_file="$2"
	local mnt="$WORK/mnt"
	rm -rf "$mnt"
	mkdir -p "$mnt"
	local tlog="$WORK/random_rss"
	rm -f "$tlog"
	local start
	start=$(now)
	unshare --user --map-root-user --mount -- bash -c '
		set -e
		tlog="$1" archive="$2" mnt="$3" block="$4" offsets="$5"
		/usr/bin/time -f "%M" -o "$tlog" squashfuse_ll -f -o ro "$archive" "$mnt" &
		mount_pid=$!
		tries=0
		until mountpoint -q "$mnt" 2>/dev/null; do
			tries=$((tries + 1))
			if [ "$tries" -ge 100 ]; then
				kill "$mount_pid" 2>/dev/null
				exit 1
			fi
			sleep 0.05
		done
		while IFS=$'"'"'\t'"'"' read -r tfile off; do
			dd if="$mnt/$tfile" bs="$block" skip="$off" iflag=skip_bytes count=1 of=/dev/null 2>/dev/null
		done <"$offsets"
		fusermount3 -u "$mnt"
		wait "$mount_pid" || true
	' _ "$tlog" "$archive" "$mnt" "$RANDOM_BLOCK" "$offsets_file" >/dev/null 2>&1 ||
		die "random read failed for $archive"
	printf '%s %s\n' "$(elapsed "$start")" "$(cat "$tlog" 2>/dev/null || echo 0)"
}

# exec_once mounts one archive and, in the same namespace, runs CMD (a path
# relative to ROOT — the dataset's single source's own basename, which is
# where mksquashfs's -keep-as-directory actually put it — plus arguments)
# EXEC_RUNS times, each timed and RSS-measured individually under
# /usr/bin/time. No cold/warm split — see the header for why. Prints one
# "<seconds> <rss_kb>" line per run. Written to a real script file rather
# than an inline bash -c string, since the inner loop's own quoting would
# otherwise collide with the outer single-quoted unshare command.
exec_once() {
	local archive="$1" root="$2" cmd="$3"
	local mnt="$WORK/mnt"
	rm -rf "$mnt"
	mkdir -p "$mnt"
	local script="$WORK/exec_runner.sh"
	local tlog="$WORK/exec_times"
	rm -f "$tlog"
	cat >"$script" <<'INNER'
#!/usr/bin/env bash
set -e
archive="$1" mnt="$2" root="$3" cmd="$4" runs="$5" tlog="$6"
/usr/bin/time -f "%M" -o "$tlog.mount" squashfuse_ll -f -o ro "$archive" "$mnt" &
mount_pid=$!
tries=0
until mountpoint -q "$mnt" 2>/dev/null; do
	tries=$((tries + 1))
	if [ "$tries" -ge 100 ]; then
		kill "$mount_pid" 2>/dev/null
		exit 1
	fi
	sleep 0.05
done
cd "$mnt/$root" || exit 1
i=0
while [ "$i" -lt "$runs" ]; do
	rlog="$tlog.$i"
	start=$(date +%s%N)
	/usr/bin/time -f "%M" -o "$rlog" bash -c "$cmd" >/dev/null 2>&1
	end=$(date +%s%N)
	rss=$(cat "$rlog" 2>/dev/null || echo 0)
	rm -f "$rlog"
	awk -v s="$start" -v e="$end" -v rss="$rss" 'BEGIN { printf "%.6f %s\n", (e - s) / 1000000000, rss }' >>"$tlog"
	i=$((i + 1))
done
cd /
fusermount3 -u "$mnt"
wait "$mount_pid" || true
INNER
	chmod +x "$script"
	unshare --user --map-root-user --mount -- "$script" "$archive" "$mnt" "$root" "$cmd" "$EXEC_RUNS" "$tlog" \
		>/dev/null 2>&1 || die "exec failed for $archive"
	cat "$tlog"
}

printf 'work    %s (%s)\nprocs   %s\ncombos  %s\ndatasets %s\nrandom  %s\ndrop_caches %s\n\n' \
	"$WORK" "$FSTYPE" "$PROCS" "$COMBOS" "${NAMES[*]}" "${RAND_NAMES[*]:-none}" \
	"$([[ $DROP_OK == 1 ]] && echo yes || echo "no (needs root) — cold rows are cold-unverified")"

mkdir -p "$WORK/offsets"

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

	offsets_file=""
	if [[ -v RAND_FAI[$name] ]]; then
		offsets_file="$WORK/offsets/$name"
		fai="${RAND_FAI[$name]}"
		if [[ -n "$fai" ]]; then
			[[ -f "$fai" ]] || die "$name: no .fai at $fai"
			# The fasta is whichever --entry source the .fai's own name (minus
			# .fai) matches; every dataset's --entry list is small enough that
			# an exact basename match is unambiguous.
			fname=""
			for s in $src; do
				[[ "$(basename "$fai")" == "$(basename "$s").fai" ]] && fname="$(basename "$s")"
			done
			[[ -n "$fname" ]] || die "$name: $fai does not index any of its --entry sources"
			random_offsets_fai "$fai" "$fname" >"$offsets_file"
		else
			# shellcheck disable=SC2086
			random_offsets_walk $src >"$offsets_file"
		fi
	fi

	exec_root=""
	if [[ -v EXEC_CMD[$name] ]]; then
		# shellcheck disable=SC2206
		src_arr=($src)
		[[ ${#src_arr[@]} -eq 1 ]] || die "$name: --exec requires exactly one --entry source, has ${#src_arr[@]}"
		exec_root="$(basename "${src_arr[0]}")"
	fi

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

		cold_label="cold"
		((DROP_OK)) || cold_label="cold-unverified"

		if ((DROP_OK)); then
			sync
			echo 3 2>/dev/null >/proc/sys/vm/drop_caches
		fi
		printf '  %s: reading %s%s sequential (%s) ...\n' "$name" "$algo" "${level:+:$level}" "$cold_label"
		# shellcheck disable=SC2086
		read -r t1 rss1 <<<"$(read_once "$out" $src)"
		rrow "$name" "$algo" "$level" sequential "$cold_label" "$t1" "$source_bytes" "$size" "$source_bytes" "$rss1"
		printf '  %s: reading %s%s sequential (warm) ...\n' "$name" "$algo" "${level:+:$level}"
		read -r t2 rss2 <<<"$(read_once "$out" $src)"
		rrow "$name" "$algo" "$level" sequential warm "$t2" "$source_bytes" "$size" "$source_bytes" "$rss2"

		if [[ -n "$offsets_file" ]]; then
			bytes_read=$((RANDOM_READS * RANDOM_BLOCK))
			if ((DROP_OK)); then
				sync
				echo 3 2>/dev/null >/proc/sys/vm/drop_caches
			fi
			printf '  %s: reading %s%s random (%s) ...\n' "$name" "$algo" "${level:+:$level}" "$cold_label"
			read -r t1 rss1 <<<"$(random_once "$out" "$offsets_file")"
			rrow "$name" "$algo" "$level" random "$cold_label" "$t1" "$bytes_read" "$size" "$source_bytes" "$rss1"
			printf '  %s: reading %s%s random (warm) ...\n' "$name" "$algo" "${level:+:$level}"
			read -r t2 rss2 <<<"$(random_once "$out" "$offsets_file")"
			rrow "$name" "$algo" "$level" random warm "$t2" "$bytes_read" "$size" "$source_bytes" "$rss2"
		fi

		if [[ -n "$exec_root" ]]; then
			cmd="${EXEC_CMD[$name]}"
			printf '  %s: exec %s%s "%s" x%s ...\n' "$name" "$algo" "${level:+:$level}" "$cmd" "$EXEC_RUNS"
			mapfile -t exec_lines < <(exec_once "$out" "$exec_root" "$cmd")
			stats="$(printf '%s\n' "${exec_lines[@]}" | awk '
				{ secs[NR] = $1; r = $2 + 0; if (r > maxrss) maxrss = r }
				END {
					n = NR
					for (i = 1; i <= n; i++)
						for (j = i + 1; j <= n; j++)
							if (secs[j] < secs[i]) { t = secs[i]; secs[i] = secs[j]; secs[j] = t }
					min = secs[1]
					mid = int((n + 1) / 2)
					median = (n % 2 == 0) ? (secs[n / 2] + secs[n / 2 + 1]) / 2 : secs[mid]
					printf "%.6f %.6f %d\n", min, median, maxrss
				}')"
			read -r emin emedian erss <<<"$stats"
			erow "$name" "$algo" "$level" "$cmd" "$EXEC_RUNS" "$emin" "$emedian" "$erss"
		fi

		((KEEP)) || rm -f "$out"
	done
done

rm -rf "$WORK/mnt" "$WORK/offsets"
if ((KEEP)); then
	:
else
	rm -rf "$WORK/src"
	((${#EXTRACT_TMP_DIRS[@]})) && rm -rf "${EXTRACT_TMP_DIRS[@]}"
fi
printf '\nwrote %s\n      %s\n      %s\n' "$CCSV" "$RCSV" "$ECSV"
