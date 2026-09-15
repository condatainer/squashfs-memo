#!/usr/bin/env python3
"""Plot compress_bench.csv and read_bench.csv into compress_bench.png,
compress_memory.png and read_bench.png — one subplot per dataset, same
time-vs-size line-graph layout as squash/squash_bench.png: one line per
algorithm, points annotated by level, lz4 (no level) as a lone marker. Does
not touch apptainer_exec_runs.csv; that investigation isn't finished.

    ./plot.py
    ./plot.py -o /some/other/dir
"""
import argparse
import csv
import os

import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
ALGO_COLOR = {"lz4": "#e6b800", "gzip": "#d6604d", "zstd": "#4393c3"}


def read_rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def datasets_in_order(rows):
    seen = []
    for row in rows:
        if row["dataset"] not in seen:
            seen.append(row["dataset"])
    return seen


def plot_grid(rows, x_fn, y_fn, xlabel, ylabel, title, out_path, filter_fn=None):
    if filter_fn:
        rows = [r for r in rows if filter_fn(r)]
    names = datasets_in_order(rows)
    ncols = 3
    nrows = -(-len(names) // ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.5 * ncols, 4.5 * nrows), squeeze=False)
    for i, name in enumerate(names):
        ax = axes[i // ncols][i % ncols]
        by_algo = {}
        for r in rows:
            if r["dataset"] != name:
                continue
            by_algo.setdefault(r["algo"], []).append(r)
        for algo, algo_rows in by_algo.items():
            color = ALGO_COLOR.get(algo, "#333333")
            leveled = [r for r in algo_rows if r["level"]]
            leveled.sort(key=lambda r: int(r["level"]))
            xs = [x_fn(r) for r in leveled]
            ys = [y_fn(r) for r in leveled]
            if xs:
                ax.plot(xs, ys, marker="o", color=color, label=algo)
                for r, x, y in zip(leveled, xs, ys):
                    ax.annotate(r["level"], (x, y), fontsize=7, xytext=(3, 3), textcoords="offset points")
            unleveled = [r for r in algo_rows if not r["level"]]
            for r in unleveled:
                ax.plot(x_fn(r), y_fn(r), marker="o", color=color, label=algo)
        ax.set_title(name)
        ax.set_xlabel(xlabel)
        ax.set_ylabel(ylabel)
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)
    for j in range(len(names), nrows * ncols):
        axes[j // ncols][j % ncols].axis("off")
    fig.suptitle(title)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--outdir", default=HERE)
    args = parser.parse_args()

    compress_rows = read_rows(os.path.join(HERE, "compress_bench.csv"))
    reads = read_rows(os.path.join(HERE, "read_bench.csv"))

    plot_grid(
        compress_rows,
        x_fn=lambda r: float(r["seconds"]),
        y_fn=lambda r: float(r["size_bytes"]) / 1e6,
        xlabel="pack seconds",
        ylabel="size (MB)",
        title="Compress: time vs size",
        out_path=os.path.join(args.outdir, "compress_bench.png"),
    )
    plot_grid(
        compress_rows,
        x_fn=lambda r: float(r["seconds"]),
        y_fn=lambda r: float(r["peak_rss_kb"]) / 1024,
        xlabel="pack seconds",
        ylabel="peak RSS (MB)",
        title="Compress: time vs memory",
        out_path=os.path.join(args.outdir, "compress_memory.png"),
    )
    plot_grid(
        reads,
        x_fn=lambda r: float(r["seconds"]),
        y_fn=lambda r: float(r["size_bytes"]) / 1e6,
        xlabel="read seconds (sequential, warm)",
        ylabel="size (MB)",
        title="Read: time vs size",
        out_path=os.path.join(args.outdir, "read_bench.png"),
        filter_fn=lambda r: r["mode"] == "sequential" and r["run"] == "warm",
    )
    print(
        f"wrote {args.outdir}/compress_bench.png\n"
        f"      {args.outdir}/compress_memory.png\n"
        f"      {args.outdir}/read_bench.png"
    )


if __name__ == "__main__":
    main()
