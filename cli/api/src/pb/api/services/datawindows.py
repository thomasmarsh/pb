"""DataWindow business logic extracted from route handlers."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import duckdb
from pb.api.routes.dependencies import rows
from pb.api.services.objects import _get_root


def get_dw_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any]:
    controls = rows(
        conn.execute(
            "SELECT name AS control_name, control_type, band, x, y, width, height, expression "
            "FROM dw_controls WHERE object = ? ORDER BY band, y, x",
            [name],
        )
    )
    try:
        tables = rows(
            conn.execute(
                "SELECT DISTINCT table_name, namespace FROM dw_retrieve_tables "
                "WHERE object = ? ORDER BY table_name",
                [name],
            )
        )
    except Exception:
        tables = []
    try:
        columns = rows(
            conn.execute(
                "SELECT column_fqn, table_name, column_name "
                "FROM dw_retrieve_columns WHERE object = ? ORDER BY table_name, column_name",
                [name],
            )
        )
    except Exception:
        columns = []
    try:
        where = rows(
            conn.execute("SELECT idx, exp1, op, exp2, logic FROM dw_retrieve_where WHERE object = ? ORDER BY idx", [name])
        )
    except Exception:
        where = []
    arguments = rows(
        conn.execute("SELECT arg_name, arg_type FROM dw_arguments WHERE object = ? ORDER BY ordinal", [name])
    )
    used_by_objects = rows(conn.execute(
        "SELECT DISTINCT object FROM call_sites WHERE to_name = ? ORDER BY object",
        [name],
    ))
    used_by_procs = rows(conn.execute(
        "SELECT DISTINCT object, proc_name "
        "FROM call_sites WHERE to_name = ? AND proc_name IS NOT NULL "
        "ORDER BY object, proc_name",
        [name],
    ))

    return {
        "controls": controls,
        "retrieve_tables": [{"table_name": t["table_name"], "namespace": t["namespace"]} for t in tables],
        "retrieve_columns": columns,
        "retrieve_where": where,
        "arguments": arguments,
        "used_by_objects": [r["object"] for r in used_by_objects],
        "used_by_procs": [{"object": r["object"], "proc": r["proc_name"]} for r in used_by_procs],
    }


def get_datawindow_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    file_rows = rows(conn.execute("SELECT DISTINCT file FROM dw_controls WHERE object = ?", [name]))
    if not file_rows:
        return None

    source_file = file_rows[0]["file"]

    source_original = None
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
