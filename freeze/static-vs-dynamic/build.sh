#!/usr/bin/env bash
#
# build.sh — builds fuse2fs at one e2fsprogs version twice: once statically
# linked, once dynamically linked, both under -w (the one working directory
# this folder's scripts share — same -w compare.sh and cleanup.sh take). Two
# builds from the same clone differing in nothing but link mode is the
# comparison ../README.md's "Apptainer's bundled fuse2fs is slow" needs but
# bundled-vs-path can't give, since those also differ in version and in
# whatever unrelated patches the system package carries.
#
#   ./build.sh -w /tmp/svd-bench
#   ./build.sh -w /tmp/svd-bench -v v1.47.0
#
set -euo pipefail

WORK=""
VERSION="v1.47.4"

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

while getopts "w:v:h" opt; do
	case "$opt" in
	w) WORK="$OPTARG" ;;
	v) VERSION="$OPTARG" ;;
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

SRC="$WORK/e2fsprogs"
[[ -d "$SRC" ]] || git clone --depth 1 --branch "$VERSION" https://github.com/tytso/e2fsprogs.git "$SRC" ||
	die "clone failed; check network access and that tag $VERSION exists"

build_one() { # build_one <link> <extra-configure-flags>
	local link="$1" flags="$2" build="$WORK/build-$1"
	mkdir -p "$build"
	cd "$build"
	"$SRC/configure" --enable-fuse2fs $flags >"$build/configure.log" 2>&1 ||
		die "$link: configure failed; see $build/configure.log"
	make -j"$(nproc)" >"$build/make.log" 2>&1 || die "$link: make failed; see $build/make.log"

	local bin
	bin="$(find "$build" -type f -name fuse2fs -perm -u+x | head -n1)"
	[[ -n "$bin" ]] || die "$link: build finished but no fuse2fs binary found under $build"

	printf 'built %s (link=%s)\n' "$bin" "$link"
	"$bin" -V
	ldd "$bin"
	printf '\n'
}

build_one static ""
build_one dynamic "--enable-elf-shlibs"
