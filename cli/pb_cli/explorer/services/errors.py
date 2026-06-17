"""Parse-error (PowerScript/lex/SQL) listing — extracted from route handler."""

from __future__ import annotations

from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows


def list_errors(
    conn: duckdb.DuckDBPyConnection,
    kind: str = "",
    q: str = "",
    limit: int = 200,
    offset: int = 0,
) -> dict[str, Any]:
    try:
        table_check = conn.execute(
            "SELECT 1 FROM information_schema.tables WHERE table_name = 'parse_errors'"
        ).fetchone()
    except Exception:
        table_check = None

    if not table_check:
        return {"total": 0, "offset": offset, "limit": limit, "items": []}

    conditions: list[str] = []
    params: list[Any] = []
    if kind:
        conditions.append("error_kind = ?")
        params.append(kind)
    if q:
        conditions.append("(message ILIKE ? OR file ILIKE ? OR snippet ILIKE ?)")
        params += [f"%{q}%", f"%{q}%", f"%{q}%"]
    where = "WHERE " + " AND ".join(conditions) if conditions else ""

    count_row = conn.execute(f"SELECT count(*) FROM parse_errors {where}", params).fetchone()
    total = count_row[0] if count_row else 0

    items = rows(
        conn.execute(
            f"SELECT file, error_kind, message, object, proc_name, line, snippet "
            f"FROM parse_errors {where} "
            f"ORDER BY file, line "
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
        row = conn.execute(
            "SELECT source_text FROM objects WHERE file = ? LIMIT 1",
            [file],
        ).fetchone()
    except Exception:
        row = None

    if row and row[0]:
        lines = row[0].split("\n")
        return {"lines": lines}
    return {"lines": []}
