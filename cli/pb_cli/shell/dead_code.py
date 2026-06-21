"""DuckDB I/O for dead_procedures table — bulk-inserts from Haskell-produced JSON.

Pass 8 of the Haskell pipeline (writeDeadCodeAnalysis) produces:
  dead_procedures.json

This module reads that file and bulk-inserts into DuckDB.
"""

from __future__ import annotations

import json
from pathlib import Path

from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn


def build_dead_code_table(conn: Conn, out_dir: Path | None = None) -> None:
    """Bulk-insert dead code analysis results from Haskell-produced JSON."""
    conn.execute("DELETE FROM dead_procedures")

    if out_dir is None:
        return

    path = out_dir / "dead_procedures.json"
    if not path.exists():
        return

    rows = json.loads(path.read_text(encoding="utf-8"))
    if not rows:
        return

    bulk_insert(
        conn,
        "dead_procedures",
        ["object", "name", "proc_type", "cyclomatic", "confidence",
         "caller_count_naive", "caller_count_scoped"],
        [
            (r["object"], r["name"], r["proc_type"], r.get("cyclomatic"),
             r["confidence"], r["caller_count_naive"], r["caller_count_scoped"])
            for r in rows
        ],
    )
