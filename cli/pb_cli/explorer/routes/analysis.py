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
    # Reachability from runtime entry points (event/on handlers) via call graph.
    # Three arms in call_edges:
    #   same-object: calls.object + to_name matched against procedures in same object
    #   cross-object: resolved_calls rows that have target_object/target_proc filled
    #   override: if B.m is reachable and C inherits B and defines m, C.m is reachable
    # Remaining false negatives: cross-object calls with no target_object in resolved_calls
    # (unresolved virtual dispatch where the receiver type is unknown).
    items = rows(
        conn.execute("""
            WITH RECURSIVE
            -- Materialise all directed call edges before the recursion so that
            -- the recursive CTE only needs a single self-reference.
            call_edges(caller_obj, caller_proc, callee_obj, callee_proc) AS (
                -- Same-object calls: callee lives in the same object as the caller
                SELECT c.object, c.from_proc, p2.object, p2.name
                FROM calls c
                JOIN procedures p2 ON p2.object = c.object AND p2.name = c.to_name
                UNION ALL
                -- Cross-object calls: use target_object/target_proc from resolved_calls
                SELECT rc.object, rc.from_proc, rc.target_object, rc.target_proc
                FROM resolved_calls rc
                WHERE rc.target_object IS NOT NULL AND rc.target_proc IS NOT NULL
                UNION ALL
                -- Override edges: if B.m is a call edge target and C inherits from B
                -- and overrides m, add B.m → C.m so virtual dispatch is modelled.
                -- The recursive reachable CTE then propagates through these transitively.
                SELECT p1.object, p1.name, p2.object, p2.name
                FROM procedures p1
                JOIN inherits inh ON inh.to_object = p1.object
                JOIN procedures p2 ON p2.object = inh.from_object AND p2.name = p1.name
            ),
            reachable(obj, proc) AS (
                SELECT object, name FROM procedures WHERE proc_type IN ('event', 'on')
                UNION
                SELECT e.callee_obj, e.callee_proc
                FROM call_edges e
                JOIN reachable r ON r.obj = e.caller_obj AND r.proc = e.caller_proc
            )
            SELECT p.name, p.object, p.proc_type, p.cyclomatic
            FROM procedures p
            WHERE NOT EXISTS (
                SELECT 1 FROM reachable r WHERE r.obj = p.object AND r.proc = p.name
            )
            ORDER BY p.object, p.name
        """)
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
    # Interproc edges are bounded by call count, safe to load fully.
    interproc = rows(conn.execute("SELECT * FROM interproc_edges"))

    # Fetch defs/uses only for the origin procedure and its immediate
    # inter-procedural neighbors, rather than the whole corpus.
    related: set[tuple[str, str]] = {(object_name, proc_name)}
    for e in interproc:
        if e["caller_object"] == object_name and e["caller_proc"] == proc_name:
            related.add((e["callee_object"], e["callee_proc"]))
        elif e["callee_object"] == object_name and e["callee_proc"] == proc_name:
            related.add((e["caller_object"], e["caller_proc"]))

    proc_defs: list[dict] = []
    proc_uses: list[dict] = []
    for obj, proc in related:
        proc_defs.extend(rows(conn.execute(
            "SELECT * FROM proc_defs WHERE object = ? AND proc_name = ?",
            [obj, proc],
        )))
        proc_uses.extend(rows(conn.execute(
            "SELECT * FROM proc_uses WHERE object = ? AND proc_name = ?",
            [obj, proc],
        )))

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
