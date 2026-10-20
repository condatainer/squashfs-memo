#!/bin/bash
# Report a node's FUSE stack and test the truncate end to end through apptainer.
# No Slurm and no build needed. Run it on a node of the cluster to check:
#   ./check-cluster.sh /path/to/any-image.sif-or-sqf      (a full OS image that can run `sh`, not a data overlay)
# Needs apptainer, mke2fs and debugfs on PATH (on a software-stack cluster: load the modules first).
set -u
IMAGE=${1:-}

echo "host=$(hostname -f 2>/dev/null || hostname)"
echo "kernel=$(uname -r)"
echo "os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"

f=$(command -v fuse2fs || true)
echo "fuse2fs=${f:-none}"
if [ -n "$f" ]; then
  echo "fuse2fs_realpath=$(readlink -f "$f")"
  echo "fuse2fs_version=$(fuse2fs --version 2>&1 | sed -n 's/^fuse2fs //p' | head -1)"
  echo "fuse2fs_libfuse=$(ldd "$f" 2>/dev/null | grep -oE 'libfuse3?\.so[.0-9]*[^ ]* => [^ ]*' | head -1)"
fi
m=$(command -v fusermount3 || command -v fusermount || true)
echo "fusermount=${m:-none} $( [ -n "$m" ] && ls -lL "$m" | cut -d' ' -f1 )"

a=$(command -v apptainer || true)
echo "apptainer=${a:-none} $( [ -n "$a" ] && apptainer --version 2>&1 | head -1 )"
if [ -n "$a" ]; then
  libexec=$(apptainer buildcfg 2>/dev/null | sed -n 's/^LIBEXECDIR=//p')
  echo "apptainer_libexec_tools=$(ls "$libexec/apptainer/bin" 2>/dev/null | tr '\n' ' ')"
  b="$libexec/apptainer/bin/fuse2fs"
  [ -x "$b" ] && echo "apptainer_bundled_fuse2fs=$("$b" --version 2>&1 | sed -n 's/^fuse2fs //p' | head -1) $(ldd "$b" | grep -oE 'libfuse3?\.so[.0-9]*' | head -1)"
fi
command -v module >/dev/null 2>&1 && echo "modules=$(module list 2>&1 | tr '\n' ' ' | tr -s ' ')"

[ -n "$IMAGE" ] && [ -n "$a" ] || { echo "end-to-end test skipped (needs an image argument and apptainer)"; exit 0; }
for tool in mke2fs debugfs; do command -v $tool >/dev/null || { echo "end-to-end test skipped ($tool missing)"; exit 0; }; done

apptainer exec "$IMAGE" sh -c true >/dev/null 2>&1 || {
  echo "end-to-end test skipped: $IMAGE cannot run sh. Use a full OS image, not a data overlay."
  echo "  example: apptainer pull alpine.sif docker://alpine:3.20 && ./check-cluster.sh alpine.sif"
  exit 0
}

T=$(mktemp -d "${TMPDIR:-/tmp}/otrunc.XXXXXX"); trap 'rm -rf "$T"' EXIT
truncate -s 64M "$T/t.img"; mke2fs -q -t ext3 -F "$T/t.img"
# The test makes no files owned by another uid, so the host fakeroot command is not needed. Skipping it also
# avoids binding a glibc fakeroot into a musl image.
apptainer exec --fakeroot --ignore-fakeroot-command --overlay "$T/t.img" "$IMAGE" sh -c '
  head -c 62383 /dev/urandom > /otrunc-sh; echo short > /otrunc-sh
  head -c 62383 /dev/urandom > /otrunc-cp; echo short > /tmp/s; cp /tmp/s /otrunc-cp
  echo "in-session: sh=$(stat -c %s /otrunc-sh) cp=$(stat -c %s /otrunc-cp)"' > "$T/exec.out" 2>&1
grep -E "^in-session" "$T/exec.out" || {
  echo "apptainer exec did not run the test; its last output lines:"
  grep -v "unknown groupid" "$T/exec.out" | tail -15 | sed 's/^/  /'
}
size() { debugfs -R "stat /upper/$1" "$T/t.img" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1; }
sh_size=$(size otrunc-sh); cp_size=$(size otrunc-cp)
echo "on-disk:    sh=$sh_size cp=$cp_size   (expect 6 and 6)"
if [ -z "$sh_size" ] || [ -z "$cp_size" ]; then echo "verdict=ERROR (the test files were not created, nothing was measured)"
elif [ "$sh_size" = 6 ] && [ "$cp_size" = 6 ]; then echo "verdict=OK"
else echo "verdict=TRUNCATE-LOST"; fi
