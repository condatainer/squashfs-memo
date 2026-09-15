#!/usr/bin/env bash
#
# compress_matrix.sh — runs compress_bench.sh once per real dataset already
# installed on this machine, one at a time: only that one dataset's scratch
# exists at a time, and it is deleted before the next dataset starts. Nothing
# is built for this — every category below is an existing artifact, resolved
# either through `condatainer info` (for a condatainer overlay) or under
# --modules-root (for a plain installed module). A category is skipped, with
# a message, when its artifact isn't present on this machine.
#
# Only genome-fasta gets --random: it's the one dataset with a real
# coordinate-indexed random-access pattern (samtools faidx and friends). It
# isn't added elsewhere — a program (the env-* categories) isn't loaded by
# touching random offsets, see README.md's --exec section, and STAR/salmon
# load their index wholesale into RAM rather than touching it at random, so
# there's nothing real for a random-offset draw to model there either.
#
# Environment categories (the "shape" tested, not literally these tools):
#
#   os            an OS overlay (condatainer: ubuntu24/build-essential)
#   env-python    a python-based tool (module: conda/envs/scenic)
#   env-c         a C-based tool (module: apps/samtools/1.22.1)
#   env-complex   many mixed-language deps: python + JVM + a C++ tool, run
#                 through Snakemake (module: conda/envs/sci_rna)
#   env-java      a java-based tool (module: apps/gatk4/4.6.2.0)
#
# Data categories:
#
#   genome-fasta   a reference FASTA, with its .fai for coordinate-weighted
#                  random reads (module: ref/grch38/genome/gencode)
#   star-index     a STAR index (module: ref/grch38/star/2.7.11b/gencode47-151)
#
#   ./compress_matrix.sh --work tmp/compress-matrix
#   ./compress_matrix.sh --work tmp/compress-matrix --only os,env-c
#
# --modules-root overrides where plain installed modules are found (default
# /path/to/modules); --only restricts to a comma-separated subset of the
# category names above; any other flag is forwarded to every
# compress_bench.sh call (e.g. --combos, --procs).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'compress_matrix: %s\n' "$*" >&2; exit 1; }
usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

MODULES="${CMB_MODULES_ROOT:-/path/to/modules}"
WORK=""
ONLY=""
EXTRA=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--work) WORK="$2"; shift 2 ;;
	--modules-root) MODULES="$2"; shift 2 ;;
	--only) ONLY="$2"; shift 2 ;;
	-h | --help) usage 0 ;;
	*) EXTRA+=("$1"); shift ;;
	esac
done

[[ -n "$WORK" ]] || die "--work is required"
mkdir -p "$WORK" || die "cannot create $WORK"
WORK="$(cd "$WORK" && pwd)"

wanted() {
	[[ -z "$ONLY" ]] && return 0
	[[ ",$ONLY," == *",$1,"* ]]
}

# resolve_overlay prints the on-disk path condatainer resolves NAME to, or
# nothing if NAME isn't installed.
resolve_overlay() {
	condatainer info "$1" 2>/dev/null | awk '/^  Path:/ {print $2; exit}'
}

# run_one packs+reads one dataset in its own --work subdir, deleted
# afterward regardless of outcome, so only one dataset's scratch exists at a
# time. Extra args (a dataset's --entry/--random) come after the name.
run_one() {
	local name="$1"
	shift
	if ! wanted "$name"; then
		skip "$name" "not in --only"
		return 0
	fi
	local cwork="$WORK/$name"
	rm -rf "$cwork"
	mkdir -p "$cwork"
	"$HERE/compress_bench.sh" --work "$cwork" --outdir "$HERE" "$@" "${EXTRA[@]}"
	local rc=$?
	rm -rf "$cwork"
	return $rc
}

skip() { printf '%s: skip (%s)\n' "$1" "$2"; }

# --- environment categories ---

os_path="$(resolve_overlay ubuntu24/build-essential)"
if [[ -n "$os_path" ]]; then
	[[ -f "$os_path" ]] || die "ubuntu24/build-essential resolved to $os_path, which does not exist"
	run_one os --entry "os=$os_path"
else
	skip os "ubuntu24/build-essential not installed"
fi

py_path="$MODULES/conda/envs/scenic"
if [[ -d "$py_path" ]]; then
	run_one env-python --entry "env-python=$py_path"
else
	skip env-python "no $py_path"
fi

c_path="$MODULES/apps/samtools/1.22.1"
if [[ -d "$c_path" ]]; then
	run_one env-c --entry "env-c=$c_path"
else
	skip env-c "no $c_path"
fi

complex_path="$MODULES/conda/envs/sci_rna"
if [[ -d "$complex_path" ]]; then
	run_one env-complex --entry "env-complex=$complex_path"
else
	skip env-complex "no $complex_path"
fi

java_path="$MODULES/apps/gatk4/4.6.2.0"
if [[ -d "$java_path" ]]; then
	run_one env-java --entry "env-java=$java_path"
else
	skip env-java "no $java_path"
fi

# --- data categories ---

fasta_path="$MODULES/ref/grch38/genome/gencode/GRCh38.primary_assembly.genome.fa"
fai_path="$fasta_path.fai"
if [[ -f "$fasta_path" ]]; then
	if [[ -f "$fai_path" ]]; then
		run_one genome-fasta --entry "genome-fasta=$fasta_path" --random "genome-fasta=$fai_path"
	else
		run_one genome-fasta --entry "genome-fasta=$fasta_path"
	fi
else
	skip genome-fasta "no $fasta_path"
fi

star_dir="$MODULES/ref/grch38/star/2.7.11b/gencode47-151"
if [[ -d "$star_dir" ]]; then
	run_one star-index --entry "star-index=$star_dir"
else
	skip star-index "no $star_dir"
fi
