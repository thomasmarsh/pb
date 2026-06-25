"""Object-related business logic extracted from route handlers."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows


def _get_root(conn: duckdb.DuckDBPyConnection) -> Path | None:
    """Return the ingestion root directory from metadata, or None."""
    row = conn.execute("SELECT value FROM metadata WHERE key = 'ingestion_root'").fetchone()
    return Path(row[0]) if row else None


def pbl_name(file_path: str) -> str:
    """Extract .pbl library name from an extracted file path."""
    parts = file_path.replace("\\", "/").split("/")
    for part in parts:
        if part.lower().endswith(".pbl"):
            return part
    if len(parts) >= 2:
        return parts[-2]
    return "(unknown)"


_ALL_OBJECTS_CTE = """
WITH all_objects AS (
    SELECT object, kind, file, ancestor FROM objects
    UNION ALL
    SELECT object, 'datawindow' AS kind, file, NULL AS ancestor FROM dw_objects
)
"""


def list_objects(
    conn: duckdb.DuckDBPyConnection,
    *,
    q: str = "",
    kind: str = "",
    sort: str = "name",
    order: str = "asc",
    limit: int = 100,
    offset: int = 0,
) -> dict[str, Any]:
    conditions: list[str] = []
    params: list[Any] = []
    if q:
        conditions.append("(o.object ILIKE ? OR o.file ILIKE ?)")
        params += [f"%{q}%", f"%{q}%"]
    if kind:
        conditions.append("o.kind = ?")
        params.append(kind)
    where = "WHERE " + " AND ".join(conditions) if conditions else ""

    _sort_map = {"name": "object", "kind": "kind", "file": "file"}
    sort_col = _sort_map.get(sort, "object")
    sort_dir = "DESC" if order.lower() == "desc" else "ASC"

    count_row = conn.execute(
        f"{_ALL_OBJECTS_CTE} SELECT count(*) FROM all_objects o {where}", params
    ).fetchone()
    total = count_row[0] if count_row else 0

    items = rows(
        conn.execute(
            f"{_ALL_OBJECTS_CTE}"
            f"SELECT o.object AS name, o.kind, o.file, o.ancestor "
            f"FROM all_objects o {where} "
            f"ORDER BY o.{sort_col} {sort_dir} "
            f"LIMIT ? OFFSET ?",
            params + [limit, offset],
        )
    )
    return {"total": total, "offset": offset, "limit": limit, "items": items}


def get_object_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    obj_rows = rows(conn.execute("SELECT object AS name, kind, file, ancestor FROM objects WHERE object = ?", [name]))
    if not obj_rows:
        # Fall back to dw_objects for DataWindow objects
        dw_rows = rows(conn.execute("SELECT object AS name, file FROM dw_objects WHERE object = ?", [name]))
        if not dw_rows:
            return None
        dw = dw_rows[0]
        callers = rows(conn.execute("SELECT DISTINCT object AS caller FROM call_sites WHERE to_name = ?", [name]))
        return {
            "name": dw["name"],
            "kind": "datawindow",
            "file": dw["file"],
            "ancestor": None,
            "metrics": None,
            "procedures": [],
            "ancestors": [],
            "descendants": [],
            "callers": [c["caller"] for c in callers],
            "callees": [],
            "dws_used": [],
            "tables_accessed": [],
        }
    obj = obj_rows[0]

    metrics = rows(conn.execute("SELECT * FROM object_metrics WHERE object = ?", [name]))
    obj["metrics"] = metrics[0] if metrics else None

    procs = rows(
        conn.execute(
            "SELECT object, object AS owner, proc_type, proc_name AS name, "
            "params, return_type, start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? ORDER BY proc_type, proc_name",
            [name],
        )
    )
    obj["procedures"] = procs

    ancestors = rows(conn.execute(
        "SELECT ancestor AS parent FROM objects WHERE object = ? AND ancestor IS NOT NULL", [name]
    ))
    obj["ancestors"] = [a["parent"] for a in ancestors]

    descendants = rows(conn.execute(
        "SELECT object AS child FROM objects WHERE ancestor = ?", [name]
    ))
    obj["descendants"] = [d["child"] for d in descendants]

    callers = rows(conn.execute("SELECT DISTINCT object AS caller FROM call_sites WHERE to_name = ?", [name]))
    obj["callers"] = [c["caller"] for c in callers]

    callees = rows(conn.execute("SELECT DISTINCT to_name AS callee FROM call_sites WHERE object = ?", [name]))
    obj["callees"] = [c["callee"] for c in callees]

    dws = rows(conn.execute(
        "SELECT DISTINCT c.to_name AS dw_name "
        "FROM call_sites c "
        "JOIN objects o ON o.object = c.to_name AND o.kind = 'datawindow' "
        "WHERE c.object = ? "
        "ORDER BY c.to_name",
        [name],
    ))
    obj["dws_used"] = [d["dw_name"] for d in dws]

    tables = rows(conn.execute(
        "SELECT DISTINCT t.table_name "
        "FROM all_sql_tables t "
        "WHERE (t.object = ? AND t.source = 'powerscript') "
        "   OR (t.source = 'datawindow' AND t.object IN ("
        "       SELECT DISTINCT c.to_name FROM call_sites c "
        "       JOIN objects o ON o.object = c.to_name AND o.kind = 'datawindow' "
        "       WHERE c.object = ?)) "
        "ORDER BY t.table_name",
        [name, name],
    ))
    obj["tables_accessed"] = [t["table_name"] for t in tables if t.get("table_name")]

    return obj


def get_object_source(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    obj_rows = rows(conn.execute("SELECT object AS name, kind, file FROM objects WHERE object = ?", [name]))
    if not obj_rows:
        dw_rows = rows(conn.execute("SELECT object AS name, file FROM dw_objects WHERE object = ?", [name]))
        if not dw_rows:
            return None
        obj_rows = [{"name": dw_rows[0]["name"], "kind": "datawindow", "file": dw_rows[0]["file"]}]

    file_path = obj_rows[0]["file"]
    lines = []
    if file_path:
        # Try the source_files table first (self-contained DB source).
        src_row = conn.execute(
            "SELECT lines FROM source_files WHERE file = ?", [file_path]
        ).fetchone()
        if src_row and src_row[0]:
            lines = src_row[0].splitlines()
        else:
            # Fallback: read from disk (preserves behaviour for non-PBL sources).
            root = _get_root(conn)
            disk_path = (root / file_path) if root else Path(file_path)
            if disk_path.exists():
                try:
                    with open(disk_path, "r", errors="replace") as f:
                        lines = f.read().splitlines()
                except OSError:
                    pass

    procs = rows(
        conn.execute(
            "SELECT p.proc_name AS name, p.proc_type, p.params, p.return_type, "
            "p.start_line, p.end_line, p.cyclomatic, "
            "COUNT(DISTINCT c_in.object || '.' || c_in.from_proc) AS caller_count, "
            "COUNT(DISTINCT c_out.to_name) AS callee_count "
            "FROM procedures p "
            "LEFT JOIN call_sites c_in ON c_in.to_name = p.proc_name "
            "LEFT JOIN call_sites c_out ON c_out.object = p.object AND c_out.from_proc = p.proc_name "
            "WHERE p.object = ? "
            "AND p.start_line IS NOT NULL AND p.end_line IS NOT NULL "
            "GROUP BY p.proc_name, p.proc_type, p.params, p.return_type, "
            "         p.start_line, p.end_line, p.cyclomatic "
            "ORDER BY p.start_line",
            [name],
        )
    )

    known_objects = rows(conn.execute("SELECT object AS name, kind FROM objects WHERE object != ? ORDER BY object", [name]))

    known_procs = rows(
        conn.execute(
            "SELECT DISTINCT p.proc_name AS name, p.object, p.proc_type, "
            "p.params, p.return_type, p.start_line, p.end_line, p.cyclomatic "
            "FROM procedures p "
            "JOIN call_sites c ON c.to_name = p.proc_name "
            "WHERE c.object = ? "
            "UNION "
            "SELECT DISTINCT p.proc_name AS name, p.object, p.proc_type, "
            "p.params, p.return_type, p.start_line, p.end_line, p.cyclomatic "
            "FROM procedures p "
            "WHERE p.object = ? AND p.proc_type IN ('function', 'subroutine') "
            "ORDER BY name",
            [name, name],
        )
    )

    try:
        local_symbols = rows(
            conn.execute(
                "SELECT proc_name, var_name, raw_type, resolved_kind, resolved_target, is_parameter "
                "FROM resolved_types WHERE object = ? ORDER BY proc_name, var_name",
                [name],
            )
        )
    except Exception:
        local_symbols = []

    return {
        "file": file_path,
        "lines": lines,
        "source_available": bool(lines),
        "procedures": procs,
        "knownObjects": known_objects,
        "knownProcs": known_procs,
        "localSymbols": local_symbols,
    }


_PB_BASE_CLASSES = {"window", "datawindow", "userobject", "dwuserobject", "nonvisualobject"}


def get_object_ast(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    """Return event/function CPS graphs and variables for an object."""
    import json
    obj_rows = rows(conn.execute(
        "SELECT object AS name, ancestor FROM objects WHERE object = ?", [name]
    ))
    if not obj_rows:
        return None

    ancestor_name: str | None = obj_rows[0].get("ancestor")

    event_rows = rows(conn.execute(
        "SELECT proc_name AS name, object AS owner, cps_graph_json FROM procedures "
        "WHERE object = ? AND proc_type = 'event'",
        [name],
    ))
    events = [
        {
            "name": r["name"],
            "owner": r["owner"],
            "body": [],
            "cpsGraph": json.loads(r["cps_graph_json"]) if r.get("cps_graph_json") else None,
        }
        for r in event_rows
    ]

    func_rows = rows(conn.execute(
        "SELECT proc_name AS name, object AS owner, cps_graph_json FROM procedures "
        "WHERE object = ? AND proc_type IN ('function', 'subroutine')",
        [name],
    ))
    functions = [
        {
            "name": r["name"],
            "owner": r["owner"] or name,
            "body": [],
            "cpsGraph": json.loads(r["cps_graph_json"]) if r.get("cps_graph_json") else None,
        }
        for r in func_rows
    ]

    var_rows = rows(conn.execute(
        "SELECT var_name, var_type, mods AS modifiers FROM global_vars "
        "WHERE object = ? ORDER BY var_name",
        [name],
    ))
    variables = [
        {
            "name": r["var_name"],
            "type": r["var_type"],
            "modifiers": r.get("modifiers"),
            "scope": "instance",
        }
        for r in var_rows
    ]

    ancestor_events: list[dict[str, Any]] = []
    ancestor_functions: list[dict[str, Any]] = []

    if ancestor_name and ancestor_name.lower() not in _PB_BASE_CLASSES:
        anc_rows = rows(conn.execute(
            "SELECT proc_name AS name, object AS owner, proc_type, cps_graph_json FROM procedures "
            "WHERE object = ? AND proc_type IN ('event', 'function', 'subroutine')",
            [ancestor_name],
        ))
        for r in anc_rows:
            entry = {
                "name": r["name"],
                "owner": r["owner"] or ancestor_name,
                "body": [],
                "cpsGraph": json.loads(r["cps_graph_json"]) if r.get("cps_graph_json") else None,
            }
            if r["proc_type"] == "event":
                ancestor_events.append(entry)
            else:
                ancestor_functions.append(entry)

    return {
        "typeBlocks": [],
        "events": events,
        "functions": functions,
        "variables": variables,
        "ancestorName": ancestor_name,
        "ancestorEvents": ancestor_events,
        "ancestorFunctions": ancestor_functions,
    }


def get_object_layout(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    """Return the parsed window layout JSON stored during ingestion."""
    row = conn.execute(
        "SELECT layout_json FROM objects WHERE object = ?", [name]
    ).fetchone()
    if not row or not row[0]:
        return None
    try:
        return json.loads(row[0])
    except Exception:
        return None


def get_dw_layout(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    """Return the parsed DataWindowFile JSON stored during ingestion."""
    row = conn.execute(
        "SELECT layout_json FROM dw_objects WHERE object = ?", [name]
    ).fetchone()
    if not row or not row[0]:
        return None
    try:
        return json.loads(row[0])
    except Exception:
        return None


def get_explore_tree(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    obj_rows = rows(conn.execute("SELECT object AS name, kind, file FROM objects ORDER BY kind, object"))
    proc_rows = rows(
        conn.execute(
            "SELECT object, proc_type, proc_name AS name, params, return_type, "
            "start_line, end_line, cyclomatic "
            "FROM procedures ORDER BY object, proc_type, proc_name"
        )
    )
    procs_by_obj: dict[str, list[dict[str, Any]]] = {}
    for p in proc_rows:
        procs_by_obj.setdefault(p["object"], []).append(p)

    libraries: dict[str, list[dict[str, Any]]] = {}
    for obj in obj_rows:
        fpath = obj.get("file", "")
        lib = pbl_name(fpath)
        obj_entry = {
            "name": obj["name"],
            "kind": obj["kind"],
            "file": fpath,
            "procedures": procs_by_obj.get(obj["name"], []),
        }
        libraries.setdefault(lib, []).append(obj_entry)

    result = [{"name": lib, "objects": objs} for lib, objs in sorted(libraries.items())]
    return {"libraries": result}
