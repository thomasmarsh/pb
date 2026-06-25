"""Table inventory, per-table lineage detail, and DB-wide stats."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException
from pb.api.routes.dependencies import get_db
from pb.api.services.tables import get_table_detail, get_table_stats, list_tables

router = APIRouter()


@router.get("/api/tables")
async def list_tables_route(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return list_tables(conn)


@router.get("/api/tables/{table_name}")
async def get_table(table_name: str, conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    result = get_table_detail(conn, table_name)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Table not found: {table_name}")
    return result


@router.get("/api/stats")
async def get_stats(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_table_stats(conn)
