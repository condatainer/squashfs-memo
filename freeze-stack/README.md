# Freeze-on-frozen: does stacking, then freezing again, actually work?

Memo: can a second writable overlay be mounted live on top of an already-frozen
`env.sqf`, edited, and then packed into a new, self-contained `.sqf` that
carries both what it added and what it deleted — from its own content and
from `env.sqf`'s?

Neither half of this exists in `condatainer` today: mounting `env.sqf` and any
`.img` together is refused (both claim `/cnt_env`), and `overlay freeze` only
knows how to pack a single `.img`. Two scripts answer the pack half by hand,
before either piece of code is written, matching the two routes freeze already
supports for packing a single `.img` (mount a fuse union vs stage both sides
to a plain directory first):

- `test-freeze-stack.sh` — the **mount** route: `apptainer` and the same
  `fuse2fs`/`squashfuse`/`fuse-overlayfs`/`mksquashfs`/`debugfs` tools freeze
  already uses, unioning `env1.sqf` and `env2.img` live before packing.
- `test-freeze-stack-rdump.sh` — the **rdump** route: no `unshare`, no FUSE
  mount of any kind for the pack step. `unsquashfs`/`debugfs rdump` extract
  both sides to plain directories, a `cp`+`rm` reproduces the union by hand,
  and `mksquashfs` packs the result. This is the fallback a host uses when it
  can't do the unprivileged mount at all — same reason it exists for the
  single-`.img` case today.

Both take the same `env1.sqf` + edited `env2.img` and produce a byte-identical
listing for `env3.sqf`.

## What it does

```
0. create env1.img, write a file, delete a base file (/etc/hostname), freeze -> env1.sqf
1. apptainer exec --overlay env1.sqf:ro --overlay env2.img (a fresh, empty .img), on the real base:
     - confirm env1.sqf's content and its whiteout are visible through the stack
     - add a file, delete something env1.sqf itself provided, delete something only the base provides
2. debugfs-scan env2.img's raw upper/ (no mount) for the two deletion markers
3. confirm env1.sqf's own whiteout is real (a bare squashfuse mount of env1.sqf alone shows it)
4. unsquashfs -lls env1.sqf to enumerate any whiteout it already carries
5. mount env1.sqf(ro) + env2.img(rw) together (no base), pack the merged view with
   mksquashfs, injecting a fresh char 0:0 node for every deletion found in steps 2 and 4
6. mount the resulting env3.sqf against the real base and check the combined state
```

## Running it

```bash
CNT=/path/to/condatainer_go BASE=/path/to/base.sqf bash test-freeze-stack.sh
CNT=/path/to/condatainer_go BASE=/path/to/base.sqf bash test-freeze-stack-rdump.sh
```

The mount route needs `apptainer`, `e2fsprogs` (`debugfs`), `squashfs-tools`,
`squashfuse`, `fuse-overlayfs`, `unshare`. The rdump route needs only
`apptainer` (for the two real edit sessions, steps 0–1), `e2fsprogs`,
`squashfs-tools` — no `unshare`, no FUSE tools at all. Neither needs fakeroot
or root. Everything happens under `img/`, `sqf/`, `stage/` beside the script
and is safe to delete afterwards.

## Result: it works, but not for the reason it first looked like it would

All six stages pass. `env3.sqf`, mounted for real against the same base,
correctly has the new file, is missing both deleted files, and neither
deletion resurrected the base file it was hiding.

**The one surprise (step 3/5):** the plan going in was that an *existing*
whiteout in `env1.sqf` — the `/etc/hostname` char `0:0` node from its own
freeze — would pass through a live `env1.sqf` + `env2.img` overlay union for
free, since nothing in `env2.img` touches it. It does not. `fuse-overlayfs`
recognizes the kernel whiteout convention (a char `0:0` node) on *read*, in
any layer it's stacked over — not only in the upper layer it itself writes —
and swallows the entry instead of exposing it as an ordinary device node. So
packing straight from the merged view silently drops it, exactly the
resurrection bug freeze already found once at the base level, one level up:
an *inherited* whiteout needs the same explicit re-injection as a brand new
one. Step 4's `unsquashfs -lls | grep '^c'` is how that inheritance is found
— no mount required, since `env1.sqf` is a plain archive.

**What did merge for free:** regular content. `keep.txt` (untouched),
`newfile.txt` (added), and `willdelete.txt`'s removal (deleting something
`env1.sqf` itself provided) all came out correct from the live
`env1.sqf` + `env2.img` union with no special-casing — the union only needed
help for whiteouts, not for files.

**Simpler than expected:** deciding whether a deletion in `env2.img` needs a
fresh whiteout never needed to ask "does `env1.sqf` have this path" — only
"does the container base have it." A deletion of `env1.sqf`'s own content is
safe to translate into a whiteout unconditionally, matching how freeze already
treats every single-file `.wh.<name>` marker today (always emit the char `0:0`
node; it's harmless if there's nothing left below to hide). No new
base-comparison logic was needed for the plain-file case tested here — only
for a whole-directory replacement (opaque dirs), which this experiment doesn't
exercise and which already has its own mechanism that would need to look at
`env1.sqf` *and* the base rather than just the base, unlike everything else
here.

**The rdump route needs the same re-injection, for a different reason.**
`unsquashfs -d` extracting `env1.sqf` drops its device node exactly like the
live union swallows it (`unsquashfs` can't create one unprivileged — exit 2,
same as `Unfreeze` already handles) — so both routes end up needing the
*same* two-source scan (env2.img's raw upper/ + env1.sqf's own `unsquashfs
-lls` listing) and the same combined `-pf` list. What differs is only how the
non-deletion content gets merged: the mount route gets it from a live
`fuse-overlayfs` union; the rdump route reproduces the same union by hand —
extract both sides to plain directories, copy the upper's real files over the
lower's, and for every surviving `.wh.<name>` marker, delete both the marker
and the path it names. No `rsync` was available on this host, so that's
`cp -a` twice (lower then upper) followed by a `find | rm` pass, not a single
merge call — a real implementation would want something more careful than
"copy twice," but the *result* matched the mount route exactly.

**A tool quirk that cost the most debugging time:** `stat` (and bash's
`[ -e ]`) hangs indefinitely reading a device-node inode through `squashfuse`
inside an `unshare --map-root-user` mount+user namespace, on this host. `ls`
(readdir + getattr) reads the exact same inode instantly. Nothing in the real
mechanism depends on `stat`-ing a device node through a live mount — the
pack gets whiteout information from `-pf` and `unsquashfs -lls`, never from
touching one through a mount — so this doesn't block anything, but it burned
most of the iteration time getting this script to stop hanging. Worth knowing
before reaching for `stat` in similar unprivileged-mount tooling.
