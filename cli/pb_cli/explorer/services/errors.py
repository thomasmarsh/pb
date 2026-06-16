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
