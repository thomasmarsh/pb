"""Search business logic extracted from route handlers."""

from __future__ import annotations

from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows


def global_search(conn: duckdb.DuckDBPyConnection, q: str) -> dict[str, Any]:
    like = f"%{q}%"
    objects = rows(
        conn.execute(
            "SELECT name, kind, file FROM objects WHERE name ILIKE ? OR file ILIKE ? ORDER BY name LIMIT 50",
            [like, like],
        )
    )
    procs = rows(
        conn.execute(
            "SELECT object, proc_type, name, modifiers, start_line "
            "FROM procedures "
            "WHERE name ILIKE ? OR object ILIKE ? "
            "ORDER BY name LIMIT 50",
            [like, like],
        )
    )
    dw = rows(
        conn.execute(
            "SELECT DISTINCT dw_name, control_name, control_type "
            "FROM dw_controls "
            "WHERE dw_name ILIKE ? OR control_name ILIKE ? "
            "LIMIT 50",
            [like, like],
        )
    )
    tables = rows(
        conn.execute(
            "SELECT DISTINCT table_name, "
            "  count(*) FILTER (WHERE source='datawindow')  AS dw_count, "
            "  count(*) FILTER (WHERE source='powerscript') AS ps_count "
            "FROM all_sql_tables "
            "WHERE lower(table_name) LIKE ? "
            "GROUP BY table_name ORDER BY (dw_count+ps_count) DESC LIMIT 20",
            [f"%{q.lower()}%"],
        )
    )
    return {"objects": objects, "procedures": procs, "datawindows": dw, "tables": tables}
