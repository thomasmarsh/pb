"""Table inventory, per-table lineage detail, and DB-wide stats."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from pb.api.routes.dependencies import get_db
from pb.api.services.tables import (
    get_table_detail,
    get_table_stats,
    list_schemas,
    list_tables,
    resolve_table_detail,
)

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


@router.get("/api/tables/{namespace}/{table_name}")
async def get_table_in_namespace(
    namespace: str,
    table_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """Canonical, unambiguous table identity: (namespace, table_name)."""
    result = get_table_detail(conn, table_name, namespace)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Table not found: {namespace}.{table_name}")
    return result


@router.get("/api/tables/{table_name}")
async def get_table(
    table_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """Bare-name lookup for callers that don't yet know the table's schema
    (a typed URL, a table name lifted from search/DW-lineage results that
    predates namespace resolution). Resolves the namespace server-side
    rather than guessing NULL -- returns 300 with the candidate namespace
    list if the name is ambiguous across schemas, never a wrong table.
    """
    result = resolve_table_detail(conn, table_name)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Table not found: {table_name}")
    if result.get("ambiguous"):
        return JSONResponse(status_code=300, content=result)
    return result


@router.get("/api/stats")
async def get_stats(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_table_stats(conn)
