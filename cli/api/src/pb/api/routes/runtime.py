"""Runtime support endpoints — DW query map for the instruction-graph interpreter."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends
from pb.api.routes.dependencies import get_db
from pb.api.services.objects import get_dw_queries

router = APIRouter()


@router.get("/api/runtime/dw-queries")
async def get_dw_queries_route(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_dw_queries(conn)
