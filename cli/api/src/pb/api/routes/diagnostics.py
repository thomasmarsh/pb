"""Diagnostics (parse/ingestion error + pipeline timeline) browsing endpoint."""

from __future__ import annotations

import duckdb
from fastapi import APIRouter, Depends, Query, Request
from pb.api.routes.dependencies import get_db
from pb.api.services.diagnostics import get_error_source, list_errors

router = APIRouter()


@router.get("/api/diagnostics")
async def list_diagnostics_route(
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
    kind: str = Query("", description="Filter by error_kind (powerscript | sql)"),
    q: str = Query("", description="Search term"),
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    return list_errors(conn, kind=kind, q=q, limit=limit, offset=offset)


@router.get("/api/diagnostics/source")
async def diagnostics_source_route(
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
    file: str = Query(..., description="File path"),
):
    return get_error_source(conn, file)


@router.get("/api/diagnostics/timeline")
async def diagnostics_timeline_route(
    request: Request,
    zoom: float = Query(1.0, ge=0.25, le=20.0, description="Timeline horizontal zoom level"),
):
    """Return pipeline timeline data from the most recent indexing run.

    The zoom parameter regenerates the SVG at the requested horizontal scale
    (1.0 = default 1200px plot width, 2.0 = double width, etc.).
    """
    job = request.app.state.index_job
    if job is None:
        return {"active": False}
    snap = job.snapshot()
    # Re-render SVG at requested zoom if not default
    timeline_html = snap.get("timeline_html", "")
    if zoom != 1.0:
        timeline_html = job._collector.generate_timeline_svg(zoom=zoom)
    return {
        "active": True,
        "status": snap.get("status"),
        "elapsed_ms": snap.get("elapsed_ms"),
        "timeline_html": timeline_html,
        "steps": snap.get("steps", []),
        "current": snap.get("current"),
    }
