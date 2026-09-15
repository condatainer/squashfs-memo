#!/usr/bin/env bash
#
# freeze_bench.sh — the parts of a freeze that could be done another way, timed
# against their alternatives as the file count grows. Writes pack_bench.csv and
# ident_bench.csv.
#
# Packing and identifying are the two phases where a route was chosen, they
# scale differently, and timing them together says nothing useful about either —
# so each keeps its own output.
#
#   pack   produce the .sqf from the writable .img
#            fuse             mksquashfs reads through a fuse2fs mount of the .img
#            rdump-stage      debugfs extracts the payload to a directory
#            rdump-mksquashfs mksquashfs reads that directory
#          the second pair is the fallback where --fusemount cannot mount.
#
#   ident  hash the payload, which is what the identity is taken over
#            img          through the fuse2fs mount of the .img
#            sqf          through a squashfuse mount of the packed artifact
#            local        on a plain directory — the baseline, and what the
#                         rdump staging directory already offers for free
#
# Freeze also runs Walk, Translate and AppendMeta, and none are timed. Each has
# one implementation and no alternative to compare against — Walk enumerates with
# debugfs because mounting to enumerate would write the superblock of a writable
# source, Translate must list the base to resolve opaque markers, AppendMeta is
# one mksquashfs append. Being route-independent they add the same constant to
# every strategy, so they cannot move a ratio here; they do mean **the totals are
# what you can choose between, not a freeze's wall clock.**
#
# Not the same as plan/freeze-bench.sh, which takes one real .img and reports what
# freezing *that* costs, end to end. This one synthesizes trees to find how the
# choices scale.
#
#   ./assets/memo/freeze/freeze_bench.sh -w /tmp/freezebench
#   ./assets/memo/freeze/freeze_bench.sh -w /tmp/freezebench -n "1000 5000"
#   ./assets/memo/freeze/freeze_bench.sh -w /tmp/freezebench -p 16
#
# -p pins how many processors mksquashfs may use, low by default so a run says
# something about a compute node rather than about whatever the login node has.
# The two phases do not run at the same width — packing is parallel, hashing is
# one process at a time — so each row records what it used, and the phases are
# not comparable without it.
#
# -w must be on a **local** filesystem and is required. On NFS every row measures
# the network instead of the thing named. Peak inode use is twice the largest
# tier: the tree, plus the rdump staging copy, which coexist.
#
set -uo pipefail

BASE=""
OUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=""
TIERS="1000 5000 10000 20000 30000"
COMP="-comp zstd -Xcompression-level 8"
PROCS=4
KEEP=0

# The whole comment header, however long it grows — a line range would silently
# cut it mid-sentence the next time something is added.
usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

while getopts "w:n:b:o:c:p:kh" opt; do
	case "$opt" in
	w) WORK="$OPTARG" ;;
	n) TIERS="$OPTARG" ;;
	b) BASE="$OPTARG" ;;
	o) OUTDIR="$OPTARG" ;;
	c) COMP="$OPTARG" ;;
	p) PROCS="$OPTARG" ;;
	k) KEEP=1 ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

die() { printf 'freeze_bench: %s\n' "$*" >&2; exit 1; }

[[ -n "$WORK" ]] || die "-w is required; point it at a directory on a local filesystem"
[[ -n "$BASE" ]] || die "-b is required; point it at a base image"
[[ -f "$BASE" ]] || die "no base image at $BASE"
mkdir -p "$WORK" "$OUTDIR" || die "cannot create $WORK or $OUTDIR"
WORK="$(cd "$WORK" && pwd)"

# Refused rather than warned: an NFS run produces a plausible CSV of the wrong
# thing, and nothing in the numbers says so afterwards.
FSTYPE="$(stat -f -c %T "$WORK")"
case "$FSTYPE" in
nfs | nfs4 | autofs | cifs | lustre | gpfs)
	die "$WORK is $FSTYPE; this measures local read and pack cost, so it needs a local filesystem"
	;;
esac

for tool in mksquashfs mke2fs debugfs sha256sum apptainer; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# Apptainer bundles both helpers and mounts with them unprivileged, which is why
# freeze can rely on them; buildcfg is authoritative about where.
LIBEXEC="$(apptainer buildcfg 2>/dev/null | sed -n 's/^LIBEXECDIR=//p')/apptainer/bin"
SQUASHFUSE=""
for name in squashfuse_ll squashfuse; do
	[[ -x "$LIBEXEC/$name" ]] && SQUASHFUSE="$LIBEXEC/$name" && break
done
FUSE2FS="$LIBEXEC/fuse2fs"
[[ -n "$SQUASHFUSE" ]] || die "no squashfuse in $LIBEXEC"
[[ -x "$FUSE2FS" ]] || die "no fuse2fs at $FUSE2FS"

# PATH-resolved, for the host: and unshare routes.
PATH_SQUASHFUSE=""
for name in squashfuse_ll squashfuse; do
	command -v "$name" >/dev/null 2>&1 && PATH_SQUASHFUSE="$(command -v "$name")" && break
done
PATH_FUSE2FS="$(command -v fuse2fs 2>/dev/null || true)"
[[ -n "$PATH_SQUASHFUSE" ]] || die "no squashfuse on PATH (outside the apptainer bundle)"
[[ -n "$PATH_FUSE2FS" ]] || die "no fuse2fs on PATH (outside the apptainer bundle)"
command -v unshare >/dev/null 2>&1 || die "unshare is not on PATH"

COMP="$COMP -processors $PROCS"
# xargs runs one sha256sum at a time, so the ident phase is serial whatever the
# host has. Recorded per row because the two phases are otherwise read as if they
# had been measured the same way.
IDENT_PROCS=1

PACK_CSV="$OUTDIR/pack_bench.csv"
IDENT_CSV="$OUTDIR/ident_bench.csv"

# Matches freeze's own identity walk, verbatim but for the cd: three passes,
# not one. The entry pass stats *every* inode — directories and symlinks
# included — and is the part that scales with inode count rather than with
# bytes; hashing regular files alone would measure the wrong half.
WALK_TAIL='find . -mindepth 1 -printf "E\0%y\0%m\0%p\0%l\0"
find . -mindepth 1 -type f -print0 | xargs -0 -r sha256sum -z |
	while IFS= read -r -d "" line; do printf "H\0%s\0" "$line"; done
find . -mindepth 1 \( -type c -o -type b \) -print0 |
	xargs -0 -r stat --printf="D\0%n\0%t\0%T\0"'
WALK='set -o pipefail
cd "$0" || exit 1
'"$WALK_TAIL"

now() { date +%s%N; }
elapsed() { awk -v ns="$(($(now) - $1))" 'BEGIN { printf "%.3f", ns / 1000000000 }'; }

# pack_row and ident_row write to their own file. touched is how many files the
# route actually handled: a mount that failed still returns quickly, so without
# it a broken route is a fast row rather than a visible one. 0 means the route
# does not count files.
pack_row() { # pack_row <files> <route> <seconds> <sqf-bytes> <touched>
	printf '%s,%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$PROCS" "$FSTYPE" >>"$PACK_CSV"
	report pack "$1" "$2" "$3" "$4" "$5"
}
# ident counts entries, not files: the identity covers every inode, so ENTRIES is
# what a complete run must reach. fstype is recorded because the walk is a stat
# over every inode, and that cost is metadata-path performance, which varies by
# filesystem far more than by route.
ident_row() { # ident_row <files> <route> <seconds> <source-bytes> <entries> [expected]
	printf '%s,%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$IDENT_PROCS" "$FSTYPE" >>"$IDENT_CSV"
	local expected="${6:-$ENTRIES}"
	local mark=""
	[[ "$5" == 0 || "$5" == "$expected" ]] || mark="  << saw $5 of $expected entries"
	printf '  %-5s %-17s %8ss  %12s%s\n' ident "$2" "$3" "$4" "$mark"
}
report() {
	local mark=""
	[[ "$6" == 0 || "$6" == "$2" ]] || mark="  << touched $6 of $2"
	printf '  %-5s %-17s %8ss  %12s%s\n' "$1" "$3" "$4" "$5" "$mark"
}

# make_tree builds <n> files over a shallow directory fan, so the walk pays for
# directory traversal the way a real prefix does rather than reading one flat
# directory the kernel caches perfectly. Incompressible and distinct: repeated
# bytes let mksquashfs dedupe the tree away, and then the pack and the squashfuse
# read both measure almost nothing.
make_tree() {
	local dir="$1" n="$2" i
	mkdir -p "$dir"
	for ((i = 0; i < n; i++)); do
		local sub="$dir/d$((i / 100))"
		[[ -d "$sub" ]] || mkdir -p "$sub"
		head -c 4096 /dev/urandom >"$sub/f$i"
		# Roughly the ratio a real environment carries (2 989 links against
		# 109 456 files), so the entry pass has inodes to describe that carry no
		# content of their own.
		((i % 40)) || ln -s "f$i" "$sub/l$i"
	done
}

printf 'files,route,seconds,sqf_bytes,touched,procs,fstype\n' >"$PACK_CSV"
printf 'files,route,seconds,source_bytes,entries,procs,fstype\n' >"$IDENT_CSV"
printf 'work   %s (%s)\nbase   %s\ncomp   %s\nprocs  %s packing, %s hashing\ntiers  %s\n\n' \
	"$WORK" "$FSTYPE" "$BASE" "$COMP" "$PROCS" "$IDENT_PROCS" "$TIERS"

for N in $TIERS; do
	TIER="$WORK/tier-$N"
	rm -rf "$TIER"
	mkdir -p "$TIER/mnt" "$TIER/stage"
	TREE="$TIER/tree"
	IMG="$TIER/env.img"

	printf '%s files\n' "$N"
	make_tree "$TREE" "$N"
	BYTES="$(du -sb "$TREE" | cut -f1)"
	ENTRIES="$(find "$TREE" -mindepth 1 | wc -l)"
	printf '  %s entries (%s files, %s dirs and links)\n' \
		"$ENTRIES" "$N" "$((ENTRIES - N))"

	# 4 MiB of slack per 1000 files, floor 16 MiB: ext3 metadata and the journal
	# need room the payload total does not account for.
	MB=$((BYTES / 1048576 + N / 250 + 16))
	mke2fs -q -t ext3 -F -d "$TREE" "$IMG" "${MB}M" >/dev/null 2>&1 ||
		die "mke2fs could not build a ${MB}M image for $N files"

	# --- pack -------------------------------------------------------------
	start=$(now)
	apptainer exec --fusemount "container:$FUSE2FS -o ro $IMG /mnt" "$BASE" \
		bash -c "mksquashfs /mnt $TIER/fuse.sqf -no-progress -quiet -noappend $COMP" >/dev/null 2>&1
	pack_row "$N" fuse-container "$(elapsed "$start")" "$(stat -c%s "$TIER/fuse.sqf" 2>/dev/null || echo 0)" 0

	start=$(now)
	apptainer exec --fusemount "host:$PATH_FUSE2FS -o ro $IMG /mnt" "$BASE" \
		bash -c "mksquashfs /mnt $TIER/fuse-host.sqf -no-progress -quiet -noappend $COMP" >/dev/null 2>&1
	pack_row "$N" fuse-host "$(elapsed "$start")" "$(stat -c%s "$TIER/fuse-host.sqf" 2>/dev/null || echo 0)" 0

	start=$(now)
	apptainer exec --fusemount "host:$FUSE2FS -o ro $IMG /mnt" "$BASE" \
		bash -c "mksquashfs /mnt $TIER/fuse-host-bundled.sqf -no-progress -quiet -noappend $COMP" >/dev/null 2>&1
	pack_row "$N" fuse-host-bundled "$(elapsed "$start")" "$(stat -c%s "$TIER/fuse-host-bundled.sqf" 2>/dev/null || echo 0)" 0

	start=$(now)
	unshare --user --map-root-user --mount -- bash -c \
		'"$0" -o ro "$1" "$2" || exit 1
mksquashfs "$2" "$3" -no-progress -quiet -noappend '"$COMP"'' \
		"$PATH_FUSE2FS" "$IMG" "$TIER/mnt" "$TIER/fuse-unshare.sqf" >/dev/null 2>&1
	pack_row "$N" fuse-unshare "$(elapsed "$start")" "$(stat -c%s "$TIER/fuse-unshare.sqf" 2>/dev/null || echo 0)" 0

	# rdump cannot restore ownership unprivileged; the chown complaints are the
	# documented limitation, not a failure.
	start=$(now)
	debugfs -R "rdump / $TIER/stage" "$IMG" >/dev/null 2>&1
	staged=$(elapsed "$start")
	pack_row "$N" rdump-stage "$staged" "$(du -sb "$TIER/stage" | cut -f1)" \
		"$(find "$TIER/stage" -mindepth 1 -type f ! -path '*/lost+found/*' | wc -l)"

	start=$(now)
	mksquashfs "$TIER/stage" "$TIER/native.sqf" -no-progress -quiet -noappend $COMP >/dev/null 2>&1
	native=$(elapsed "$start")
	pack_row "$N" rdump-mksquashfs "$native" "$(stat -c%s "$TIER/native.sqf" 2>/dev/null || echo 0)" 0
	pack_row "$N" rdump-total "$(awk -v a="$staged" -v b="$native" 'BEGIN{printf "%.3f", a+b}')" \
		"$(stat -c%s "$TIER/native.sqf" 2>/dev/null || echo 0)" 0

	# --- ident ------------------------------------------------------------
	# Entries counted from the captured preimage afterwards, so the count costs
	# nothing inside the timed region. It is E records, not files: the identity
	# covers every inode.
	entries() { tr '\0' '\n' <"$TIER/preimage" | grep -cx E; }

	start=$(now)
	apptainer exec --fusemount "container:$FUSE2FS -o ro $IMG /mnt" "$BASE" \
		bash -c "$WALK" /mnt >"$TIER/preimage" 2>/dev/null
	# mke2fs will add lost+found at the image root, one entry $TREE never had.
	ident_row "$N" img-container "$(elapsed "$start")" "$(stat -c%s "$IMG")" "$(entries)" "$((ENTRIES + 1))"

	start=$(now)
	apptainer exec --fusemount "host:$PATH_FUSE2FS -o ro $IMG /mnt" "$BASE" \
		bash -c "$WALK" /mnt >"$TIER/preimage" 2>/dev/null
	ident_row "$N" img-host "$(elapsed "$start")" "$(stat -c%s "$IMG")" "$(entries)" "$((ENTRIES + 1))"

	# Same binary as img-container, host: mode instead of container: — isolates
	# the mount mechanism from which fuse2fs build is doing the work.
	start=$(now)
	apptainer exec --fusemount "host:$FUSE2FS -o ro $IMG /mnt" "$BASE" \
		bash -c "$WALK" /mnt >"$TIER/preimage" 2>/dev/null
	ident_row "$N" img-host-bundled "$(elapsed "$start")" "$(stat -c%s "$IMG")" "$(entries)" "$((ENTRIES + 1))"

	start=$(now)
	unshare --user --map-root-user --mount -- bash -c \
		'"$0" -o ro "$1" "$2" || exit 1
cd "$2" || exit 1
'"$WALK_TAIL" \
		"$PATH_FUSE2FS" "$IMG" "$TIER/mnt" >"$TIER/preimage" 2>/dev/null
	ident_row "$N" img-unshare "$(elapsed "$start")" "$(stat -c%s "$IMG")" "$(entries)" "$((ENTRIES + 1))"

	start=$(now)
	apptainer exec --fusemount "container:$SQUASHFUSE $TIER/fuse.sqf /mnt" "$BASE" \
		bash -c "$WALK" /mnt >"$TIER/preimage" 2>/dev/null
	ident_row "$N" sqf-container "$(elapsed "$start")" "$(stat -c%s "$TIER/fuse.sqf")" "$(entries)"

	start=$(now)
	apptainer exec --fusemount "host:$PATH_SQUASHFUSE $TIER/fuse.sqf /mnt" "$BASE" \
		bash -c "$WALK" /mnt >"$TIER/preimage" 2>/dev/null
	ident_row "$N" sqf-host "$(elapsed "$start")" "$(stat -c%s "$TIER/fuse.sqf")" "$(entries)"

	start=$(now)
	unshare --user --map-root-user --mount -- bash -c \
		'"$0" "$1" "$2" || exit 1
cd "$2" || exit 1
'"$WALK_TAIL" \
		"$PATH_SQUASHFUSE" "$TIER/fuse.sqf" "$TIER/mnt" >"$TIER/preimage" 2>/dev/null
	ident_row "$N" sqf-unshare "$(elapsed "$start")" "$(stat -c%s "$TIER/fuse.sqf")" "$(entries)"

	start=$(now)
	bash -c "$WALK" "$TREE" >"$TIER/preimage" 2>/dev/null
	ident_row "$N" local "$(elapsed "$start")" "$BYTES" "$(entries)"

	((KEEP)) || rm -rf "$TIER"
	printf '\n'
done

printf 'wrote %s\n      %s\n' "$PACK_CSV" "$IDENT_CSV"
