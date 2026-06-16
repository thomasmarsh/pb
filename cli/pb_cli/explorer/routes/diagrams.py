"""DOT/SVG diagram rendering for all `pb explore` graph views."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import Response

from pb_cli.explorer.routes.dependencies import get_conn
from pb_cli.storage import (
    build_calls,
    build_dw_tables,
    build_heatmap,
    build_inheritance,
    build_proc_tables,
    build_sql_lineage,
    build_table_lineage,
)

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


def _render_diagram(kind: str, **kwargs) -> str:
    if kind == "inheritance":
        dot = build_inheritance(**kwargs)
    elif kind == "calls":
        dot = build_calls(**kwargs)
    elif kind == "dw-tables":
        dot = build_dw_tables(**kwargs)
    elif kind == "heatmap":
        dot = build_heatmap(**kwargs)
    elif kind == "sql-lineage":
        dot = build_sql_lineage(**kwargs)
    elif kind == "table-lineage":
        try:
            dot = build_table_lineage(**kwargs)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
    elif kind == "proc-tables":
        dot = build_proc_tables(**kwargs)
    else:
        raise HTTPException(status_code=400, detail=f"Unknown diagram: {kind}")

    return dot.pipe(format="svg").decode("utf-8")


@router.get("/api/diagram/{kind}")
async def get_diagram(
    kind: str,
    request: Request,
    root: str = Query("", description="Root object (inheritance)"),
    focal: str = Query("", description="Focal object (calls)"),
    depth: int = Query(2, description="Ego-graph radius (calls)"),
    table: str = Query("", description="Filter DB table (dw-tables)"),
):
    if kind not in _KINDS:
        raise HTTPException(status_code=400, detail=f"Unknown diagram: {kind}")

    conn = get_conn(request)
    try:
        kwargs: dict[str, Any] = {"conn": conn}
        if kind == "inheritance" and root:
            kwargs["root"] = root
        elif kind == "calls":
            kwargs["focal"] = focal or "fn_sqlerror"
            kwargs["depth"] = depth
        elif kind == "dw-tables" and table:
            kwargs["filter_table"] = table
        elif kind == "sql-lineage" and focal:
            kwargs["focal"] = focal
        elif kind == "table-lineage":
            kwargs["table_name"] = table or ""
        elif kind == "proc-tables":
            kwargs["table_name"] = table or ""
            if focal:
                kwargs["focal"] = focal

        svg = _render_diagram(kind, **kwargs)
        return Response(content=svg, media_type="image/svg+xml")
    finally:
        conn.close()
