# Base image ownership and `apt install` under `--fakeroot`

## What broke

On a host with no `/etc/subuid` entry, `--fakeroot` maps only uid 0. `apt` creates
`archives/partial` as `_apt:root` mode `0700`, an unmapped uid, so every download failed:
`rm: cannot remove '.../partial/*.deb': Permission denied`, then `Could not open file
.../partial/...` for each package.

Diffed a base that worked against one that did not, full tally rather than a sample:

```bash
sif=image.sif
offset=$(apptainer sif list "$sif" | awk -F'[|-]' '/FS \(Squashfs/ {gsub(/ /,"",$4); print $4}')
unsquashfs -o "$offset" -lls "$sif" 2>/dev/null \
  | awk '$1 ~ /^[dl-]/ {print $2}' | sort | uniq -c | sort -rn
```

The working image was all entries `root/root`. The broken one had five distinct
non-root owners: `_apt` on `archives/partial`, plus `ubuntu`/`shadow`/`mail`/`utmp` groups on
ordinary system files (`/etc/shadow`, `/home/ubuntu`, `/var/mail`) that `base-passwd` sets during
the docker layer and have nothing to do with sandboxed `apt`.

## Why it cannot recur

Chose repacking `-all-root` over patching only the recipe's `apt-get clean` step: nothing
guarantees any host has an identity for whatever uid an upstream `docker://` layer happens to
ship, subuid range or not.

A `base`/`os` recipe (a "definition" build) is built by writing Apptainer's output as a
**sandbox directory** (`apptainer build --sandbox`), never a `.sif`. Every pack — sandbox
included — goes through one `mksquashfs` invocation:

```
mksquashfs <sources> <target> -processors N -b <block-size> [-keep-as-directory] -all-root -no-xattrs <compress-args>
```

`-all-root` is unconditional there — not gated on build type. Whatever uids a `docker://` layer
shipped, the final `.sqf` has none of them: every entry is owned by root. The bug's precondition —
a file `--fakeroot`'s uid-0-only mapping cannot reach — no longer exists in the archive, on any
host.

A script that reproduces the old `Bootstrap: docker` → `apptainer build --fakeroot out.sif def`
path directly (no sandbox, no repack) is testing the pre-fix pipeline, not this one, and its
results say nothing about whether the fix holds.

## Verifying a given `.sqf`

No comparison build is needed — check the archive directly:

```bash
unsquashfs -lls path/to/some--base.sqf 2>/dev/null \
  | awk '$1 ~ /^[dl-]/ {print $2}' | sort | uniq -c | sort -rn
```

Every entry should read `root/root`. Anything else names a `.sqf` built before this fix, or one
that bypassed condatainer's own build pipeline — not a difference between hosts.
