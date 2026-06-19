"""DuckDB I/O for intra-procedural data flow tables — called after type resolution."""

from __future__ import annotations

import json

from pb_cli.core.dataflow import analyze_procedure
from pb_cli.shell.db import Conn


def build_dataflow_tables(conn: Conn) -> None:
    """Iterate all procedures, run intra-procedural analysis, store results.

    Creates proc_defs and proc_uses tables.
    """
    conn.execute("DROP TABLE IF EXISTS proc_defs")
    conn.execute("DROP TABLE IF EXISTS proc_uses")
    conn.execute("""
        CREATE TABLE proc_defs (
            file TEXT NOT NULL,
            object TEXT NOT NULL,
            proc_name TEXT NOT NULL,
            var_name TEXT NOT NULL,
            block_id TEXT NOT NULL,
            stmt_index INT NOT NULL,
            line INT,
            kind TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE proc_uses (
            file TEXT NOT NULL,
            object TEXT NOT NULL,
            proc_name TEXT NOT NULL,
            var_name TEXT NOT NULL,
            block_id TEXT NOT NULL,
            stmt_index INT NOT NULL,
            line INT,
            kind TEXT NOT NULL
        )
    """)

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

    if all_defs:
        conn.executemany(
            "INSERT INTO proc_defs VALUES (?,?,?,?,?,?,?,?)",
            all_defs,
        )
    if all_uses:
        conn.executemany(
            "INSERT INTO proc_uses VALUES (?,?,?,?,?,?,?,?)",
            all_uses,
        )
