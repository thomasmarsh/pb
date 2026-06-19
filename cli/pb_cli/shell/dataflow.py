"""DuckDB I/O for intra-procedural data flow tables — called after type resolution."""

from __future__ import annotations

import json

from pb_cli.core.dataflow import analyze_procedure
from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn


def build_dataflow_tables(conn: Conn) -> None:
    """Iterate all procedures, run intra-procedural analysis, store results.

    Creates proc_defs and proc_uses tables.
    """
    conn.execute("TRUNCATE TABLE proc_defs")
    conn.execute("TRUNCATE TABLE proc_uses")

    rows = conn.execute(
        "SELECT file, object, name, body_json FROM procedures WHERE body_json IS NOT NULL"
    ).fetchall()

    all_defs: list[tuple] = []
    all_uses: list[tuple] = []

    for file_path, obj, name, body_json_str in rows:
        body = json.loads(body_json_str) if isinstance(body_json_str, str) else body_json_str
        if not body:
            continue
        pf = analyze_procedure(body, obj, name, file_path)
        for var, defs in pf.all_defs.items():
            for d in defs:
                all_defs.append((file_path, obj, name, var, d.block_id, d.stmt_index, d.line, d.kind))
        for var, uses in pf.all_uses.items():
            for u in uses:
                all_uses.append((file_path, obj, name, var, u.block_id, u.stmt_index, u.line, u.kind))

    _DEFS_COLS = ["file", "object", "proc_name", "var_name", "block_id", "stmt_index", "line", "kind"]
    bulk_insert(conn, "proc_defs", _DEFS_COLS, all_defs)
    bulk_insert(conn, "proc_uses", _DEFS_COLS, all_uses)
