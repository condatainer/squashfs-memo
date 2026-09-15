#!/usr/bin/env python3
"""Statistical test on apptainer_exec_runs.csv: does apptainer's own load
time (baseline) really differ by compression combo, and does a tool's own
added cost (its runs minus that combo's baseline median) still differ by
combo once that load time is subtracted out?

Kruskal-Wallis across all nine combos, then pairwise Mann-Whitney against
lz4 (the reference point in every other plot here), for baseline and for
each tool's baseline-subtracted diff.

    ./apptainer_exec_test.py
"""
import csv
import os
import statistics
from collections import defaultdict

from scipy.stats import kruskal, mannwhitneyu

HERE = os.path.dirname(os.path.abspath(__file__))
COMBO_ORDER = ["lz4", "gzip:1", "gzip:6", "gzip:9", "zstd:1", "zstd:8", "zstd:14", "zstd:19", "zstd:22"]
TOOL_ORDER = ["samtools", "java", "python-import", "snakemake", "cutadapt"]
ALPHA = 0.05


def read_rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def report(label, groups):
    combos = [c for c in COMBO_ORDER if c in groups]
    h, p = kruskal(*(groups[c] for c in combos))
    print(f"\n{label}")
    print(f"  Kruskal-Wallis across {len(combos)} combos: H={h:.2f} p={p:.3g} "
          f"({'differs by combo' if p < ALPHA else 'no significant difference'})")
    ref = groups["lz4"]
    print(f"  {'combo':<8} {'median':>10} {'vs lz4 p':>10}")
    for c in combos:
        med = statistics.median(groups[c])
        if c == "lz4":
            print(f"  {c:<8} {med:>10.2f} {'--':>10}")
            continue
        _, p = mannwhitneyu(ref, groups[c])
        flag = "*" if p < ALPHA else ""
        print(f"  {c:<8} {med:>10.2f} {p:>9.3g}{flag}")


def main():
    rows = read_rows(os.path.join(HERE, "apptainer_exec_runs.csv"))

    by_tool_combo = defaultdict(list)
    for r in rows:
        by_tool_combo[(r["tool"], r["combo"])].append(float(r["ns"]) / 1e6)

    baseline = {c: v for (t, c), v in by_tool_combo.items() if t == "baseline"}
    baseline_median = {c: statistics.median(v) for c, v in baseline.items()}
    report("baseline (apptainer's own load time)", baseline)

    for tool in TOOL_ORDER:
        diffs = defaultdict(list)
        for c in COMBO_ORDER:
            if (tool, c) not in by_tool_combo:
                continue
            diffs[c] = [v - baseline_median[c] for v in by_tool_combo[(tool, c)]]
        if diffs:
            report(f"{tool} minus baseline (tool's own added cost)", diffs)


if __name__ == "__main__":
    main()
