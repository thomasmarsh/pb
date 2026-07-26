#!/usr/bin/env python3
"""Benchmark compiler-only DuckDB roundtrip cost.

Usage:
    uv run --project cli python scripts/benchmark_roundtrip.py <src_dir> --pbc compiler/pbc

Tables measured (compiler-only, no UI consumer):
  local_vars, cat_footprint_columns, taint_intra_edges, taint_return_rows,
  dw_write_columns, dw_where_columns

Output: JSON to stdout, human-readable report to stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

BYTES_PER_ROW: dict[str, int] = {
    "local_vars": 120,
    "cat_footprint_columns": 160,
    "taint_intra_edges": 80,
    "taint_return_rows": 60,
    "dw_write_columns": 100,
    "dw_where_columns": 100,
}


@dataclass
class TableMetric:
    table: str
    row_count: int = 0
    duckdb_bytes: int = 0
    duckdb_pages: int = 0
    phase_a_append_ms: float = 0.0
    phase_b_query_ms: float = 0.0
    est_memory_mb: float = 0.0


@dataclass
class AggregateMetrics:
    total_row_count: int = 0
    total_duckdb_bytes: int = 0
    total_est_memory_mb: float = 0.0
    total_phase_a_append_ms: float = 0.0
    total_phase_b_query_ms: float = 0.0
    total_roundtrip_ms: float = 0.0
    tables: list[dict[str, Any]] = None  # type: ignore[assignment]
    phase_a_residency_mb: float | None = None
    phase_b_residency_mb: float | None = None
    corpus_file_count: int = 0
    corpus_elapsed_ms: float = 0.0

    def __post_init__(self) -> None:
        if self.tables is None:
            self.tables = []


COMPILER_ONLY_TABLES = frozenset({
    "local_vars",
    "cat_footprint_columns",
    "taint_intra_edges",
    "taint_return_rows",
    "dw_write_columns",
    "dw_where_columns",
})

PHASE_A_TIME_PATTERNS: dict[str, re.Pattern] = {
    "local_vars": re.compile(r"local_vars", re.I),
    "cat_footprint_columns": re.compile(r"cat_footprint", re.I),
    "taint_intra_edges": re.compile(r"taint_intra", re.I),
    "taint_return_rows": re.compile(r"taint_return", re.I),
    "dw_write_columns": re.compile(r"dw_write_column", re.I),
    "dw_where_columns": re.compile(r"dw_where_column", re.I),
}

PHASE_B_QUERY_PATTERNS: dict[str, re.Pattern] = {
    "local_vars": re.compile(r"queryLocalVars"),
    "cat_footprint_columns": re.compile(r"queryCatFootprintColumns"),
    "taint_intra_edges": re.compile(r"queryTaintIntraEdges"),
    "taint_return_rows": re.compile(r"queryTaintReturnRows"),
    "dw_write_columns": re.compile(r"queryDwWriteColumns"),
    "dw_where_columns": re.compile(r"queryDwWhereColumns"),
}


def _match_table(label: str, patterns: dict[str, re.Pattern]) -> str | None:
    for table, pat in patterns.items():
        if pat.search(label):
            return table
    return None


# ---------------------------------------------------------------------------
# Progress event parser
# ---------------------------------------------------------------------------


def parse_progress_events(
    stderr_lines: list[str],
) -> tuple[dict[str, float], dict[str, float], float | None, float | None]:
    append_times: dict[str, float] = {}
    query_times: dict[str, float] = {}
    in_phase_b = False
    last_res_a: float | None = None
    last_res_b: float | None = None

    for line in stderr_lines:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        tag = ev.get("tag")
        name = ev.get("name")

        if tag == "phase" and name == "B":
            in_phase_b = True
            continue
        if tag == "phase" and name == "A":
            in_phase_b = False
            continue
        if tag != "step":
            continue

        label = ev.get("label", "")
        elapsed = ev.get("elapsed_ms")
        residency = ev.get("residency_mb")

        if not in_phase_b:
            tbl = _match_table(label, PHASE_A_TIME_PATTERNS)
            if tbl and elapsed is not None:
                append_times[tbl] = append_times.get(tbl, 0.0) + elapsed
            if residency is not None:
                last_res_a = residency
        else:
            tbl = _match_table(label, PHASE_B_QUERY_PATTERNS)
            if tbl and elapsed is not None:
                query_times[tbl] = query_times.get(tbl, 0.0) + elapsed
            if residency is not None:
                last_res_b = residency

    return append_times, query_times, last_res_a, last_res_b


# ---------------------------------------------------------------------------
# DuckDB table stats
# ---------------------------------------------------------------------------


def get_table_stats(db_path: str, table: str) -> tuple[int, int, int]:
    import duckdb

    conn = duckdb.connect(db_path, read_only=True)
    try:
        rc = int(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
        try:
            stats = conn.execute(
                f"SELECT estimated_size::BIGINT FROM duckdb_tables() WHERE table_name = '{table}'"
            ).fetchone()
            est = int(stats[0]) if stats and stats[0] else rc * BYTES_PER_ROW.get(table, 80)
        except Exception:
            est = rc * BYTES_PER_ROW.get(table, 80)
        pages = max(1, est // 4096)
        return (rc, est, pages)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Main benchmark
# ---------------------------------------------------------------------------


def run_benchmark(src_dir: str, pbc_path: str, db_path: str) -> AggregateMetrics:
    db_new = db_path + ".new"
    for p in [db_path, db_new]:
        if os.path.exists(p):
            os.unlink(p)

    cmd = [pbc_path, "-i", src_dir, "--db", db_new]
    print(f"Running: {' '.join(cmd)}", file=sys.stderr)

    t0 = time.time()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    _, stderr_bytes = proc.communicate()
    elapsed_ms = (time.time() - t0) * 1000
    if proc.returncode != 0:
        print(f"ERROR: pbc exited with code {proc.returncode}", file=sys.stderr)
        print(stderr_bytes.decode()[:5000], file=sys.stderr)
        sys.exit(1)

    stderr_lines = stderr_bytes.decode().split("\n")
    if os.path.exists(db_new):
        os.rename(db_new, db_path)

    # File count heuristic
    file_count = sum(
        1 for line in stderr_lines
        if line.strip() and line.strip().startswith('{"tag":"step"')
        and "compil" in json.loads(line).get("label", "").lower()
    )
    file_count = max(file_count, 1)

    append_times, query_times, res_a, res_b = parse_progress_events(stderr_lines)

    tables_info: list[dict[str, Any]] = []
    for table in sorted(COMPILER_ONLY_TABLES):
        try:
            rc, est, pages = get_table_stats(db_path, table)
        except Exception as exc:
            print(f"  Warning: {table}: {exc}", file=sys.stderr)
            rc, est, pages = 0, 0, 0
        mem_mb = (rc * BYTES_PER_ROW.get(table, 80)) / (1024 * 1024)
        a_ms = append_times.get(table, 0.0)
        q_ms = query_times.get(table, 0.0)
        tables_info.append(asdict(TableMetric(table, rc, est, pages, round(a_ms, 1), round(q_ms, 1), round(mem_mb, 3))))

    total_rows = sum(t["row_count"] for t in tables_info)
    total_bytes = sum(t["duckdb_bytes"] for t in tables_info)
    total_mem = sum(t["est_memory_mb"] for t in tables_info)
    total_a = sum(t["phase_a_append_ms"] for t in tables_info)
    total_q = sum(t["phase_b_query_ms"] for t in tables_info)
    total_rt = total_a + total_q

    return AggregateMetrics(
        total_row_count=total_rows,
        total_duckdb_bytes=total_bytes,
        total_est_memory_mb=round(total_mem, 3),
        total_phase_a_append_ms=round(total_a, 1),
        total_phase_b_query_ms=round(total_q, 1),
        total_roundtrip_ms=round(total_rt, 1),
        tables=tables_info,
        phase_a_residency_mb=round(res_a, 1) if res_a is not None else None,
        phase_b_residency_mb=round(res_b, 1) if res_b is not None else None,
        corpus_file_count=file_count,
        corpus_elapsed_ms=round(elapsed_ms, 0),
    )


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def _fmt_bytes(b: int) -> str:
    if b < 1024:
        return f"{b}B"
    if b < 1024 * 1024:
        return f"{b // 1024}KB"
    return f"{b / (1024 * 1024):.1f}MB"


def print_report(r: AggregateMetrics) -> None:
    print("\n" + "=" * 78, file=sys.stderr)
    print("  COMPILER-ONLY DUCKDB ROUNDTRIP BENCHMARK", file=sys.stderr)
    print("=" * 78, file=sys.stderr)
    print(f"  Corpus files:    {r.corpus_file_count}", file=sys.stderr)
    print(f"  Total elapsed:   {r.corpus_elapsed_ms:.0f} ms", file=sys.stderr)
    print(file=sys.stderr)

    hdr = f"  {'Table':<25} {'Rows':>8} {'DB Size':>10} {'Est Mem':>9}  {'Append':>8}  {'Query':>8}  {'Total':>8}"
    sep = f"  {'-'*25} {'-'*8} {'-'*10} {'-'*9}  {'-'*8}  {'-'*8}  {'-'*8}"
    print(hdr, file=sys.stderr)
    print(sep, file=sys.stderr)

    for t in r.tables:
        total_t = t["phase_a_append_ms"] + t["phase_b_query_ms"]
        print(
            f"  {t['table']:<25} {t['row_count']:>8,} {_fmt_bytes(t['duckdb_bytes']):>10} "
            f"{t['est_memory_mb']:>7.2f}MB  {t['phase_a_append_ms']:>7.1f}ms  "
            f"{t['phase_b_query_ms']:>7.1f}ms  {total_t:>7.1f}ms",
            file=sys.stderr,
        )

    print(sep, file=sys.stderr)
    print(
        f"  {'TOTAL':<25} {r.total_row_count:>8,} {_fmt_bytes(r.total_duckdb_bytes):>10} "
        f"{r.total_est_memory_mb:>7.2f}MB  {r.total_phase_a_append_ms:>7.1f}ms  "
        f"{r.total_phase_b_query_ms:>7.1f}ms  {r.total_roundtrip_ms:>7.1f}ms",
        file=sys.stderr,
    )

    print(file=sys.stderr)
    pct = r.total_roundtrip_ms / r.corpus_elapsed_ms * 100 if r.corpus_elapsed_ms > 0 else 0
    print(f"  Roundtrip as % of total:  {pct:.1f}%", file=sys.stderr)
    print(f"  Est. memory saved:        {r.total_est_memory_mb:.2f} MB", file=sys.stderr)
    if r.phase_a_residency_mb is not None:
        print(f"  Peak residency Phase A:  {r.phase_a_residency_mb:.1f} MB", file=sys.stderr)
    if r.phase_b_residency_mb is not None:
        print(f"  Peak residency Phase B:  {r.phase_b_residency_mb:.1f} MB", file=sys.stderr)

    mem = r.total_est_memory_mb
    print(file=sys.stderr)
    print(f"  {'RECOMMENDATION':-^78}", file=sys.stderr)
    if mem < 0.5:
        print("  Memory impact negligible (< 0.5 MB) — not worth changing.", file=sys.stderr)
    elif mem < 10:
        print(
            f"  Small memory impact ({mem:.1f} MB). Worth evaluating if Phase B query\n"
            f"  overhead significantly exceeds append overhead.",
            file=sys.stderr,
        )
    else:
        print(
            f"  Significant memory impact ({mem:.1f} MB). Worth keeping these tables\n"
            f"  in memory to avoid the DuckDB roundtrip. Target tables:\n"
            f"    {', '.join(sorted(COMPILER_ONLY_TABLES))}",
            file=sys.stderr,
        )
    print("=" * 78, file=sys.stderr)


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("src_dir")
    parser.add_argument("--db", default="pb.duckdb")
    parser.add_argument("--pbc", default="")
    parser.add_argument("-o", "--output", default=None)

    args = parser.parse_args(argv)

    pbc_path = args.pbc
    if not pbc_path:
        for c in [
            "compiler/pbc",
            "compiler/result/bin/pbc",
            str(Path.cwd() / "compiler" / "pbc"),
        ]:
            if os.path.isfile(c) and os.access(c, os.X_OK):
                pbc_path = c
                break
        if not pbc_path:
            try:
                result = subprocess.run(
                    ["cabal", "exec", "--", "which", "pbc"],
                    capture_output=True, text=True,
                    cwd=Path(__file__).resolve().parent.parent,
                )
                if result.returncode == 0 and result.stdout.strip():
                    pbc_path = result.stdout.strip()
            except Exception:
                pass
        if not pbc_path:
            print("ERROR: cannot find pbc binary. Use --pbc.", file=sys.stderr)
            sys.exit(1)

    src_dir = args.src_dir
    if not os.path.isdir(src_dir):
        print(f"ERROR: {src_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    result = run_benchmark(src_dir=src_dir, pbc_path=pbc_path, db_path=args.db)
    print_report(result)

    json_out = json.dumps(asdict(result), indent=2, default=str)
    if args.output:
        with open(args.output, "w") as f:
            f.write(json_out + "\n")
        print(f"\nJSON written to {args.output}", file=sys.stderr)
    else:
        print(json_out)


if __name__ == "__main__":
    main()