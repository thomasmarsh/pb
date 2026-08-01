"""Analysis-level endpoints (dead code, taint, slicing)."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query
from pb.api.models import LiveProceduresResponse
from pb.api.routes.dependencies import get_db
from pb.api.services.analysis import (
    get_code_quality_report,
    get_dead_code,
    get_dead_vars,
    get_explain_pseudocode,
    get_live_procedures,
    get_program_slice,
    get_sql_lint_summary,
    get_taint_annotations,
    get_taint_path,
    get_taint_paths,
    get_taint_sinks,
    get_taint_sources,
    get_type_coverage,
    get_type_mismatches,
)

router = APIRouter()


@router.get("/api/analysis/dead-code")
async def dead_code(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    items = get_dead_code(conn)
    return {"items": items, "total": len(items)}


@router.get("/api/analysis/dead-vars")
async def dead_vars(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    items = get_dead_vars(conn)
    return {"items": items, "total": len(items)}


@router.get("/api/analysis/type-mismatches")
async def type_mismatches(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    items = get_type_mismatches(conn)
    return {"items": items, "total": len(items)}


@router.get("/api/analysis/type-coverage")
async def type_coverage(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_type_coverage(conn)


@router.get("/api/analysis/live-procedures", response_model=LiveProceduresResponse)
async def live_procedures(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    items = get_live_procedures(conn)
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


@router.get("/api/analysis/explain/{object_name}/{proc_name}")
async def explain_pseudocode(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    result = get_explain_pseudocode(conn, object_name, proc_name)
    if result is None:
        raise HTTPException(
            status_code=404,
            detail=f"No pseudocode for {object_name}.{proc_name}",
        )
    return result


@router.get("/api/analysis/sources")
async def taint_sources(
    source_type: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_taint_sources(conn, source_type=source_type, limit=limit)


@router.get("/api/analysis/report")
async def code_quality_report(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_code_quality_report(conn)


@router.get("/api/analysis/sql-lint")
async def sql_lint(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    return get_sql_lint_summary(conn)


@router.get("/api/analysis/sinks")
async def taint_sinks(
    sink_type: str | None = None,
    severity: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    return get_taint_sinks(conn, sink_type=sink_type, severity=severity, limit=limit)
