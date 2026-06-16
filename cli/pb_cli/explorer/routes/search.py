"""Global search across objects, procedures, DataWindow controls, and tables."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, Query

from pb_cli.explorer.routes.dependencies import get_db
from pb_cli.explorer.services.search import global_search

router = APIRouter()


@router.get("/api/search")
async def search(conn: duckdb.DuckDBPyConnection = Depends(get_db), q: str = Query(..., min_length=1)):
    return global_search(conn, q)
