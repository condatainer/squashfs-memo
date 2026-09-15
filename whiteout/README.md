# Whiteout round-trip test

Memo: does a deletion made in a writable overlay actually stay deleted after
freeze and unfreeze, or does it come back?

`test-whiteout.sh` runs the real CLI end to end — create, delete, freeze, run,
unfreeze, run again — through real Apptainer mounts:

```
create .img → delete in it (exec -w) → freeze → run the .sqf → unfreeze → run the .img
```

Two kinds of deletion, since they're recorded differently:

- **a single file deleted** (`/etc/hostname`)
- **a whole base directory replaced** (`rm -rf /etc/logrotate.d && mkdir
  /etc/logrotate.d && ...`) — the harder case, since packing has to know what
  the directory used to hold in the base in order to hide the entries the
  replacement doesn't provide.

## Running it

```bash
CNT=/path/to/condatainer_go bash test-whiteout.sh   # CNT defaults to `condatainer` on PATH
```

Everything happens under this directory (`img/`, `sqf2/`, `img2/`) and is safe
to delete afterwards — nothing outside it is touched. `test-whiteout.out` is
the output from one such run.

## Result

All three stages passed: both the frozen `.sqf` and the rebuilt `.img` still
hid `/etc/hostname` and the three original `/etc/logrotate.d` entries, while
keeping the payload and the replacement file (`logrotate.d/mine.conf`). See
`test-whiteout.out` for the full run.
