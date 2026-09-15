#!/usr/bin/env bash
#
# build.sh — builds fuse2fs at two e2fsprogs versions, both statically linked
# (link mode held constant, matching Apptainer-bundled fuse2fs — static-vs-dynamic/
# already ruled link mode out as the cause). Isolates the one remaining untested
# candidate in ../README.md's "Apptainer's bundled fuse2fs is slow": v1.47.4
# (bundled's version) against v1.47.1 (a PATH version actually seen).
#
#   ./build.sh -w /tmp/version-bench
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

die() { printf 'build: %s\n' "$*" >&2; exit 1; }

[[ -n "$WORK" ]] || die "-w is required; point it at the shared working directory"
for tool in git gcc make pkg-config; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
pkg-config --exists fuse3 || die "fuse3 dev headers not found (pkg-config fuse3); install libfuse3-dev"

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

build_one() { # build_one <version-tag>
	local version="$1"
	local src="$WORK/e2fsprogs-$version"
	local build="$WORK/build-$version"

	[[ -d "$src" ]] || git clone --depth 1 --branch "$version" https://github.com/tytso/e2fsprogs.git "$src" ||
		die "$version: clone failed; check network access and that the tag exists"

	mkdir -p "$build"
	cd "$build"
	"$src/configure" --enable-fuse2fs >"$build/configure.log" 2>&1 ||
		die "$version: configure failed; see $build/configure.log"
	make -j"$(nproc)" >"$build/make.log" 2>&1 || die "$version: make failed; see $build/make.log"

	local bin
	bin="$(find "$build" -type f -name fuse2fs -perm -u+x | head -n1)"
	[[ -n "$bin" ]] || die "$version: build finished but no fuse2fs binary found under $build"

	printf 'built %s (version=%s)\n' "$bin" "$version"
	"$bin" -V
	ldd "$bin"
	printf '\n'
}

build_one v1.47.4
build_one v1.47.1
