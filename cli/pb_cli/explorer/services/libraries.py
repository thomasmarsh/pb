"""Library-level aggregation business logic."""

from __future__ import annotations

from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows


def _pbl_like_params(name: str) -> list[str]:
    """Return LIKE patterns that match an object whose file path starts with or contains /<name>/."""
    return [f"{name}/%", f"%/{name}/%"]


def get_library_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    like_clause = "(o.file LIKE ? OR o.file LIKE ?)"
    params = _pbl_like_params(name)

    obj_rows = rows(
        conn.execute(
            f"SELECT o.object AS name, o.kind, count(p.proc_name) AS proc_count "
            f"FROM objects o "
            f"LEFT JOIN procedures p ON p.object = o.object "
            f"WHERE {like_clause} "
            f"GROUP BY o.object, o.kind "
            f"ORDER BY o.kind, o.object",
            params,
        )
    )

    if not obj_rows:
        return None

    uncalled_row = conn.execute(
        f"SELECT count(*) "
        f"FROM procedures p "
        f"JOIN objects o ON o.object = p.object "
        f"LEFT JOIN call_sites c ON c.to_name = p.proc_name "
        f"WHERE {like_clause} AND c.to_name IS NULL",
        params,
    ).fetchone()
    uncalled_count = uncalled_row[0] if uncalled_row else 0

    return {
        "name": name,
        "objects": obj_rows,
        "object_count": len(obj_rows),
        "uncalled_proc_count": uncalled_count,
    }
