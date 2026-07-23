"""Search business logic extracted from route handlers."""

from __future__ import annotations

from typing import Any

import duckdb
from pb.api.routes.dependencies import rows


def global_search(conn: duckdb.DuckDBPyConnection, q: str) -> dict[str, Any]:
    like = f"%{q}%"
    objects = rows(
        conn.execute(
            "SELECT object AS name, kind, file FROM objects WHERE object ILIKE ? OR file ILIKE ? ORDER BY object LIMIT 50",
            [like, like],
        )
    )
    procs = rows(
        conn.execute(
            "SELECT object, proc_type, proc_name AS name, start_line "
            "FROM procedures "
            "WHERE proc_name ILIKE ? OR object ILIKE ? "
            "ORDER BY proc_name LIMIT 50",
            [like, like],
        )
    )
    dw = rows(
        conn.execute(
            "SELECT DISTINCT object, name AS control_name, control_type "
            "FROM dw_controls "
            "WHERE object ILIKE ? OR name ILIKE ? "
            "LIMIT 50",
            [like, like],
        )
    )
    tables = rows(
        conn.execute(
            "SELECT table_name, namespace, "
            "  count(*) FILTER (WHERE source='datawindow')  AS dw_count, "
            "  count(*) FILTER (WHERE source='powerscript') AS ps_count "
            "FROM all_sql_tables "
            "WHERE lower(table_name) LIKE ? "
            "GROUP BY table_name, namespace ORDER BY (dw_count+ps_count) DESC LIMIT 20",
            [f"%{q.lower()}%"],
        )
    )
    return {"objects": objects, "procedures": procs, "datawindows": dw, "tables": tables}
