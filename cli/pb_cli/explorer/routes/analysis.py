"""Analysis-level endpoints (dead code, etc.)."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends

from pb_cli.explorer.routes.dependencies import get_db, rows

router = APIRouter()


@router.get("/api/analysis/dead-code")
async def dead_code(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    items = rows(
        conn.execute(
            "SELECT p.name, p.object, p.proc_type, p.cyclomatic "
            "FROM procedures p "
            "LEFT JOIN calls c ON c.to_name = p.name "
            "WHERE c.to_name IS NULL "
            "ORDER BY p.object, p.name"
        )
    )
    return {"items": items, "total": len(items)}
