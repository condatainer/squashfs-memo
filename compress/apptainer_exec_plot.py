#!/usr/bin/env python3
"""Plot apptainer_exec_runs.csv: a box plot (one subplot per tool, one box
per compression combo) and a line plot of every tool's median time minus
that combo's baseline median, all tools on one axes.

    ./apptainer_exec_plot.py
    ./apptainer_exec_plot.py -o /some/other/dir
"""
import argparse
import csv
import os
import statistics
from collections import defaultdict

import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
ALGO_COLOR = {"lz4": "#e6b800", "gzip": "#d6604d", "zstd": "#4393c3"}
TOOL_COLOR = {
    "samtools": "#1b9e77",
    "java": "#d95f02",
    "python-import": "#7570b3",
    "snakemake": "#e7298a",
    "cutadapt": "#66a61e",
}
COMBO_ORDER = ["lz4", "gzip:1", "gzip:6", "gzip:9", "zstd:1", "zstd:8", "zstd:14", "zstd:19", "zstd:22"]
TOOL_ORDER = ["baseline", "samtools", "java", "python-import", "snakemake", "cutadapt"]


def read_rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--outdir", default=HERE)
    args = parser.parse_args()

    rows = read_rows(os.path.join(HERE, "apptainer_exec_runs.csv"))

    by_tool_combo = defaultdict(list)
    for r in rows:
        by_tool_combo[(r["tool"], r["combo"])].append(float(r["ns"]) / 1e6)

    tools = [t for t in TOOL_ORDER if any(t == r["tool"] for r in rows)]
    ncols = 3
    nrows = -(-len(tools) // ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.5 * ncols, 4.5 * nrows), squeeze=False)

    for i, tool in enumerate(tools):
        ax = axes[i // ncols][i % ncols]
        combos = [c for c in COMBO_ORDER if (tool, c) in by_tool_combo]
        data = [by_tool_combo[(tool, c)] for c in combos]
        colors = [ALGO_COLOR.get(c.split(":")[0], "#333333") for c in combos]
        bp = ax.boxplot(data, tick_labels=combos, patch_artist=True, showfliers=True)
        for patch, color in zip(bp["boxes"], colors):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
        ax.set_title(tool)
        ax.set_ylabel("ms")
        ax.tick_params(axis="x", rotation=45)
        ax.grid(True, alpha=0.3, axis="y")

    for j in range(len(tools), nrows * ncols):
        axes[j // ncols][j % ncols].axis("off")

    fig.suptitle("apptainer exec: time vs compression combo")
    fig.tight_layout()
    box_path = os.path.join(args.outdir, "apptainer_exec_box.png")
    fig.savefig(box_path, dpi=150)
    plt.close(fig)

    medians = {(t, c): statistics.median(v) for (t, c), v in by_tool_combo.items()}
    combos = [c for c in COMBO_ORDER if ("baseline", c) in medians]

    fig, ax = plt.subplots(figsize=(8, 5.5))
    ax.axhline(0, color="#999999", linestyle="--", linewidth=1, label="baseline")
    for tool in tools:
        if tool == "baseline":
            continue
        xs, ys = [], []
        for i, c in enumerate(combos):
            if (tool, c) not in medians:
                continue
            xs.append(i)
            ys.append(medians[(tool, c)] - medians[("baseline", c)])
        ax.plot(xs, ys, marker="o", color=TOOL_COLOR.get(tool, "#333333"), label=tool)
    ax.set_xticks(range(len(combos)))
    ax.set_xticklabels(combos, rotation=45)
    ax.set_ylabel("median ms - baseline median ms")
    ax.set_title("apptainer exec: per-tool time above baseline")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    diff_path = os.path.join(args.outdir, "apptainer_exec_diff.png")
    fig.savefig(diff_path, dpi=150)
    plt.close(fig)

    print(f"wrote {box_path}\n      {diff_path}")


if __name__ == "__main__":
    main()
