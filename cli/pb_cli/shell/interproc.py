"""DuckDB I/O for inter-procedural data flow tables — bulk-inserts from Haskell-produced JSON.

Pass 7 of the Haskell pipeline (writeTaintAnalysis) produces:
  interproc_edges.json, procedure_summaries.json

This module reads those files and bulk-inserts into DuckDB.
"""

from __future__ import annotations

import json
from pathlib import Path

from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn


def _load_json(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def build_interproc_tables(conn: Conn, out_dir: Path | None = None) -> None:
    """Bulk-insert interproc_edges and procedure_summaries from Haskell-produced JSON."""
    conn.execute("TRUNCATE TABLE interproc_edges")
    conn.execute("TRUNCATE TABLE procedure_summaries")

    if out_dir is None:
        return

    _bulk_insert_interproc_edges(conn, out_dir)
    _bulk_insert_procedure_summaries(conn, out_dir)


def _bulk_insert_interproc_edges(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "interproc_edges.json")
    if not rows:
        return
    bulk_insert(conn, "interproc_edges",
        ["caller_object", "caller_proc", "caller_line",
         "callee_object", "callee_proc", "edge_kind",
         "var_name", "caller_context", "callee_context"],
        [
            (
                r["caller_object"], r["caller_proc"], r.get("caller_line"),
                r["callee_object"], r["callee_proc"], r["edge_kind"],
                r["var_name"], r["caller_context"], r["callee_context"],
            )
            for r in rows
        ],
    )


def _bulk_insert_procedure_summaries(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "procedure_summaries.json")
    if not rows:
        return
    bulk_insert(conn, "procedure_summaries",
        ["file", "object", "proc_name",
         "params_in", "globals_read", "globals_written", "return_flows_to"],
        [
            (
                r["file"], r["object"], r["proc_name"],
                json.dumps(r["params_in"]) if r.get("params_in") else None,
                json.dumps(r["globals_read"]) if r.get("globals_read") else None,
                json.dumps(r["globals_written"]) if r.get("globals_written") else None,
                json.dumps(r["return_flows_to"]) if r.get("return_flows_to") else None,
            )
            for r in rows
        ],
    )
