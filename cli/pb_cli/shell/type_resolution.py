"""DuckDB I/O for type resolution tables — bulk-inserts from Haskell-produced JSON.

Pass 5 of the Haskell pipeline (writeResolution) produces:
  resolved_types.json, resolved_calls.json, global_vars.json

This module reads those files and bulk-inserts into DuckDB, replacing
the former Python-based re-resolution (core/type_resolution.py).
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


def build_type_tables(conn: Conn, out_dir: Path | None = None) -> None:
    """Bulk-insert resolved_types, resolved_calls, global_vars from Haskell JSON."""
    conn.execute("DELETE FROM resolved_types")
    conn.execute("DELETE FROM resolved_calls")
    conn.execute("DELETE FROM global_vars")

    if out_dir is None:
        return

    _bulk_insert_resolved_types(conn, out_dir)
    _bulk_insert_resolved_calls(conn, out_dir)
    _bulk_insert_global_vars(conn, out_dir)


def _bulk_insert_resolved_types(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "resolved_types.json")
    if not rows:
        return
    bulk_insert(conn, "resolved_types",
        ["file", "object", "proc_name", "var_name", "raw_type",
         "resolved_kind", "resolved_target", "is_parameter", "scope_line"],
        [
            (
                r["file"], r["object"], r["procName"], r["varName"],
                r["rawType"], r["kind"], r.get("target"),
                r["isParam"], r.get("scopeLine"),
            )
            for r in rows
        ],
    )


def _bulk_insert_resolved_calls(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "resolved_calls.json")
    if not rows:
        return
    conn.execute("ALTER TABLE resolved_calls ADD COLUMN IF NOT EXISTS return_type TEXT")
    bulk_insert(conn, "resolved_calls",
        ["file", "object", "from_proc", "to_name", "call_type",
         "call_line", "target_object", "target_proc",
         "resolution_kind", "confidence", "return_type"],
        [
            (
                r["file"], r["object"], r["fromProc"], r["toName"],
                r["callType"], r.get("line"),
                r.get("targetObject"), r.get("targetProc"),
                r["kind"], r["confidence"], None,
            )
            for r in rows
        ],
    )


def _bulk_insert_global_vars(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "global_vars.json")
    if not rows:
        return
    bulk_insert(conn, "global_vars",
        ["file", "object", "var_name", "var_type", "modifiers", "scope"],
        [
            (
                r["file"], r["object"], r["name"], r["type"],
                " ".join(r["mods"]) if r.get("mods") else None,
                "global",
            )
            for r in rows
        ],
    )
