"""Analysis-level endpoints (dead code, taint, slicing)."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query

from pb_cli.explorer.routes.dependencies import get_db
from pb_cli.explorer.services.analysis import (
    get_dead_code,
    get_program_slice,
    get_taint_annotations,
    get_taint_path,
    get_taint_paths,
    get_taint_sinks,
    get_taint_sources,
)

router = APIRouter()


@router.get("/api/analysis/dead-code")
async def dead_code(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    items = get_dead_code(conn)
    return {"items": items, "total": len(items)}


@router.get("/api/analysis/taint-paths")
async def taint_paths(
    category: str | None = None,
    severity: str | None = None,
    source_type: str | None = None,
    sink_type: str | None = None,
    object_name: str | None = None,
    proc_name: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_taint_paths(
        conn,
        category=category,
        severity=severity,
        source_type=source_type,
        sink_type=sink_type,
        object_name=object_name,
        proc_name=proc_name,
        limit=limit,
    )


@router.get("/api/analysis/taint-paths/{path_id}")
async def taint_path_detail(
    path_id: int,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    result = get_taint_path(conn, path_id)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Taint path {path_id} not found")
    return result


@router.get("/api/analysis/slice/{object_name}/{proc_name}/{line}")
async def slice_endpoint(
    object_name: str,
    proc_name: str,
    line: int,
    direction: str = Query(default="backward", pattern="^(backward|forward)$"),
    var: str | None = None,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_program_slice(
        conn, object_name, proc_name, line, direction=direction, var=var,
    )


@router.get("/api/analysis/taint-annotations/{object_name}/{proc_name}")
async def taint_annotations(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    result = get_taint_annotations(conn, object_name, proc_name)
    if result is None:
        raise HTTPException(
            status_code=404,
            detail=f"No taint annotations for {object_name}.{proc_name}",
        )
    return result


@router.get("/api/analysis/sources")
async def taint_sources(
    source_type: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_taint_sources(conn, source_type=source_type, limit=limit)


@router.get("/api/analysis/sinks")
async def taint_sinks(
    sink_type: str | None = None,
    severity: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_taint_sinks(conn, sink_type=sink_type, severity=severity, limit=limit)
