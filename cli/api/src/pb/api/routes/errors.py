"""Parse-error (PowerScript/lex/SQL) browsing endpoint."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, Query
from pb.api.routes.dependencies import get_db
from pb.api.services.errors import get_error_source, list_errors

router = APIRouter()


@router.get("/api/errors")
async def list_errors_route(
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
    kind: str = Query("", description="Filter by error_kind (powerscript | sql)"),
    q: str = Query("", description="Search term"),
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    return list_errors(conn, kind=kind, q=q, limit=limit, offset=offset)


@router.get("/api/errors/source")
async def error_source_route(
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
    file: str = Query(..., description="File path"),
):
    return get_error_source(conn, file)
