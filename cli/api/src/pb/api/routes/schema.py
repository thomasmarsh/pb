"""`Sch` views (Plan 153 D1 + D2 + D4 + D6) — thin route layer, delegates to services.schema."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query
from pb.api.models import (
    ColumnAffinityResponse,
    ColumnUsageResponse,
    CoUpdateRitualsResponse,
    FkGraphResponse,
    ProcedureFootprintResponse,
)
from pb.api.routes.dependencies import get_db
from pb.api.services.schema import (
    get_co_update_rituals,
    get_column_affinity,
    get_column_managers,
    get_column_usage,
    get_fk_graph,
    get_procedure_footprint,
)

router = APIRouter()


@router.get("/api/schema/co-update-rituals", response_model=CoUpdateRitualsResponse)
async def get_co_update_rituals_route(
    min_support: int = Query(2, ge=1, description="Minimum co-write statement count to qualify as a ritual"),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_co_update_rituals(conn, min_support)


@router.get("/api/schema/fk-graph", response_model=FkGraphResponse)
async def get_fk_graph_route(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_fk_graph(conn)


@router.get("/api/schema/column-usage", response_model=ColumnUsageResponse)
async def get_column_usage_route(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_column_usage(conn)


@router.get(
    "/api/schema/footprint/{object_name}/{proc_name}",
    response_model=ProcedureFootprintResponse,
)
async def get_procedure_footprint_route(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    result = get_procedure_footprint(conn, object_name, proc_name)
    if result is None:
        raise HTTPException(
            status_code=404,
            detail=f"Procedure not found: {object_name}.{proc_name}",
        )
    return result


@router.get("/api/schema/column-affinity/{table_name}", response_model=ColumnAffinityResponse)
async def get_column_affinity_route(
    table_name: str,
    namespace: str = Query("", description="Table namespace/schema, if any"),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    result = get_column_affinity(conn, namespace or None, table_name)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Table not found: {table_name}")
    return result


@router.get("/api/schema/column-managers/{table_name}/{column_name}")
async def get_column_managers_route(
    table_name: str,
    column_name: str,
    namespace: str = Query("", description="Table namespace/schema, if any"),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_column_managers(conn, namespace or None, table_name, column_name)
