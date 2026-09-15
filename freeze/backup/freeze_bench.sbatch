#!/usr/bin/env bash
#SBATCH --job-name=freeze_bench
#SBATCH --cpus-per-task=4
#SBATCH --mem=4G
#SBATCH --time=02:00:00
#SBATCH --output=freeze_bench.out
#
# Submits freeze_bench.sh at -p matching --cpus-per-task, against the base
# image this node's condatainer install already has.
#
#   cd freeze && sbatch freeze_bench.sbatch
#
# Must be submitted from this directory: slurmd stages the script into its own
# spool path before running it, so BASH_SOURCE cannot find freeze_bench.sh — the
# job starts with its cwd already set to where sbatch was invoked, so pwd can.
set -euo pipefail

die() { echo "freeze_bench.sbatch: $*" >&2; exit 1; }
command -v condatainer >/dev/null || die "condatainer is not on PATH"

if [[ -n "${CNT_ROOT:-}" ]]; then
	ROOT="$CNT_ROOT"
else
	bin="$(readlink -f "$(command -v condatainer)")"
	ROOT="$(dirname "$(dirname "$bin")")"
fi

base_name="$(condatainer config get base 2>/dev/null)"
[[ -n "$base_name" ]] || die "condatainer config get base returned nothing"

BASE="$ROOT/images/$base_name--base.sqf"
[[ -f "$BASE" ]] || die "no base image at $BASE"

[[ -f ./freeze_bench.sh ]] || die "no freeze_bench.sh in $(pwd) — submit from the freeze/ directory"
WORK="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/freeze_bench.${SLURM_JOB_ID:-$$}"

./freeze_bench.sh -w "$WORK" -b "$BASE" -p "${SLURM_CPUS_PER_TASK:-4}"
