"""Procedure detail — raw source view and full AST/SQL explore view."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException

from pb_cli.explorer.routes.dependencies import get_db
from pb_cli.explorer.services.procedures import get_procedure_detail, get_procedure_explore, list_procedures

router = APIRouter()


@router.get("/api/procedures")
async def list_procedures_route(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return list_procedures(conn)


@router.get("/api/procedures/{object_name}/{proc_name}")
async def get_procedure(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    proc = get_procedure_detail(conn, object_name, proc_name)
    if proc is None:
        raise HTTPException(
            status_code=404,
            detail=f"Procedure not found: {object_name}.{proc_name}",
        )
    return proc


@router.get("/api/explore/procedure/{object_name}/{proc_name}")
async def explore_procedure(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    result = get_procedure_explore(conn, object_name, proc_name)
    if result is None:
        raise HTTPException(status_code=404, detail="Procedure not found")
    return result
