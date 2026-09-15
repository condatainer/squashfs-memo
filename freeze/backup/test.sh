#!/usr/bin/env bash
#SBATCH --job-name=test
#SBATCH --cpus-per-task=4
#SBATCH --mem=4G
#SBATCH --time=01:00:00
#SBATCH --output=test.out

echo Hello Slurm
echo $HOSTNAME
echo $USER

if [[ -n "${TMPDIR:-}" ]]; then
	echo "TMPDIR=$TMPDIR"
	stat -f -c %T "$TMPDIR"
    df -h "$TMPDIR"
fi

if [[ -n "${SLURM_TMPDIR:-}" ]]; then
	echo "SLURM_TMPDIR=$SLURM_TMPDIR"
	stat -f -c %T "$SLURM_TMPDIR"
    df -h "$SLURM_TMPDIR"
fi

command -v condatainer
