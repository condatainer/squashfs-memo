#!/bin/bash
# Build fuse2fs from the same e2fsprogs source against libfuse 2 and libfuse 3.
#   ./build.sh            builds every version in versions.env
# Output: work/bin/fuse2fs-<e2fsprogs>-libfuse<2|3> and work/build-info.txt
# Needs: a C compiler, make, pkg-config (or pkgconf), python3 with pip (for meson and ninja), curl, xz, tar.
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$HERE/versions.env"
WORK=${WORK:-$HERE/work}
JOBS=${JOBS:-4}
DL=$WORK/dl SRC=$WORK/src PFX=$WORK/prefix BIN=$WORK/bin
mkdir -p "$DL" "$SRC" "$PFX" "$BIN"

command -v pkg-config >/dev/null || command -v pkgconf >/dev/null || {
  echo "pkg-config is required (configure uses it to find libfuse3)" >&2; exit 1; }
command -v gcc >/dev/null || command -v cc >/dev/null || { echo "a C compiler is required" >&2; exit 1; }

# A toolchain with prefixed binutils (for example a conda compiler) has no plain `ar`.
triplet=$( (gcc -dumpmachine || cc -dumpmachine) 2>/dev/null)
for tool in ar ranlib nm; do
  command -v "$tool" >/dev/null && continue
  command -v "$triplet-$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
  export "$(echo "$tool" | tr a-z A-Z)=$triplet-$tool"
done

fetch() {   # fetch <file> <url> <sha256>
  local file=$1 url=$2 want=$3
  [ -f "$DL/$file" ] || curl -fsSL -o "$DL/$file" "$url"
  local got; got=$(sha256sum "$DL/$file" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "sha256 mismatch for $file: $got" >&2; exit 1; }
}

fetch "fuse-$LIBFUSE2_VERSION.tar.gz" \
  "https://github.com/libfuse/libfuse/releases/download/fuse-$LIBFUSE2_VERSION/fuse-$LIBFUSE2_VERSION.tar.gz" \
  "$SHA256_fuse_2_9_9"
fetch "fuse-$LIBFUSE3_VERSION.tar.gz" \
  "https://github.com/libfuse/libfuse/releases/download/fuse-$LIBFUSE3_VERSION/fuse-$LIBFUSE3_VERSION.tar.gz" \
  "$SHA256_fuse_3_16_2"
for v in $E2FSPROGS_VERSIONS; do
  var=SHA256_e2fsprogs_${v//./_}
  fetch "e2fsprogs-$v.tar.xz" \
    "https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$v/e2fsprogs-$v.tar.xz" "${!var}"
done

# libfuse 2: library only. The mount helper is the host's fusermount, linked at compare time.
if [ ! -f "$PFX/fuse2/lib/libfuse.so" ]; then
  rm -rf "$SRC/fuse-$LIBFUSE2_VERSION"; tar -xzf "$DL/fuse-$LIBFUSE2_VERSION.tar.gz" -C "$SRC"
  ( cd "$SRC/fuse-$LIBFUSE2_VERSION"
    ./configure --prefix="$PFX/fuse2" --disable-static --disable-example --disable-util --disable-mtab
    make -j"$JOBS" && make install )
fi

# libfuse 3: library only, built with meson.
if [ ! -f "$PFX/fuse3/lib/libfuse3.so" ] && [ ! -f "$PFX/fuse3/lib64/libfuse3.so" ]; then
  [ -x "$WORK/venv/bin/meson" ] || { python3 -m venv "$WORK/venv"; "$WORK/venv/bin/pip" -q install meson ninja; }
  rm -rf "$SRC/fuse-$LIBFUSE3_VERSION"; tar -xzf "$DL/fuse-$LIBFUSE3_VERSION.tar.gz" -C "$SRC"
  ( cd "$SRC/fuse-$LIBFUSE3_VERSION"
    PATH="$WORK/venv/bin:$PATH" meson setup build --prefix="$PFX/fuse3" --libdir=lib \
      -Dutils=false -Dexamples=false -Dtests=false -Duseroot=false
    PATH="$WORK/venv/bin:$PATH" ninja -C build install )
fi

: > "$WORK/build-info.txt"
for v in $E2FSPROGS_VERSIONS; do
  for n in 2 3; do
    name=fuse2fs-$v-libfuse$n
    dir=$SRC/e2fsprogs-$v-libfuse$n
    rm -rf "$dir"; mkdir -p "$dir"; tar -xJf "$DL/e2fsprogs-$v.tar.xz" -C "$dir" --strip-components=1
    (
      cd "$dir"
      export CFLAGS="-g -O2 -std=gnu17"   # a compiler defaulting to C23 rejects the old `typedef int bool`
      if [ "$n" = 3 ]; then
        export PKG_CONFIG_LIBDIR="$PFX/fuse3/lib/pkgconfig"     # fuse3 is found, so configure picks it
        export LDFLAGS="-L$PFX/fuse3/lib -Wl,-rpath,$PFX/fuse3/lib"
      else
        export PKG_CONFIG_LIBDIR="$WORK/none"                   # fuse3 is not found, so configure falls back to -lfuse (2.x API)
        export CPPFLAGS="-I$PFX/fuse2/include -D_FILE_OFFSET_BITS=64" LDFLAGS="-L$PFX/fuse2/lib -Wl,-rpath,$PFX/fuse2/lib"
      fi
      ./configure --enable-fuse2fs --disable-nls --disable-fsck --disable-uuidd --enable-libuuid --enable-libblkid > configure.log 2>&1
      make -j"$JOBS" libs > make.log 2>&1
      make -C misc fuse2fs >> make.log 2>&1
    )
    cp "$dir/misc/fuse2fs" "$BIN/$name"
    {
      echo "== $name"
      "$BIN/$name" --version 2>&1 | head -2 || true
      ldd "$BIN/$name" | grep -iE "fuse" || true
    } | tee -a "$WORK/build-info.txt"
  done
done
echo "built: $(ls "$BIN" | tr '\n' ' ')"
