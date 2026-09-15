# Static vs dynamic `libext2fs`: isolating the real cause

`../README.md`'s "Apptainer's bundled `fuse2fs` is slow" finding narrowed the cause
to one confirmed structural difference: the bundled binary statically links its own
`libext2fs`, while a separately-installed one dynamically links the host's. But that
comparison also crossed e2fsprogs *versions* at the same time, so it doesn't prove
static linking itself is the cause. `build.sh` builds the same e2fsprogs source
twice — once statically linked, once dynamically — so the two differ in nothing but
link mode.

```
apptainer exec image.sqf ./build.sh -w /tmp/svd-bench
./compare.sh -w /tmp/svd-bench
./cleanup.sh -w /tmp/svd-bench
```

## Result

Static linking is not the cause — and the result runs the opposite direction from
the hypothesis. At 5k files, on the same host, on `xfs`-backed local scratch, from
the same e2fsprogs clone:

| link mode | seconds |
|---|---|
| static | 3.3 |
| dynamic | 20.6 |

`static` is ~6x *faster* than `dynamic`. Since Apptainer's bundled `fuse2fs` (the slow
one in the original comparison) is statically linked, this rules out link mode as the
explanation entirely — if anything, static linking should make a binary faster, not
slower. Whatever actually makes the bundled binary slow is something else; see
`../README.md`'s "Apptainer's bundled `fuse2fs` is slow" for what else has been ruled
out and what hasn't.
