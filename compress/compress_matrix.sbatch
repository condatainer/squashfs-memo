#!/usr/bin/env bash
#SBATCH --job-name=compress_matrix
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --time=12:00:00
#SBATCH --output=compress_matrix.out
#
# Submits compress_matrix.sh at -procs matching --cpus-per-task. Every
# dataset it runs is already installed on this machine — see
# compress_matrix.sh's header for the category list and where each comes
# from; nothing here needs a path passed in.
#
#   cd compress && sbatch compress_matrix.sbatch
#   cd compress && sbatch compress_matrix.sbatch --only os,env-c
#
# Must be submitted from this directory: slurmd stages the script into its
# own spool path before running it, so BASH_SOURCE cannot find
# compress_matrix.sh — the job starts with its cwd already set to where
# sbatch was invoked, so pwd can.
set -euo pipefail

die() { echo "compress_matrix.sbatch: $*" >&2; exit 1; }
[[ -f ./compress_matrix.sh ]] || die "no compress_matrix.sh in $(pwd) — submit from the compress/ directory"

./compress_matrix.sh --work "${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/compress_matrix.${SLURM_JOB_ID:-$$}" \
	--procs "${SLURM_CPUS_PER_TASK:-4}" "$@"
