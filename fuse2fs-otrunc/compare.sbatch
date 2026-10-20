#!/bin/bash
#SBATCH --job-name=fuse2fs-otrunc
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:20:00
#SBATCH --output=%x-%j.log
# Submit from this directory: sbatch --nodelist=<node> compare.sbatch
# Slurm runs a copy of this script from its spool directory, so paths come from the submit directory.
set -u
D=${SLURM_SUBMIT_DIR:?submit from the fuse2fs-otrunc directory}
IMAGE=${IMAGE:-/workspace/lab/hanlab/software/condatainer/images/ubuntu24--base.sqf}   # any image with e2fsprogs
echo "hostname=$(hostname) slurm_node=${SLURMD_NODENAME:-?} kernel=$(uname -r)"
apptainer exec --fakeroot --bind "$D" --bind "$(dirname "$IMAGE")" "$IMAGE" bash "$D/compare.sh"
