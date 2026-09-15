#!/usr/bin/env python3
"""Plot procs_bench.csv into procs_bench.png (pack time) and procs_memory.png
(peak RSS) -- one subplot per dataset, one line per combo, x-axis is
-processors. Only a few combos are drawn (COMBO_COLOR below) -- the full
level sweep is in procs_bench.csv, but plotting all of it is unreadable.
Also writes procs_ratio.png: compressed/source size by algo and level,
independent of -processors, so it draws every level (unlike the two above).

    ./plot.py
    ./plot.py -o /some/other/dir
"""
import argparse
import csv
import os

import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
# A handful of representative combos, not the full sweep in procs_bench.csv:
# gzip-9 (max effort), zstd-8 (the recommended default), zstd-14 (the
# speed/size tradeoff pick), zstd-19 (near-max effort), lz4 (no level).
COMBO_COLOR = {
    ("gzip", "9"): "#d6604d",
    ("lz4", ""): "#e6b800",
    ("zstd", "8"): "#92c5de",
    ("zstd", "14"): "#4393c3",
    ("zstd", "19"): "#2166ac",
}
ALGO_COLOR = {"gzip": "#d6604d", "lz4": "#e6b800", "zstd": "#4393c3"}


def read_rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def datasets_in_order(rows):
    seen = []
    for row in rows:
        if row["dataset"] not in seen:
            seen.append(row["dataset"])
    return seen


def series_label(algo, level):
    return f"{algo}-{level}" if level else algo


def plot_grid(rows, y_fn, ylabel, title, out_path):
    names = datasets_in_order(rows)
    ncols = 3
    nrows = -(-len(names) // ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.5 * ncols, 4.5 * nrows), squeeze=False)
    for i, name in enumerate(names):
        ax = axes[i // ncols][i % ncols]
        by_combo = {}
        for r in rows:
            if r["dataset"] != name or (r["algo"], r["level"]) not in COMBO_COLOR:
                continue
            by_combo.setdefault((r["algo"], r["level"]), []).append(r)

        for (algo, level), combo_rows in sorted(by_combo.items()):
            combo_rows.sort(key=lambda r: int(r["procs"]))
            xs = [int(r["procs"]) for r in combo_rows]
            ys = [y_fn(r) for r in combo_rows]
            ax.plot(xs, ys, marker="o", color=COMBO_COLOR[(algo, level)], label=series_label(algo, level))
        ax.set_title(name)
        ax.set_xlabel("-processors")
        ax.set_ylabel(ylabel)
        ax.legend(fontsize=7, ncol=2)
        ax.grid(True, alpha=0.3)
    for j in range(len(names), nrows * ncols):
        axes[j // ncols][j % ncols].axis("off")
    fig.suptitle(title)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def plot_ratio(rows, out_path):
    # -processors doesn't affect ratio_pct, only speed, so one row per
    # (dataset, algo, level) is enough -- the full CSV has four duplicates
    # of every ratio, one per procs count tested.
    names = datasets_in_order(rows)
    ncols = 3
    nrows = -(-len(names) // ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.5 * ncols, 4.5 * nrows), squeeze=False)
    for i, name in enumerate(names):
        ax = axes[i // ncols][i % ncols]
        seen = {}
        for r in rows:
            if r["dataset"] == name:
                seen.setdefault((r["algo"], r["level"]), float(r["ratio_pct"]))

        by_algo = {}
        for (algo, level), ratio in seen.items():
            by_algo.setdefault(algo, []).append((level, ratio))

        for algo, pts in sorted(by_algo.items()):
            color = ALGO_COLOR.get(algo, "#333333")
            leveled = sorted(((int(level), ratio) for level, ratio in pts if level))
            if leveled:
                xs = [p[0] for p in leveled]
                ys = [p[1] for p in leveled]
                ax.plot(xs, ys, marker="o", color=color, label=algo)
            for level, ratio in pts:
                if not level:
                    ax.axhline(ratio, color=color, linestyle="--", label=algo)
        ax.set_title(name)
        ax.set_xlabel("level")
        ax.set_ylabel("compressed / source (%)")
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)
    for j in range(len(names), nrows * ncols):
        axes[j // ncols][j % ncols].axis("off")
    fig.suptitle("Procs: compression ratio by algo and level")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--outdir", default=HERE)
    args = parser.parse_args()

    rows = read_rows(os.path.join(HERE, "procs_bench.csv"))

    plot_grid(
        rows,
        y_fn=lambda r: float(r["seconds"]),
        ylabel="pack seconds",
        title="Procs: cores vs pack time",
        out_path=os.path.join(args.outdir, "procs_bench.png"),
    )
    plot_grid(
        rows,
        y_fn=lambda r: float(r["peak_rss_kb"]) / 1024,
        ylabel="peak RSS (MB)",
        title="Procs: cores vs memory",
        out_path=os.path.join(args.outdir, "procs_memory.png"),
    )
    plot_ratio(rows, os.path.join(args.outdir, "procs_ratio.png"))
    print(
        f"wrote {args.outdir}/procs_bench.png\n"
        f"      {args.outdir}/procs_memory.png\n"
        f"      {args.outdir}/procs_ratio.png"
    )


if __name__ == "__main__":
    main()
