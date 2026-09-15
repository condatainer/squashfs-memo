# e2fsprogs version: isolating the real cause

`../static-vs-dynamic/`'s result ruled out link mode as the cause of "Apptainer's
bundled `fuse2fs` is slow" — a plain vanilla static build was faster than dynamic,
the opposite of what would explain bundled (static) being the slow one. That leaves
version: bundled is always the newer release (1.47.4) against whatever's on PATH
(1.47.0 or 1.47.1) in every pairing seen so far. `build.sh` builds both versions,
both statically linked, so the two differ in nothing but version.

```
apptainer exec ../static-vs-dynamic/image.sqf ./build.sh -w /tmp/version-bench
./compare.sh -w /tmp/version-bench
./cleanup.sh -w /tmp/version-bench
```

## Result

The version is the cause. At 5k files, same host, on `xfs`-backed local scratch,
both statically linked:

| version | seconds |
|---|---|
| v1.47.4 | 3.323 |
| v1.47.1 | 1.473 |

That's the same ~2.3x gap seen between the real `bundled` and `path` binaries on this
machine, reproduced from nothing but a version change with link mode, FUSE library,
and everything else held fixed. Something changed in e2fsprogs between 1.47.1 and
1.47.4 that makes `fuse2fs` slower; which change specifically is not identified —
that would mean bisecting between the two tags.
