#!/usr/bin/env bash
#
# cleanup.sh — removes everything build.sh and compare.sh put under -w: the
# cloned source, both build trees, and the test tree/image. Same -w as the
# other two.
#
#   ./cleanup.sh -w /tmp/svd-bench
#
set -euo pipefail

WORK=""

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

while getopts "w:h" opt; do
	case "$opt" in
	w) WORK="$OPTARG" ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

die() { printf 'cleanup: %s\n' "$*" >&2; exit 1; }

[[ -n "$WORK" ]] || die "-w is required; point it at the shared working directory"
[[ -d "$WORK" ]] || die "$WORK does not exist"

rm -rf "$WORK"
printf 'removed %s\n' "$WORK"
