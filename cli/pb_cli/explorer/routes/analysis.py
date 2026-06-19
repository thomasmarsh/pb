"""Analysis-level endpoints (dead code, taint, slicing)."""

from __future__ import annotations

import json

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Query

from pb_cli.core.slicing import backward_slice, build_proc_def_use, forward_slice
from pb_cli.explorer.routes.dependencies import get_db, rows

router = APIRouter()


@router.get("/api/analysis/dead-code")
async def dead_code(conn: duckdb.DuckDBPyConnection = Depends(get_db)):
    items = rows(
        conn.execute(
            "SELECT p.name, p.object, p.proc_type, p.cyclomatic "
            "FROM procedures p "
            "LEFT JOIN calls c ON c.to_name = p.name "
            "WHERE c.to_name IS NULL "
            "ORDER BY p.object, p.name"
        )
    )
    return {"items": items, "total": len(items)}


# ---------------------------------------------------------------------------
# Taint paths
# ---------------------------------------------------------------------------


@router.get("/api/analysis/taint-paths")
async def get_taint_paths(
    category: str | None = None,
    severity: str | None = None,
    source_type: str | None = None,
    sink_type: str | None = None,
    object_name: str | None = None,
    proc_name: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """List taint paths with optional filters."""
    where: list[str] = []
    params: list = []

    if category is not None:
        where.append("category = ?")
        params.append(category)
    if severity is not None:
        where.append("severity = ?")
        params.append(severity)
    if source_type is not None:
        where.append("source_type = ?")
        params.append(source_type)
    if sink_type is not None:
        where.append("sink_type = ?")
        params.append(sink_type)
    if object_name is not None:
        where.append("(source_object = ? OR sink_object = ?)")
        params.extend([object_name, object_name])
    if proc_name is not None:
        where.append("(source_proc = ? OR sink_proc = ?)")
        params.extend([proc_name, proc_name])

    where_clause = ("WHERE " + " AND ".join(where)) if where else ""
    query = (
        "SELECT id, source_object, source_proc, source_var, source_line, source_type, "
        "sink_object, sink_proc, sink_var, sink_line, sink_type, severity, category "
        f"FROM taint_paths {where_clause} ORDER BY id LIMIT ?"
    )
    path_rows = rows(conn.execute(query, params + [limit]))

    count_query = f"SELECT COUNT(*) FROM taint_paths {where_clause}"
    total = conn.execute(count_query, params).fetchone()[0]

    paths = [
        {
            "id": r["id"],
            "source": {
                "object": r["source_object"],
                "proc": r["source_proc"],
                "var": r["source_var"],
                "line": r["source_line"],
                "type": r["source_type"],
            },
            "sink": {
                "object": r["sink_object"],
                "proc": r["sink_proc"],
                "var": r["sink_var"],
                "line": r["sink_line"],
                "type": r["sink_type"],
                "severity": r["severity"],
            },
            "severity": r["severity"],
            "category": r["category"],
        }
        for r in path_rows
    ]
    return {"paths": paths, "total": total}


@router.get("/api/analysis/taint-paths/{path_id}")
async def get_taint_path(
    path_id: int,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """Single taint path with full step details."""
    path_rows = rows(
        conn.execute("SELECT * FROM taint_paths WHERE id = ?", [path_id])
    )
    if not path_rows:
        raise HTTPException(status_code=404, detail=f"Taint path {path_id} not found")
    r = path_rows[0]
    steps = json.loads(r["steps_json"]) if r.get("steps_json") else []
    return {
        "id": r["id"],
        "source": {
            "object": r["source_object"],
            "proc_name": r["source_proc"],
            "var": r["source_var"],
            "line": r["source_line"],
            "type": r["source_type"],
        },
        "sink": {
            "object": r["sink_object"],
            "proc_name": r["sink_proc"],
            "var": r["sink_var"],
            "line": r["sink_line"],
            "type": r["sink_type"],
            "severity": r["severity"],
        },
        "severity": r["severity"],
        "category": r["category"],
        "steps": steps,
    }


# ---------------------------------------------------------------------------
# Program slicing
# ---------------------------------------------------------------------------


@router.get("/api/analysis/slice/{object_name}/{proc_name}/{line}")
async def get_slice(
    object_name: str,
    proc_name: str,
    line: int,
    direction: str = Query(default="backward", pattern="^(backward|forward)$"),
    var: str | None = None,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """Program slice from expression at given line."""
    proc_defs = rows(conn.execute("SELECT * FROM proc_defs"))
    proc_uses = rows(conn.execute("SELECT * FROM proc_uses"))
    interproc = rows(conn.execute("SELECT * FROM interproc_edges"))

    pdu = build_proc_def_use(proc_defs, proc_uses)

    if direction == "backward":
        result = backward_slice(object_name, proc_name, line, var, pdu, interproc)
    else:
        result = forward_slice(object_name, proc_name, line, var, pdu, interproc)

    return {
        "origin": {
            "object": result.origin_object,
            "proc": result.origin_proc,
            "line": result.origin_line,
            "var": result.origin_var,
        },
        "direction": result.direction,
        "steps": [
            {
                "object": s.object,
                "proc": s.proc_name,
                "line": s.line,
                "var": s.var_name,
                "kind": s.step_kind,
                "text": s.statement_text,
            }
            for s in result.steps
        ],
        "procedures_traversed": result.procedures_traversed,
    }


# ---------------------------------------------------------------------------
# Taint annotations
# ---------------------------------------------------------------------------


@router.get("/api/analysis/taint-annotations/{object_name}/{proc_name}")
async def get_taint_annotations(
    object_name: str,
    proc_name: str,
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """Per-block taint annotations for CFG coloring."""
    ann_rows = rows(
        conn.execute(
            "SELECT block_id, is_taint_entry, is_taint_sink, tainted_vars "
            "FROM taint_annotations "
            "WHERE object = ? AND proc_name = ? "
            "ORDER BY block_id",
            [object_name, proc_name],
        )
    )
    if not ann_rows:
        raise HTTPException(
            status_code=404,
            detail=f"No taint annotations for {object_name}.{proc_name}",
        )
    annotations = [
        {
            "blockId": r["block_id"],
            "isTaintEntry": r["is_taint_entry"],
            "isTaintSink": r["is_taint_sink"],
            "taintedVars": json.loads(r["tainted_vars"]) if r.get("tainted_vars") else [],
        }
        for r in ann_rows
    ]
    return {"annotations": annotations}


# ---------------------------------------------------------------------------
# Sources and sinks
# ---------------------------------------------------------------------------


@router.get("/api/analysis/sources")
async def get_taint_sources(
    source_type: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """List all taint sources."""
    where = "WHERE source_type = ?" if source_type is not None else ""
    params = [source_type] if source_type is not None else []
    src_rows = rows(
        conn.execute(
            f"SELECT * FROM taint_sources {where} ORDER BY object, proc_name, line LIMIT ?",
            params + [limit],
        )
    )
    total = conn.execute(
        f"SELECT COUNT(*) FROM taint_sources {where}", params
    ).fetchone()[0]
    return {"sources": src_rows, "total": total}


@router.get("/api/analysis/sinks")
async def get_taint_sinks(
    sink_type: str | None = None,
    severity: str | None = None,
    limit: int = Query(default=100, le=1000),
    conn: duckdb.DuckDBPyConnection = Depends(get_db),
):
    """List all taint sinks."""
    where: list[str] = []
    params: list = []
    if sink_type is not None:
        where.append("sink_type = ?")
        params.append(sink_type)
    if severity is not None:
        where.append("severity = ?")
        params.append(severity)
    where_clause = ("WHERE " + " AND ".join(where)) if where else ""
    sink_rows = rows(
        conn.execute(
            f"SELECT * FROM taint_sinks {where_clause} ORDER BY object, proc_name, line LIMIT ?",
            params + [limit],
        )
    )
    total = conn.execute(
        f"SELECT COUNT(*) FROM taint_sinks {where_clause}", params
    ).fetchone()[0]
    return {"sinks": sink_rows, "total": total}
