"""DOT/SVG diagram endpoints — thin route layer, delegates to services.diagrams."""

from __future__ import annotations

from typing import Any

import duckdb
import graphviz
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import Response
from pb.api.routes.dependencies import get_db
from pb.api.services.diagrams import get_cfg_diagram
from pb.pipeline.diagrams import render_svg

router = APIRouter()

_KINDS = (
    "inheritance",
    "calls",
    "dw-tables",
    "heatmap",
    "sql-lineage",
    "table-lineage",
    "proc-tables",
)


@router.get("/api/diagram/{kind}")
async def get_diagram(
    kind: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
    root: str = Query("", description="Root object (inheritance)"),
    focal: str = Query("", description="Focal object (calls)"),
    depth: int = Query(2, description="Ego-graph radius (calls)"),
    table: str = Query("", description="Filter DB table (dw-tables)"),
    dw: str = Query("", description="Filter by DW name (dw-tables)"),
):
    if kind not in _KINDS:
        raise HTTPException(status_code=400, detail=f"Unknown diagram: {kind}")

    params: dict[str, Any] = {}
    if kind == "inheritance" and root:
        params["root"] = root
    elif kind == "calls":
        params["focal"] = focal or "fn_sqlerror"
        params["depth"] = depth
    elif kind == "dw-tables":
        if table:
            params["filter_table"] = table
        if dw:
            params["filter_dw"] = dw
    elif kind == "sql-lineage" and focal:
        params["focal"] = focal
    elif kind == "table-lineage":
        params["table_name"] = table or ""
    elif kind == "proc-tables":
        params["table_name"] = table or ""
        if focal:
            params["focal"] = focal

    try:
        svg = render_svg(kind, conn, **params)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except graphviz.backend.execute.ExecutableNotFound:
        raise HTTPException(status_code=503, detail="graphviz 'dot' binary not found on PATH")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Diagram rendering failed: {e}") from e

    return Response(content=svg, media_type="image/svg+xml")


@router.get("/api/diagrams/cfg/{object_name}/{proc_name}")
async def get_cfg_diagram_endpoint(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    try:
        result = get_cfg_diagram(conn, object_name, proc_name)
    except graphviz.backend.execute.ExecutableNotFound:
        raise HTTPException(status_code=503, detail="graphviz 'dot' binary not found on PATH")
    if result is None:
        raise HTTPException(status_code=404, detail="Procedure not found or has no body")
    return result
