#!/usr/bin/env bash
#SBATCH --job-name=procs_matrix
#SBATCH --cpus-per-task=16
#SBATCH --mem=48G
#SBATCH --time=24:00:00
#SBATCH --output=procs_matrix.out
#
# Submits procs_matrix.sh with its default --procs-list (4 8 12 16) inside
# one allocation sized for the largest of them — mksquashfs -processors caps
# its own thread count, so a job with more cores than a given run asks for
# just leaves the rest idle for that run rather than causing contention.
#
#   cd procs && sbatch procs_matrix.sbatch
#   cd procs && sbatch procs_matrix.sbatch --procs-list "4 16"
#
# Must be submitted from this directory: slurmd stages the script into its
# own spool path before running it, so BASH_SOURCE cannot find
# procs_matrix.sh — the job starts with its cwd already set to where sbatch
# was invoked, so pwd can.
set -euo pipefail

die() { echo "procs_matrix.sbatch: $*" >&2; exit 1; }
[[ -f ./procs_matrix.sh ]] || die "no procs_matrix.sh in $(pwd) — submit from the procs/ directory"

./procs_matrix.sh --work "${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/procs_matrix.${SLURM_JOB_ID:-$$}" "$@"
