"""API routes for pb explore."""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

import duckdb
import graphviz
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, Response

from pb_cli.build import get_queries_dir
from pb_cli.diagram import (
    apply_defaults,
    build_calls,
    build_dw_tables,
    build_heatmap,
    build_inheritance,
)

router = APIRouter()


def _conn(request: Request) -> duckdb.DuckDBPyConnection:
    db_path: str = request.app.state.db_path
    if not os.path.exists(db_path):
        raise HTTPException(status_code=503, detail=f"Database not found: {db_path}")
    return duckdb.connect(db_path, read_only=True)


def _rows(cursor: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    cols = [d[0] for d in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]


def _query_info(name: str) -> tuple[str, list[tuple[str, str, str | None]], str]:
    sql_file = get_queries_dir() / f"{name}.sql"
    if not sql_file.exists():
        raise HTTPException(status_code=404, detail=f"Query not found: {name}")
    lines = sql_file.read_text().splitlines()
    description = ""
    params: list[tuple[str, str, str | None]] = []
    sql_start = len(lines)
    for i, raw in enumerate(lines):
        line = raw.strip()
        if not line.startswith("--"):
            sql_start = i
            break
        m = re.match(r"^--\s+:(\w+)\s+(\w+)(?:\s+(\S+))?$", line)
        if m:
            params.append((m.group(1), m.group(2).upper(), m.group(3)))
        elif not description:
            description = line.lstrip("-").strip()
    return description, params, "\n".join(lines[sql_start:]).strip()


# ── SPA ────────────────────────────────────────────────────────────────────────

@router.get("/", response_class=HTMLResponse)
async def index():
    html_path = Path(__file__).parent / "static" / "index.html"
    return HTMLResponse(content=html_path.read_text())


# ── Objects ────────────────────────────────────────────────────────────────────

@router.get("/api/objects")
async def list_objects(
    request: Request,
    q: str = Query("", description="Search term"),
    kind: str = Query("", description="Filter by kind"),
    sort: str = Query("name", description="Sort column"),
    order: str = Query("asc", description="Sort direction"),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    conn = _conn(request)
    try:
        conditions = []
        params: list[Any] = []
        if q:
            conditions.append("(o.name ILIKE ? OR o.file ILIKE ?)")
            params += [f"%{q}%", f"%{q}%"]
        if kind:
            conditions.append("o.kind = ?")
            params.append(kind)
        where = "WHERE " + " AND ".join(conditions) if conditions else ""

        safe_sorts = {"name", "kind", "file"}
        sort_col = sort if sort in safe_sorts else "name"
        sort_dir = "DESC" if order.lower() == "desc" else "ASC"

        count_row = conn.execute(
            f"SELECT count(*) FROM objects o {where}", params
        ).fetchone()
        total = count_row[0] if count_row else 0

        rows = _rows(conn.execute(
            f"SELECT o.name, o.kind, o.file, o.ancestor "
            f"FROM objects o {where} "
            f"ORDER BY o.{sort_col} {sort_dir} "
            f"LIMIT ? OFFSET ?",
            params + [limit, offset],
        ))
        return {"total": total, "offset": offset, "limit": limit, "items": rows}
    finally:
        conn.close()


@router.get("/api/objects/{name}")
async def get_object(name: str, request: Request):
    conn = _conn(request)
    try:
        obj_rows = _rows(conn.execute(
            "SELECT name, kind, file, ancestor FROM objects WHERE name = ?", [name]
        ))
        if not obj_rows:
            raise HTTPException(status_code=404, detail=f"Object not found: {name}")
        obj = obj_rows[0]

        metrics = _rows(conn.execute(
            "SELECT * FROM object_metrics WHERE object = ?", [name]
        ))
        obj["metrics"] = metrics[0] if metrics else None

        procs = _rows(conn.execute(
            "SELECT object, proc_type, name, modifiers, params, return_type, "
            "start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? ORDER BY proc_type, name", [name]
        ))
        obj["procedures"] = procs

        ancestors = _rows(conn.execute(
            "SELECT to_object AS parent FROM inherits WHERE from_object = ?", [name]
        ))
        obj["ancestors"] = [a["parent"] for a in ancestors]

        descendants = _rows(conn.execute(
            "SELECT from_object AS child FROM inherits WHERE to_object = ?", [name]
        ))
        obj["descendants"] = [d["child"] for d in descendants]

        callers = _rows(conn.execute(
            "SELECT DISTINCT object AS caller FROM calls WHERE to_name = ?", [name]
        ))
        obj["callers"] = [c["caller"] for c in callers]

        callees = _rows(conn.execute(
            "SELECT DISTINCT to_name AS callee FROM calls WHERE object = ?", [name]
        ))
        obj["callees"] = [c["callee"] for c in callees]

        return obj
    finally:
        conn.close()


@router.get("/api/objects/{name}/source")
async def get_object_source(name: str, request: Request):
    conn = _conn(request)
    try:
        obj_rows = _rows(conn.execute(
            "SELECT name, kind, file, source_text FROM objects WHERE name = ?", [name]
        ))
        if not obj_rows:
            raise HTTPException(status_code=404, detail=f"Object not found: {name}")

        file_path = obj_rows[0]["file"]
        lines = []
        if file_path and os.path.exists(file_path):
            try:
                with open(file_path, "r", errors="replace") as f:
                    lines = f.read().splitlines()
            except OSError:
                pass
        if not lines and obj_rows[0].get("source_text"):
            lines = obj_rows[0]["source_text"].splitlines()

        procs = _rows(conn.execute(
            "SELECT name, proc_type, modifiers, params, return_type, "
            "start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? "
            "AND start_line IS NOT NULL AND end_line IS NOT NULL "
            "ORDER BY start_line",
            [name],
        ))

        known_objects = _rows(conn.execute(
            "SELECT name, kind FROM objects WHERE name != ? ORDER BY name", [name]
        ))

        known_procs = _rows(conn.execute(
            "SELECT DISTINCT p.name, p.object, p.proc_type "
            "FROM procedures p "
            "JOIN calls c ON c.to_name = p.name "
            "WHERE c.object = ? "
            "UNION "
            "SELECT DISTINCT p.name, p.object, p.proc_type "
            "FROM procedures p "
            "WHERE p.object = ? AND p.proc_type IN ('function', 'subroutine') "
            "ORDER BY p.name",
            [name, name],
        ))

        return {
            "file": file_path,
            "lines": lines,
            "source_available": bool(lines),
            "procedures": procs,
            "knownObjects": known_objects,
            "knownProcs": known_procs,
        }
    finally:
        conn.close()


# ── Procedures ─────────────────────────────────────────────────────────────────

@router.get("/api/procedures/{object_name}/{proc_name}")
async def get_procedure(object_name: str, proc_name: str, request: Request):
    conn = _conn(request)
    try:
        rows = _rows(conn.execute(
            "SELECT file, object, proc_type, name, modifiers, params, "
            "return_type, start_line, end_line, body_json, cyclomatic, source_rendered "
            "FROM procedures WHERE object = ? AND name = ?",
            [object_name, proc_name],
        ))
        if not rows:
            raise HTTPException(
                status_code=404,
                detail=f"Procedure not found: {object_name}.{proc_name}",
            )
        proc = rows[0]

        proc["source_rendered"] = proc.get("source_rendered") or ""

        source_file = proc.get("file")
        start = proc.get("start_line")
        end = proc.get("end_line")
        if source_file and start and end and os.path.exists(source_file):
            try:
                with open(source_file, "r", errors="replace") as f:
                    all_lines = f.readlines()
                snippet = "".join(all_lines[max(0, start - 1):end])
                proc["source_original"] = snippet
            except (OSError, IndexError):
                proc["source_original"] = None
        else:
            proc["source_original"] = None

        return proc
    finally:
        conn.close()


# ── Search ─────────────────────────────────────────────────────────────────────

@router.get("/api/search")
async def search(request: Request, q: str = Query(..., min_length=1)):
    conn = _conn(request)
    try:
        like = f"%{q}%"
        objects = _rows(conn.execute(
            "SELECT name, kind, file FROM objects "
            "WHERE name ILIKE ? OR file ILIKE ? "
            "ORDER BY name LIMIT 50",
            [like, like],
        ))
        procs = _rows(conn.execute(
            "SELECT object, proc_type, name, modifiers, start_line "
            "FROM procedures "
            "WHERE name ILIKE ? OR object ILIKE ? "
            "ORDER BY name LIMIT 50",
            [like, like],
        ))
        dw = _rows(conn.execute(
            "SELECT DISTINCT dw_name, control_name, control_type "
            "FROM dw_controls "
            "WHERE dw_name ILIKE ? OR control_name ILIKE ? "
            "LIMIT 50",
            [like, like],
        ))
        tables = _rows(conn.execute(
            "SELECT DISTINCT table_name, "
            "  count(*) FILTER (WHERE source='datawindow')  AS dw_count, "
            "  count(*) FILTER (WHERE source='powerscript') AS ps_count "
            "FROM all_sql_tables "
            "WHERE lower(table_name) LIKE ? "
            "GROUP BY table_name ORDER BY (dw_count+ps_count) DESC LIMIT 20",
            [f"%{q.lower()}%"],
        ))
        return {"objects": objects, "procedures": procs, "datawindows": dw, "tables": tables}
    finally:
        conn.close()


# ── Diagrams ───────────────────────────────────────────────────────────────────

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
        dot = _build_sql_lineage(**kwargs)
    elif kind == "table-lineage":
        dot = _build_table_lineage(**kwargs)
    else:
        raise HTTPException(status_code=400, detail=f"Unknown diagram: {kind}")

    return dot.pipe(format="svg").decode("utf-8")


_OP_COLORS = {
    "SELECT":   "#5B8DD9",
    "INSERT":   "#56A85D",
    "UPDATE":   "#fb923c",
    "DELETE":   "#f87171",
    "retrieve": "#4ade80",
}
_DEFAULT_OP_COLOR = "#B0B0B0"


def _build_sql_lineage(conn: duckdb.DuckDBPyConnection, focal=""):
    rows = conn.execute(
        "SELECT DISTINCT object, table_name, operation "
        "FROM all_sql_tables "
        "WHERE source = 'powerscript'"
        + (" AND object = ?" if focal else ""),
        [focal] if focal else [],
    ).fetchall()

    dot = graphviz.Digraph(engine="dot", name="sql_lineage")
    apply_defaults(dot)
    dot.attr(rankdir="LR", splines="ortho", nodesep="0.3", ranksep="1.2")
    dot.attr("node", shape="box", style="filled,rounded")

    seen_objects: set[str] = set()
    seen_tables: set[str] = set()

    for obj, tbl, op in rows:
        if obj not in seen_objects:
            dot.node(f"obj_{obj}", label=obj, fillcolor="#2A3050", fontcolor="#E8E8E8", fontsize="9")
            seen_objects.add(obj)
        if tbl not in seen_tables:
            dot.node(f"tbl_{tbl}", label=tbl, shape="cylinder", fillcolor="#1F2F1F",
                     fontcolor="#C8F0CA", fontsize="9")
            seen_tables.add(tbl)
        color = _OP_COLORS.get(op, _DEFAULT_OP_COLOR)
        dot.edge(f"obj_{obj}", f"tbl_{tbl}", color=color, label=op,
                 fontcolor=color, fontsize="7", penwidth="0.8")

    if not rows:
        dot.node("empty", label="No PowerScript SQL statements found",
                 shape="plaintext", fontcolor="#5c5f72")

    return dot


def _build_table_lineage(conn: duckdb.DuckDBPyConnection, table_name=""):
    if not table_name:
        raise HTTPException(status_code=400, detail="table param is required for table-lineage")

    rows = conn.execute(
        "SELECT DISTINCT object, source, operation "
        "FROM all_sql_tables WHERE table_name = ? ORDER BY source, object",
        [table_name],
    ).fetchall()

    dot = graphviz.Digraph(engine="dot", name="table_lineage")
    apply_defaults(dot)
    dot.attr(rankdir="LR", splines="ortho", nodesep="0.2", ranksep="1.4")
    dot.attr("node", shape="box", style="filled,rounded")

    dot.node("__table__", label=table_name, shape="cylinder",
             style="filled", fillcolor="#2E5E32", fontcolor="#C8F0CA", fontsize="10")

    seen_objects: set[str] = set()
    for obj, source, op in rows:
        node_id = f"obj_{obj}"
        if node_id not in seen_objects:
            is_dw = source == "datawindow"
            fill = "#2A3A4A" if is_dw else "#2A3050"
            badge = "dw" if is_dw else "ps"
            dot.node(node_id, label=f"{obj}\\n[{badge}]",
                     fillcolor=fill, fontcolor="#E8E8E8", fontsize="8")
            seen_objects.add(node_id)
        color = _OP_COLORS.get(op, _DEFAULT_OP_COLOR)
        dot.edge(node_id, "__table__", label=op, color=color, fontcolor=color,
                 fontsize="7", penwidth="0.8")

    if not rows:
        dot.node("empty", label=f"No references found for table: {table_name}",
                 shape="plaintext", fontcolor="#5c5f72")

    return dot


@router.get("/api/diagram/{kind}")
async def get_diagram(
    kind: str,
    request: Request,
    root: str = Query("", description="Root object (inheritance)"),
    focal: str = Query("", description="Focal object (calls)"),
    depth: int = Query(2, description="Ego-graph radius (calls)"),
    table: str = Query("", description="Filter DB table (dw-tables)"),
):
    if kind not in ("inheritance", "calls", "dw-tables", "heatmap", "sql-lineage", "table-lineage"):
        raise HTTPException(status_code=400, detail=f"Unknown diagram: {kind}")

    conn = _conn(request)
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

        svg = _render_diagram(kind, **kwargs)
        return Response(content=svg, media_type="image/svg+xml")
    finally:
        conn.close()


# ── DataWindow ─────────────────────────────────────────────────────────────────

@router.get("/api/dw/{name}")
async def get_datawindow(name: str, request: Request):
    conn = _conn(request)
    try:
        file_rows = _rows(conn.execute(
            "SELECT DISTINCT file FROM dw_controls WHERE dw_name = ?", [name]
        ))
        if not file_rows:
            raise HTTPException(status_code=404, detail=f"DataWindow not found: {name}")

        controls = _rows(conn.execute(
            "SELECT control_name, control_type, band, x, y, width, height, "
            "expression, tab_seq, source_line "
            "FROM dw_controls WHERE dw_name = ? ORDER BY band, y, x", [name]
        ))
        tables = _rows(conn.execute(
            "SELECT table_name FROM dw_retrieve_tables WHERE dw_name = ? ORDER BY table_name", [name]
        ))
        columns = _rows(conn.execute(
            "SELECT column_fqn, table_name, column_name "
            "FROM dw_retrieve_columns WHERE dw_name = ? ORDER BY table_name, column_name", [name]
        ))
        where = _rows(conn.execute(
            "SELECT idx, exp1, op, exp2, logic "
            "FROM dw_retrieve_where WHERE dw_name = ? ORDER BY idx", [name]
        ))
        arguments = _rows(conn.execute(
            "SELECT arg_name, arg_type FROM dw_arguments WHERE dw_name = ? ORDER BY arg_name", [name]
        ))

        source_file = file_rows[0]["file"]
        source_original = None
        if os.path.exists(source_file):
            try:
                source_original = Path(source_file).read_text(errors="replace")
            except OSError:
                pass

        return {
            "name": name,
            "file": source_file,
            "controls": controls,
            "retrieve_tables": [t["table_name"] for t in tables],
            "retrieve_columns": columns,
            "retrieve_where": where,
            "arguments": arguments,
            "source": source_original,
        }
    finally:
        conn.close()


# ── Queries ────────────────────────────────────────────────────────────────────

@router.get("/api/queries")
async def list_queries():
    queries_dir = get_queries_dir()
    if not queries_dir.is_dir():
        return {"queries": []}
    items = []
    for sql_file in sorted(queries_dir.glob("*.sql")):
        description, params, sql_body = _query_info(sql_file.stem)
        items.append({
            "name": sql_file.stem,
            "description": description,
            "params": [{"name": n, "type": t, "default": d} for n, t, d in params],
            "sql": sql_body,
        })
    return {"queries": items}


@router.get("/api/queries/{name}/run")
async def run_query(name: str, request: Request):
    description, params, sql = _query_info(name)

    conn = _conn(request)
    try:
        bound = {}
        for pname, ptype, pdefault in params:
            raw = request.query_params.get(pname)
            if raw is not None:
                bound[pname] = int(raw) if ptype in ("INT", "INTEGER", "BIGINT") else raw
            elif pdefault is not None:
                bound[pname] = int(pdefault) if ptype in ("INT", "INTEGER", "BIGINT") else pdefault

        result = conn.execute(sql, bound)
        rows = _rows(result)
        cols = [d[0] for d in result.description] if result.description else []
        return {"columns": cols, "rows": rows}
    finally:
        conn.close()


# ── Explore tree ───────────────────────────────────────────────────────────────

@router.get("/api/explore/tree")
async def explore_tree(request: Request):
    conn = _conn(request)
    try:
        obj_rows = _rows(conn.execute(
            "SELECT name, kind, file FROM objects ORDER BY kind, name"
        ))
        proc_rows = _rows(conn.execute(
            "SELECT object, proc_type, name, modifiers, params, return_type, "
            "start_line, end_line, cyclomatic "
            "FROM procedures ORDER BY object, proc_type, name"
        ))
        procs_by_obj: dict[str, list[dict[str, Any]]] = {}
        for p in proc_rows:
            procs_by_obj.setdefault(p["object"], []).append(p)

        libraries: dict[str, list[dict[str, Any]]] = {}
        for obj in obj_rows:
            fpath = obj.get("file", "")
            lib = _pbl_name(fpath)
            obj_entry = {
                "name": obj["name"],
                "kind": obj["kind"],
                "file": fpath,
                "procedures": procs_by_obj.get(obj["name"], []),
            }
            libraries.setdefault(lib, []).append(obj_entry)

        result = [
            {"name": lib, "objects": objs}
            for lib, objs in sorted(libraries.items())
        ]
        return {"libraries": result}
    finally:
        conn.close()


def _pbl_name(file_path: str) -> str:
    """Extract .pbl library name from an extracted file path."""
    parts = file_path.replace("\\", "/").split("/")
    for part in parts:
        if part.lower().endswith(".pbl"):
            return part
    if len(parts) >= 2:
        return parts[-2]
    return "(unknown)"


@router.get("/api/explore/procedure/{object_name}/{proc_name}")
async def explore_procedure(object_name: str, proc_name: str, request: Request):
    conn = _conn(request)
    try:
        rows = _rows(conn.execute(
            "SELECT body_json, source_rendered, proc_type, params, return_type, "
            "modifiers, start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? AND name = ?",
            [object_name, proc_name],
        ))
        if not rows:
            raise HTTPException(status_code=404, detail="Procedure not found")
        row = rows[0]
        body_json = row.get("body_json")
        if body_json is None:
            ast = None
        elif isinstance(body_json, str):
            ast = json.loads(body_json)
        else:
            ast = body_json

        sql_stmts = _rows(conn.execute(
            "SELECT stmt_idx, operation, raw_sql, tables, columns, "
            "has_into, has_cursor, parse_ok "
            "FROM sql_statements WHERE object = ? AND proc_name = ? ORDER BY stmt_idx",
            [object_name, proc_name],
        ))
        import sqlglot as _sqlglot
        for stmt in sql_stmts:
            raw = stmt.get("raw_sql") or ""
            try:
                stmt["formatted_sql"] = _sqlglot.transpile(
                    raw, read="oracle", write="oracle", pretty=True
                )[0]
            except Exception:
                stmt["formatted_sql"] = raw

        return {
            "ast": ast,
            "source_rendered": row.get("source_rendered") or "",
            "proc_type": row.get("proc_type"),
            "params": row.get("params"),
            "return_type": row.get("return_type"),
            "modifiers": row.get("modifiers"),
            "start_line": row.get("start_line"),
            "end_line": row.get("end_line"),
            "cyclomatic": row.get("cyclomatic"),
            "sql_statements": sql_stmts,
        }
    finally:
        conn.close()


@router.get("/api/explore/datawindow/{name}")
async def explore_datawindow(name: str, request: Request):
    conn = _conn(request)
    try:
        controls = _rows(conn.execute(
            "SELECT control_name, control_type, band, x, y, width, height, "
            "expression, tab_seq, source_line "
            "FROM dw_controls WHERE dw_name = ? ORDER BY band, y, x", [name]
        ))
        tables = _rows(conn.execute(
            "SELECT table_name FROM dw_retrieve_tables WHERE dw_name = ? ORDER BY table_name", [name]
        ))
        columns = _rows(conn.execute(
            "SELECT column_fqn, table_name, column_name "
            "FROM dw_retrieve_columns WHERE dw_name = ? ORDER BY table_name, column_name", [name]
        ))
        where = _rows(conn.execute(
            "SELECT idx, exp1, op, exp2, logic "
            "FROM dw_retrieve_where WHERE dw_name = ? ORDER BY idx", [name]
        ))
        arguments = _rows(conn.execute(
            "SELECT arg_name, arg_type FROM dw_arguments WHERE dw_name = ? ORDER BY arg_name", [name]
        ))
        return {
            "name": name,
            "controls": controls,
            "retrieve_tables": [t["table_name"] for t in tables],
            "retrieve_columns": columns,
            "retrieve_where": where,
            "arguments": arguments,
        }
    finally:
        conn.close()


# ── Tables ─────────────────────────────────────────────────────────────────────

@router.get("/api/tables")
async def list_tables(request: Request):
    conn = _conn(request)
    try:
        rows = _rows(conn.execute("""
            SELECT
                table_name,
                count(*) FILTER (WHERE source = 'datawindow')  AS dw_count,
                count(*) FILTER (WHERE source = 'powerscript') AS ps_count,
                count(DISTINCT file)                           AS file_count
            FROM all_sql_tables
            GROUP BY table_name
            ORDER BY (dw_count + ps_count) DESC, table_name
        """))
        return rows
    finally:
        conn.close()


@router.get("/api/tables/{table_name}")
async def get_table(table_name: str, request: Request):
    conn = _conn(request)
    try:
        all_refs = _rows(conn.execute(
            "SELECT source, object, proc_name, stmt_idx, operation, file "
            "FROM all_sql_tables WHERE table_name = ? ORDER BY source, object",
            [table_name],
        ))
        if not all_refs:
            raise HTTPException(status_code=404, detail=f"Table not found: {table_name}")

        dws = _rows(conn.execute(
            "SELECT DISTINCT dw_name, file FROM dw_retrieve_tables "
            "WHERE table_name = ? ORDER BY dw_name",
            [table_name],
        ))
        columns = _rows(conn.execute(
            "SELECT dw_name, column_fqn, column_name "
            "FROM dw_retrieve_columns WHERE table_name = ? ORDER BY dw_name, column_name",
            [table_name],
        ))
        where = _rows(conn.execute(
            "SELECT dw_name, idx, exp1, op, exp2, logic "
            "FROM dw_retrieve_where WHERE exp1 LIKE ? OR exp2 LIKE ? ORDER BY dw_name, idx",
            [f"%{table_name}%", f"%{table_name}%"],
        ))
        procedures = _rows(conn.execute(
            "SELECT DISTINCT object, proc_name, operation "
            "FROM all_sql_tables "
            "WHERE table_name = ? AND source = 'powerscript' ORDER BY object, proc_name",
            [table_name],
        ))
        return {
            "table_name": table_name,
            "dw_count": len(dws),
            "ps_count": len(procedures),
            "datawindows": dws,
            "columns": columns,
            "where": where,
            "procedures": procedures,
        }
    finally:
        conn.close()


# ── Stats ──────────────────────────────────────────────────────────────────────

@router.get("/api/stats")
async def get_stats(request: Request):
    conn = _conn(request)
    try:
        stats = {}
        for table in ("objects", "procedures", "dw_controls", "dw_retrieve_tables",
                       "dw_retrieve_columns", "inherits", "calls", "object_metrics"):
            try:
                row = conn.execute(f"SELECT count(*) FROM {table}").fetchone()
                stats[table] = row[0] if row else 0
            except Exception:
                stats[table] = 0

        kind_counts = _rows(conn.execute(
            "SELECT kind, count(*) AS count FROM objects GROUP BY kind ORDER BY count DESC"
        ))
        stats["by_kind"] = kind_counts

        top_complex = _rows(conn.execute(
            "SELECT object, name, proc_type, cyclomatic "
            "FROM procedures WHERE cyclomatic IS NOT NULL "
            "ORDER BY cyclomatic DESC LIMIT 10"
        ))
        stats["top_complex"] = top_complex

        top_pagerank = _rows(conn.execute(
            "SELECT object, round(pagerank, 6) AS pagerank, in_degree, out_degree "
            "FROM object_metrics ORDER BY pagerank DESC LIMIT 10"
        ))
        stats["top_pagerank"] = top_pagerank

        try:
            row = conn.execute(
                "SELECT count(DISTINCT table_name) FROM all_sql_tables"
            ).fetchone()
            stats["tables"] = row[0] if row else 0
        except Exception:
            stats["tables"] = 0

        return stats
    finally:
        conn.close()
