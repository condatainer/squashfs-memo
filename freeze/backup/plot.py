#!/usr/bin/env python3
"""Plot pack_bench.csv and ident_bench.csv into pack_bench.png and ident_bench.png.

    ./plot.py
    ./plot.py -o /some/other/dir
"""
import argparse
import csv
import os

import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

PACK_ROUTES = [
    "fuse-container",
    "fuse-host",
    "fuse-host-bundled",
    "fuse-unshare",
    "rdump-total",
]
IDENT_ROUTES = [
    "img-container",
    "img-host",
    "img-host-bundled",
    "img-unshare",
    "sqf-container",
    "sqf-host",
    "sqf-unshare",
    "local",
]


def read_rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


ROUTE_LABELS = {
    "fuse-container": "fuse2fs/ext3, container:",
    "fuse-host": "fuse2fs/ext3, host:",
    "fuse-host-bundled": "fuse2fs/ext3, host: (bundled bin)",
    "fuse-unshare": "fuse2fs/ext3, unshare",
    "img-container": "fuse2fs/ext3, container:",
    "img-host": "fuse2fs/ext3, host:",
    "img-host-bundled": "fuse2fs/ext3, host: (bundled bin)",
    "img-unshare": "fuse2fs/ext3, unshare",
    "sqf-container": "squashfuse/squashfs, container:",
    "sqf-host": "squashfuse/squashfs, host:",
    "sqf-unshare": "squashfuse/squashfs, unshare",
}


def label_for(route, row):
    # "local" names a route, not a filesystem; the chart is more useful with
    # the fstype the run actually recorded standing in for it.
    if route == "local":
        return row["fstype"]
    return ROUTE_LABELS.get(route, route)


def by_route(rows, routes):
    series = {}
    for row in rows:
        route = row["route"]
        if route not in routes:
            continue
        label = label_for(route, row)
        xs, ys = series.setdefault(label, ([], []))
        xs.append(int(row["files"]))
        ys.append(float(row["seconds"]))
    return series


def plot(series, title, out_path):
    fig, ax = plt.subplots(figsize=(7, 5))
    for route, (xs, ys) in series.items():
        if xs:
            ax.plot(xs, ys, marker="o", label=route)
    ax.set_xlabel("files")
    ax.set_ylabel("seconds")
    ax.set_title(title)
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--outdir", default=HERE)
    args = parser.parse_args()

    pack_rows = read_rows(os.path.join(HERE, "pack_bench.csv"))
    ident_rows = read_rows(os.path.join(HERE, "ident_bench.csv"))

    plot(
        by_route(pack_rows, PACK_ROUTES),
        "Freeze pack: produce the .sqf from the .img",
        os.path.join(args.outdir, "pack_bench.png"),
    )
    plot(
        by_route(ident_rows, IDENT_ROUTES),
        "Freeze ident: hash the payload",
        os.path.join(args.outdir, "ident_bench.png"),
    )
    print(f"wrote {args.outdir}/pack_bench.png\n      {args.outdir}/ident_bench.png")


if __name__ == "__main__":
    main()
