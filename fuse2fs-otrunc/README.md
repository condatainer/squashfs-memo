# fuse2fs and `O_TRUNC`: libfuse2 vs libfuse3

A writable `env.img` is an ext3 image mounted through `fuse2fs`. On some hosts a file that is
overwritten with shorter content keeps its old size on disk, so the new bytes are followed by the
tail of the old content. This folder builds the same `fuse2fs` source against libfuse 2 and
libfuse 3 and compares the result.

## What is being tested

- `fuse2fs` up to e2fsprogs 1.47.2 has no `O_TRUNC` handling in `open`. 1.47.3 adds it.
- libfuse 3 requests atomic `O_TRUNC` by default, so the kernel passes the flag to `open`.
- libfuse 2 requests it only with `-o atomic_o_trunc`, so the kernel sends a separate truncate first.
- Prediction: only an old `fuse2fs` on libfuse 3 loses the truncate.

## Matrix

| e2fsprogs | libfuse | prediction |
|---|---|---|
| 1.47.1 | 2.9.9 | ok |
| 1.47.1 | 3.16.2 | truncate lost |
| 1.47.4 | 2.9.9 | ok |
| 1.47.4 | 3.16.2 | ok |

The versions are pinned in [versions.env](versions.env).

## What the test does

For each binary the script creates a 128 MB ext3 image, mounts it, and writes 62383 random bytes
to each of six files per case. Then it shortens each file in one of four ways:

| case | operation | expected size |
|---|---|---|
| `sh` | `cat small > file` (shell redirection) | 1058 |
| `cp` | `cp small file` | 1058 |
| `zr` | `: > file` (open with truncate, no write) | 0 |
| `ft` | `truncate -s 1058 file` (`ftruncate`, no `O_TRUNC`) | 1058 |

- It reads the sizes in the mounted session, then unmounts and reads them again with `debugfs`.
- `ft` is the control: it does not use `O_TRUNC`, so it must be correct in every variant.
- A variant is `TRUNCATE-LOST` when the on-disk sizes differ from the expected ones.

## Run

Build anywhere with a compiler, `make`, `pkg-config`, `python3` with `pip`, `curl` and `xz`:

```bash
./build.sh
```

Compare inside a user namespace, where root mounts `/dev/fuse` directly. No `fusermount` is needed:

```bash
apptainer exec --fakeroot --bind "$PWD" <image with e2fsprogs> bash compare.sh
```

- Output is a table and `work/results-<job id or pid>.tsv`. Runs do not share files, so one job per node can overlap. Everything built lands under `work/`, which git ignores.
- The libfuse libraries are built without their mount helper.
- `compare.sh` unmounts with `umount`.
- Binaries are linked dynamically with an rpath into `work/prefix`, so run them from the same path.

## One node

```bash
sbatch --nodelist=<node> compare.sbatch   # the name Slurm registers (the fully qualified name)
```

- The log goes to `fuse2fs-otrunc-<job id>.log` in the submit directory.
- Run it on several nodes to confirm that the result does not depend on the node.

## Another cluster

`check-cluster.sh` needs no build, no Slurm and no other file from this folder:

```bash
# on a node of the cluster, with apptainer, mke2fs and debugfs on PATH
./check-cluster.sh /path/to/any-image    # an image that can run `sh`
```

- It prints the node's `fuse2fs` path, version and libfuse, the `fusermount` mode, the Apptainer
  version, the tools Apptainer ships in its own libexec directory, and the loaded modules.
- Then it mounts a fresh ext3 image as an overlay through `apptainer exec --fakeroot`, overwrites a
  62383-byte file with 6 bytes by `>` and by `cp`, and reads the sizes back with `debugfs`.
- `verdict=OK` means the cluster's real stack truncates. `verdict=TRUNCATE-LOST` means it does not.
- The in-session sizes can look right through the overlay. Only the on-disk sizes decide.
- On a cluster that provides tools through a software stack, load the same modules a job would use.

## Notes

- `build.sh` selects the libfuse version the way e2fsprogs' `configure` does. It looks for `fuse3`
  through `pkg-config` first and falls back to `-lfuse` (FUSE 2 API) when it finds none. For the
  libfuse 2 builds, `PKG_CONFIG_LIBDIR` points at an empty directory.
- The e2fsprogs hashes match kernel.org's `sha256sums.asc`. The libfuse hashes are of the GitHub
  release tarballs as first downloaded.
- The `fuse2fs` target is built as `make libs && make -C misc fuse2fs`. A plain `make` builds the
  rest of e2fsprogs too, which this experiment does not need.

## Results

Run on a node with kernel `6.12.0-211.61.1.el10_2`, inside a user namespace (`apptainer exec
--fakeroot`), where root mounts `/dev/fuse` directly. Same node, same kernel, same source for every row.

| e2fsprogs | libfuse | in-session | on-disk | verdict |
|---|---|---|---|---|
| 1.47.1 | 2.9.9 | `sh=1058 cp=1058 zr=0 ft=1058` | `sh=1058 cp=1058 zr=0 ft=1058` | ok |
| 1.47.1 | 3.16.2 | `sh=62383 cp=62383 zr=62383 ft=1058` | `sh=62383 cp=62383 zr=62383 ft=1058` | truncate lost |
| 1.47.4 | 2.9.9 | `sh=1058 cp=1058 zr=0 ft=1058` | `sh=1058 cp=1058 zr=0 ft=1058` | ok |
| 1.47.4 | 3.16.2 | `sh=1058 cp=1058 zr=0 ft=1058` | `sh=1058 cp=1058 zr=0 ft=1058` | ok |

- Only the old `fuse2fs` on libfuse 3 loses the truncate. This matches the prediction in the matrix.
- Every truncating open is lost there: shell redirection, `cp` and an open with no write.
- `ft` (`ftruncate`, no `O_TRUNC`) is correct in every row, so only the open path is affected.
- With 1.47.4 the same libfuse 3 gives the right sizes.
- The loss shows in the mounted session too, not only after unmount.
