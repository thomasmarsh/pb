"""DOT/SVG diagram endpoints — thin route layer, delegates to shell.diagrams."""

from __future__ import annotations

from typing import Any

import duckdb
import graphviz
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import Response

from pb_cli.core.cfg_builder import build_cfg, compute_node_states
from pb_cli.core.cfg_renderer import cfg_to_dot
from pb_cli.explorer.routes.dependencies import get_db
from pb_cli.shell.diagrams import render_svg

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
async def get_cfg_diagram(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    import json as _json

    row = conn.execute(
        "SELECT body_json FROM procedures WHERE object = ? AND name = ? LIMIT 1",
        [object_name, proc_name],
    ).fetchone()
    if not row or not row[0]:
        raise HTTPException(status_code=404, detail="Procedure not found or has no body")

    body = _json.loads(row[0])
    cfg = build_cfg(body)

    node_states = compute_node_states(cfg)

    dot = cfg_to_dot(cfg, node_states)
    try:
        svg = dot.pipe(format="svg").decode("utf-8")
    except graphviz.backend.execute.ExecutableNotFound:
        raise HTTPException(status_code=503, detail="graphviz 'dot' binary not found on PATH")

    def _stmt_label(s: dict) -> str:
        tag = s.get("node", {}).get("tag", "?")
        line = s.get("line", "")
        return f"L{line} {tag}" if line else tag

    block_details = [
        {
            "blockId": bid,
            "firstLine": block.first_line,
            "lastLine": block.last_line,
            "stmts": [_stmt_label(s) for s in block.stmts],
        }
        for bid, block in cfg.blocks.items()
    ]

    return {
        "svg": svg,
        "nodeStates": [{"blockId": bid, "state": s} for bid, s in node_states.items()],
        "blocks": block_details,
    }
