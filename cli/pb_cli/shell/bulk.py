"""Fast bulk insert for DuckDB via newline-delimited JSON (NDJSON) COPY.

DuckDB's Python executemany is ~300-800x slower than COPY FROM for large
batches.  NDJSON is preferred over CSV because:
  - NULL is a first-class JSON value (no sentinel string needed)
  - Embedded JSON blobs (e.g. taint_paths.steps) round-trip cleanly
  - On this corpus NDJSON COPY is measurably faster than CSV COPY

Usage:
    bulk_insert(conn, "proc_defs", ["file", "object", ...], rows)
"""

from __future__ import annotations

import json
import os
import tempfile

import duckdb

Conn = duckdb.DuckDBPyConnection


def bulk_insert(conn: Conn, table: str, columns: list[str], rows: list[tuple]) -> None:
    """Write rows to table via a temp NDJSON file and DuckDB COPY FROM.

    Each row is paired with columns to form a JSON object; None becomes JSON null.
    """
    if not rows:
        return
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".jsonl", delete=False
    ) as f:
        path = f.name
        for row in rows:
            f.write(json.dumps(dict(zip(columns, row))) + "\n")
    try:
        conn.execute(f"COPY {table} FROM '{path}' (FORMAT JSON)")
    finally:
        os.unlink(path)
