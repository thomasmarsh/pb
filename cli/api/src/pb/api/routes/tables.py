"""Table inventory, per-table lineage detail, and DB-wide stats."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query
from pb.api.routes.dependencies import get_db
from pb.api.services.tables import get_table_detail, get_table_stats, list_schemas, list_tables

router = APIRouter()


@router.get("/api/schemas")
async def list_schemas_route(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return list_schemas(conn)


@router.get("/api/tables")
async def list_tables_route(
    namespace: str = Query("", description="Schema/namespace to scope the table list to, if any"),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return list_tables(conn, namespace or None)


@router.get("/api/tables/{table_name}")
async def get_table(
    table_name: str,
    namespace: str = Query("", description="Schema/namespace the table belongs to, if any"),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    result = get_table_detail(conn, table_name, namespace or None)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Table not found: {table_name}")
    return result


@router.get("/api/stats")
async def get_stats(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_table_stats(conn)
