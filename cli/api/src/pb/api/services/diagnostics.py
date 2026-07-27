"""Parse-error listing — extracted from route handler."""

from __future__ import annotations

from typing import Any

import duckdb
from pb.api.routes.dependencies import rows

# Union CTE: PowerScript parse errors + SQL parse errors (parse_ok = false).
# Columns: file, error_kind, message, object, proc_name, line, snippet.
_ERRORS_CTE = """
WITH all_errors AS (
    SELECT
        file,
        'powerscript'    AS error_kind,
        error            AS message,
        NULL             AS object,
        NULL             AS proc_name,
        line,
        NULL             AS snippet
    FROM parse_errors
    UNION ALL
    SELECT
        file,
        'sql'            AS error_kind,
        COALESCE(error, raw_sql) AS message,
        object,
        proc_name,
        line,
        raw_sql          AS snippet
    FROM sql_statements
    WHERE NOT parse_ok
)
"""


def list_errors(
    conn: duckdb.DuckDBPyConnection,
    kind: str = "",
    q: str = "",
    limit: int = 200,
    offset: int = 0,
) -> dict[str, Any]:
    try:
        conn.execute("SELECT 1 FROM parse_errors LIMIT 0")
    except Exception:
        return {"total": 0, "offset": offset, "limit": limit, "items": []}

    conditions: list[str] = []
    params: list[Any] = []
    if kind and kind != "all":
        conditions.append("error_kind = ?")
        params.append(kind)
    if q:
        conditions.append("(file ILIKE ? OR message ILIKE ? OR object ILIKE ?)")
        params += [f"%{q}%", f"%{q}%", f"%{q}%"]
    where = "WHERE " + " AND ".join(conditions) if conditions else ""

    count_row = conn.execute(
        f"{_ERRORS_CTE} SELECT count(*) FROM all_errors {where}", params
    ).fetchone()
    total = count_row[0] if count_row else 0

    items = rows(
        conn.execute(
            f"{_ERRORS_CTE}"
            f"SELECT file, error_kind, message, object, proc_name, line, snippet "
            f"FROM all_errors {where} "
            f"ORDER BY error_kind, file, line "
            f"LIMIT ? OFFSET ?",
            params + [limit, offset],
        )
    )
    return {"total": total, "offset": offset, "limit": limit, "items": items}


def get_error_source(
    conn: duckdb.DuckDBPyConnection,
    file: str,
) -> dict[str, Any]:
    """Return the full source text for a file, used to show SQL error context."""
    try:
        src_row = conn.execute(
            "SELECT lines FROM source_files WHERE file = ?", [file]
        ).fetchone()
        if src_row and src_row[0]:
            return {"lines": src_row[0].splitlines()}
    except Exception:
        pass
    return {"lines": []}
