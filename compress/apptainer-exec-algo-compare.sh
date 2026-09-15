#!/usr/bin/env bash
#
# apptainer-exec-algo-compare.sh — builds a sandbox from
# apptainer-exec-algo.def, packs it into one .sqf per --combos entry, then
# runs `apptainer exec` directly against each one (no --overlay, no separate
# base image — the packed .sqf IS what's exec'd into) for several kinds of
# tool, timed. Checks whether compression algorithm affects apptainer exec's
# own load time the way it didn't for the bare unshare+squashfuse_ll --exec
# test in compress_bench.sh (see README.md).
#
# Needs `apptainer build --fakeroot` (or real root) to work — run this on a
# machine where that's available, not inside a nested/unprivileged sandbox.
#
#   ./apptainer-exec-algo-compare.sh --work tmp/apptainer-exec-algo
#   ./apptainer-exec-algo-compare.sh --work tmp/apptainer-exec-algo --combos "lz4 zstd:19"
#
# Writes apptainer_exec_runs.csv into --outdir (default: this directory) —
# one row per individual run, long format, for further analysis in Python
# (distributions, percentiles, plots) beyond the min/median/mean/max printed
# to the terminal. Elapsed time is our own `date +%s%N` nanosecond
# before/after, not /usr/bin/time's own -f '%e': %e only has centisecond
# precision (sleep 0.014 and sleep 0.001 both round to the same value),
# which is too coarse when the whole measurement is tens of milliseconds.
# /usr/bin/time is still used, just for -f '%M' (peak RSS), which has no
# such precision problem. Both are recorded as the raw values produced (raw
# ns, raw KB), unconverted — the terminal summary converts ns to ms only for
# display. Header only on first write, so repeated runs against the same
# --outdir append rather than each wiping the last.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'apptainer-exec-algo-compare: %s\n' "$*" >&2; exit 1; }
usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

WORK=""
OUTDIR="$HERE"
RUNS=30
COMBOS="lz4 gzip:1 gzip:6 gzip:9 zstd:1 zstd:8 zstd:14 zstd:19 zstd:22"
declare -A TOOL_CMD=(
	# baseline runs nothing once inside the container — isolates apptainer's
	# own per-exec overhead (mount + namespace setup) from whatever a real
	# tool then does on top of it.
	[baseline]="true"
	[samtools]="samtools --version"
	[java]="java -version"
	[python-import]="python3 -c 'import numpy, pandas, sklearn'"
	[snakemake]="snakemake --version"
	[cutadapt]="cutadapt --version"
)

while [[ $# -gt 0 ]]; do
	case "$1" in
	--work) WORK="$2"; shift 2 ;;
	--outdir) OUTDIR="$2"; shift 2 ;;
	--runs) RUNS="$2"; shift 2 ;;
	--combos) COMBOS="$2"; shift 2 ;;
	-h | --help) usage 0 ;;
	*) die "unknown option $1" ;;
	esac
done
[[ -n "$WORK" ]] || die "--work is required"

for tool in apptainer mksquashfs /usr/bin/time; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

mkdir -p "$WORK" "$OUTDIR" || die "cannot create $WORK or $OUTDIR"
WORK="$(cd "$WORK" && pwd)"
OUTDIR="$(cd "$OUTDIR" && pwd)"

RUNS_CSV="$OUTDIR/apptainer_exec_runs.csv"
[[ -f "$RUNS_CSV" ]] ||
	printf 'combo,algo,level,tool,cmd,run,ns,peak_rss_kb,image_bytes\n' >"$RUNS_CSV"

SANDBOX="$WORK/sandbox"
if [[ ! -d "$SANDBOX" ]]; then
	printf 'building sandbox from %s ...\n' "$HERE/apptainer-exec-algo.def"
	apptainer build --fakeroot --sandbox "$SANDBOX" "$HERE/apptainer-exec-algo.def" ||
		die "sandbox build failed"
fi

declare -A IMG IMG_BYTES
for combo in $COMBOS; do
	algo="${combo%%:*}"
	level=""
	extra="-comp $algo"
	[[ "$combo" == *:* ]] && level="${combo#*:}" && extra="-comp $algo -Xcompression-level $level"
	img="$WORK/base-$algo${level:+-$level}.sqf"
	if [[ ! -f "$img" ]]; then
		printf 'packing %s ...\n' "$combo"
		# shellcheck disable=SC2086
		mksquashfs "$SANDBOX" "$img" -noappend -quiet -no-progress $extra ||
			die "mksquashfs failed for $combo"
	fi
	IMG[$combo]="$img"
	IMG_BYTES[$combo]="$(stat -c%s "$img")"
done

printf '\n%-10s %-12s %10s %10s %10s %10s\n' combo tool "min ms" "median ms" "mean ms" "max ms"
for combo in $COMBOS; do
	img="${IMG[$combo]}"
	bytes="${IMG_BYTES[$combo]}"
	algo="${combo%%:*}"
	level=""
	[[ "$combo" == *:* ]] && level="${combo#*:}"
	for name in "${!TOOL_CMD[@]}"; do
		cmd="${TOOL_CMD[$name]}"
		# cmd may itself contain commas (e.g. a multi-import python -c), so it's
		# the one field that needs CSV quoting; everything else here is a plain
		# word or number.
		cmd_csv="\"${cmd//\"/\"\"}\""
		times=()
		tlog="$WORK/apptainer_time"
		for ((i = 0; i < RUNS; i++)); do
			rm -f "$tlog"
			start=$(date +%s%N)
			/usr/bin/time -f '%M' -o "$tlog" apptainer exec "$img" bash -c "$cmd" >/dev/null 2>&1 ||
				die "exec failed for $combo ($name)"
			ns=$(($(date +%s%N) - start))
			rss="$(cat "$tlog" 2>/dev/null || echo 0)"
			times+=("$ns")
			printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
				"$combo" "$algo" "$level" "$name" "$cmd_csv" "$i" "$ns" "$rss" "$bytes" >>"$RUNS_CSV"
		done
		# Stats computed on raw ns, converted to ms only for the printed
		# summary — the CSV above keeps the untouched value.
		stats="$(printf '%s\n' "${times[@]}" | sort -n | awk '
			{ a[NR] = $1; sum += $1; if ($1 > max) max = $1 }
			END {
				n = NR
				mid = int((n + 1) / 2)
				median = (n % 2 == 0) ? (a[n / 2] + a[n / 2 + 1]) / 2 : a[mid]
				printf "%.3f %.3f %.3f %.3f\n", a[1] / 1e6, median / 1e6, (sum / n) / 1e6, max / 1e6
			}')"
		read -r tmin tmedian tmean tmax <<<"$stats"
		printf '%-10s %-12s %10s %10s %10s %10s\n' "$combo" "$name" "$tmin" "$tmedian" "$tmean" "$tmax"
	done
done

printf '\nwrote %s\n' "$RUNS_CSV"
