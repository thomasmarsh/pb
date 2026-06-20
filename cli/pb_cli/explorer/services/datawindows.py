"""DataWindow business logic extracted from route handlers."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows
from pb_cli.explorer.services.objects import _get_root


def get_dw_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any]:
    controls = rows(
        conn.execute(
            "SELECT control_name, control_type, band, x, y, width, height, "
            "expression, tab_seq, source_line "
            "FROM dw_controls WHERE dw_name = ? ORDER BY band, y, x",
            [name],
        )
    )
    tables = rows(
        conn.execute("SELECT table_name FROM dw_retrieve_tables WHERE dw_name = ? ORDER BY table_name", [name])
    )
    columns = rows(
        conn.execute(
            "SELECT column_fqn, table_name, column_name "
            "FROM dw_retrieve_columns WHERE dw_name = ? ORDER BY table_name, column_name",
            [name],
        )
    )
    where = rows(
        conn.execute("SELECT idx, exp1, op, exp2, logic FROM dw_retrieve_where WHERE dw_name = ? ORDER BY idx", [name])
    )
    arguments = rows(
        conn.execute("SELECT arg_name, arg_type FROM dw_arguments WHERE dw_name = ? ORDER BY arg_name", [name])
    )
    used_by_objects = rows(conn.execute(
        "SELECT DISTINCT object FROM calls WHERE to_name = ? ORDER BY object",
        [name],
    ))
    used_by_procs = rows(conn.execute(
        "SELECT DISTINCT object, from_proc "
        "FROM calls WHERE to_name = ? AND from_proc IS NOT NULL "
        "ORDER BY object, from_proc",
        [name],
    ))

    return {
        "controls": controls,
        "retrieve_tables": [t["table_name"] for t in tables],
        "retrieve_columns": columns,
        "retrieve_where": where,
        "arguments": arguments,
        "used_by_objects": [r["object"] for r in used_by_objects],
        "used_by_procs": [{"object": r["object"], "proc": r["from_proc"]} for r in used_by_procs],
    }


def get_datawindow_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    file_rows = rows(conn.execute("SELECT DISTINCT file FROM dw_controls WHERE dw_name = ?", [name]))
    if not file_rows:
        return None

    source_file = file_rows[0]["file"]

    source_original = None
    source_rows = rows(conn.execute(
        "SELECT source_text FROM objects WHERE name = ?", [name]
    ))
    if source_rows and source_rows[0].get("source_text"):
        source_original = source_rows[0]["source_text"]

    if not source_original:
        root = _get_root(conn)
        disk_path = (root / source_file) if root else Path(source_file)
        if disk_path.exists():
            try:
                source_original = disk_path.read_text(errors="replace")
            except OSError:
                pass

    return {
        "name": name,
        "file": source_file,
        "source": source_original,
        **get_dw_detail(conn, name),
    }
