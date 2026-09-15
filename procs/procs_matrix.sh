#!/usr/bin/env bash
#
# procs_matrix.sh — runs procs_bench.sh once per (dataset x --procs) pair.
# Writes to this directory's procs_bench.csv.
#
# Datasets tested (real, already-installed on this machine):
#
#   env-complex   conda/envs/sci_rna
#   genome-fasta  ref/grch38/genome/gencode/GRCh38.primary_assembly.genome.fa
#   star-index    ref/grch38/star/2.7.11b/gencode47-151
#
#   ./procs_matrix.sh --work tmp/procs-matrix
#   ./procs_matrix.sh --work tmp/procs-matrix --procs-list "4 8"
#
# --modules-root overrides where plain installed modules are found (default
# /path/to/modules); --procs-list overrides the four core counts tested
# (default "4 8 12 16"); any other flag is forwarded to every
# procs_bench.sh call (e.g. --combos). --keep is refused: star-index alone
# is tens of GB per combo.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCS_BENCH="$HERE/procs_bench.sh"
die() { printf 'procs_matrix: %s\n' "$*" >&2; exit 1; }
usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

MODULES="${CMB_MODULES_ROOT:-/path/to/modules}"
WORK=""
PROCS_LIST="4 8 12 16"
EXTRA=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--work) WORK="$2"; shift 2 ;;
	--modules-root) MODULES="$2"; shift 2 ;;
	--procs-list) PROCS_LIST="$2"; shift 2 ;;
	--keep) die "--keep is not supported here — star-index alone is tens of GB per combo, and each combo's .sqf must be gone before the next one packs" ;;
	-h | --help) usage 0 ;;
	*) EXTRA+=("$1"); shift ;;
	esac
done

[[ -n "$WORK" ]] || die "--work is required"
[[ -x "$PROCS_BENCH" ]] || die "$PROCS_BENCH not found"
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd)"

complex_path="$MODULES/conda/envs/sci_rna"
[[ -d "$complex_path" ]] || die "no $complex_path"

fasta_path="$MODULES/ref/grch38/genome/gencode/GRCh38.primary_assembly.genome.fa"
[[ -f "$fasta_path" ]] || die "no $fasta_path"

star_dir="$MODULES/ref/grch38/star/2.7.11b/gencode47-151"
[[ -d "$star_dir" ]] || die "no $star_dir"

run_one() { # run_one <procs> <name> <bench-args...>
	local procs="$1" name="$2"
	shift 2
	local cwork="$WORK/p$procs-$name"
	rm -rf "$cwork"
	mkdir -p "$cwork"
	"$PROCS_BENCH" --work "$cwork" --outdir "$HERE" --procs "$procs" "$@" "${EXTRA[@]}"
	local rc=$?
	rm -rf "$cwork"
	return $rc
}

for procs in $PROCS_LIST; do
	run_one "$procs" env-complex --entry "env-complex=$complex_path"
	run_one "$procs" genome-fasta --entry "genome-fasta=$fasta_path"
	run_one "$procs" star-index --entry "star-index=$star_dir"
done
