"""Object-related business logic extracted from route handlers."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import duckdb
from pb.api.routes.dependencies import rows


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
    SELECT object, kind, file, ancestor, category FROM objects
)
"""


def list_objects(
    conn: duckdb.DuckDBPyConnection,
    *,
    q: str = "",
    kind: str = "",
    category: str = "",
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
    if category:
        conditions.append("o.category = ?")
        params.append(category)
    # The System category *is* the stdlib library -- only exclude it when the
    # caller isn't specifically browsing System.
    if category != "system":
        conditions.append("o.file NOT LIKE '__stdlib__%'")
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
            f"SELECT o.object AS name, o.kind, o.file, o.ancestor, o.category "
            f"FROM all_objects o {where} "
            f"ORDER BY o.{sort_col} {sort_dir} "
            f"LIMIT ? OFFSET ?",
            params + [limit, offset],
        )
    )
    return {"total": total, "offset": offset, "limit": limit, "items": items}


def get_object_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    obj_rows = rows(conn.execute("SELECT object AS name, kind, file, ancestor, category FROM objects WHERE object = ?", [name]))
    if not obj_rows:
        return None
    obj = obj_rows[0]

    metrics = rows(conn.execute("SELECT * FROM object_metrics WHERE object = ?", [name]))
    obj["metrics"] = metrics[0] if metrics else None

    procs = rows(
        conn.execute(
            "SELECT object, owner, proc_type, proc_name AS name, "
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

    structures = rows(conn.execute(
        "SELECT object AS name FROM structures WHERE owner = ? ORDER BY object", [name]
    ))
    for s in structures:
        s["fields"] = rows(conn.execute(
            "SELECT var_name, var_type, mods AS modifiers FROM global_vars "
            "WHERE object = ? ORDER BY var_name",
            [s["name"]],
        ))
    obj["structures"] = structures

    callers = rows(conn.execute("SELECT DISTINCT object AS caller FROM call_sites WHERE to_name = ?", [name]))
    obj["callers"] = [c["caller"] for c in callers]

    callees = rows(conn.execute("SELECT DISTINCT to_name AS callee FROM call_sites WHERE object = ?", [name]))
    obj["callees"] = [c["callee"] for c in callees]

    dws = rows(conn.execute(
        "SELECT DISTINCT c.to_name AS object "
        "FROM call_sites c "
        "JOIN objects o ON o.object = c.to_name AND o.kind = 'datawindow' "
        "WHERE c.object = ? "
        "ORDER BY c.to_name",
        [name],
    ))
    obj["dws_used"] = [d["object"] for d in dws]

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


def get_known_objects(conn: duckdb.DuckDBPyConnection, object_name: str) -> list[dict[str, Any]]:
    """Every other object in the workspace, for the source viewer's name-based object-link fallback."""
    return rows(conn.execute("SELECT object AS name, kind FROM objects WHERE object != ? ORDER BY object", [object_name]))


def get_resolved_calls(conn: duckdb.DuckDBPyConnection, object_name: str) -> list[dict[str, Any]]:
    """Resolved call sites within `object_name`'s source, span-keyed for identifier-linking."""
    return rows(
        conn.execute(
            "SELECT proc_name, to_name, call_type, line, target_object, target_proc, kind, confidence, "
            "to_name_start_line, to_name_start_col, to_name_end_line, to_name_end_col "
            "FROM resolved_calls WHERE object = ? ORDER BY line, to_name_start_col",
            [object_name],
        )
    )


def get_resolved_var_refs(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str | None = None) -> list[dict[str, Any]]:
    """Resolved variable/property references within `object_name`'s source, span-keyed for identifier-linking.

    Optionally scoped to one procedure. Unlike the old declaration-shaped
    `resolved_types` lookup, `resolved_var_refs` is per-occurrence -- an
    instance var read from a given procedure already carries that
    procedure's `proc_name`, so plain equality scoping is correct with no
    separate instance-var carve-out.
    """
    if proc_name is not None:
        return rows(
            conn.execute(
                "SELECT proc_name, line, name, access, target_object, kind, confidence, "
                "name_start_line, name_start_col, name_end_line, name_end_col, declared_type "
                "FROM resolved_var_refs WHERE object = ? AND proc_name = ? ORDER BY line, name_start_col",
                [object_name, proc_name],
            )
        )
    return rows(
        conn.execute(
            "SELECT proc_name, line, name, access, target_object, kind, confidence, "
            "name_start_line, name_start_col, name_end_line, name_end_col, declared_type "
            "FROM resolved_var_refs WHERE object = ? ORDER BY line, name_start_col",
            [object_name],
        )
    )


def get_object_source(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    obj_rows = rows(conn.execute("SELECT object AS name, kind, file FROM objects WHERE object = ?", [name]))
    if not obj_rows:
        return None

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
            "COUNT(DISTINCT c_in.object || '.' || c_in.proc_name) AS caller_count, "
            "COUNT(DISTINCT c_out.to_name) AS callee_count "
            "FROM procedures p "
            "LEFT JOIN call_sites c_in ON c_in.to_name = p.proc_name "
            "LEFT JOIN call_sites c_out ON c_out.object = p.object AND c_out.proc_name = p.proc_name "
            "WHERE p.object = ? "
            "AND p.start_line IS NOT NULL AND p.end_line IS NOT NULL "
            "GROUP BY p.proc_name, p.proc_type, p.params, p.return_type, "
            "         p.start_line, p.end_line, p.cyclomatic "
            "ORDER BY p.start_line",
            [name],
        )
    )

    sql_stmts = rows(
        conn.execute(
            "SELECT line, raw_sql, operation, parse_ok, error "
            "FROM sql_statements WHERE object = ? ORDER BY line",
            [name],
        )
    )

    return {
        "file": file_path,
        "lines": lines,
        "source_available": bool(lines),
        "procedures": procs,
        "knownObjects": get_known_objects(conn, name),
        "resolvedCalls": get_resolved_calls(conn, name),
        "resolvedVarRefs": get_resolved_var_refs(conn, name),
        "sqlStatements": sql_stmts,
    }


_PB_BASE_CLASSES = {
    # PB primitive base types
    "window", "datawindow", "userobject", "dwuserobject",
    # Undocumented abstract base classes — no usable event/function bodies
    "classdefinitionobject", "connectobject", "cplusplus", "dragobject",
    "drawobject", "dwobject", "extobject", "function_object", "graphicobject",
    "nonvisualobject", "omcontrol", "omcustomcontrol", "omembeddedcontrol",
    "omobject", "omstorage", "omstream", "orb", "pbtocppobject", "pdfobject",
    "powerobject", "remoteobject", "service", "structure", "windowobject",
}


def get_object_ast(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    """Return event/function instruction graphs and variables for an object."""
    import json
    obj_rows = rows(conn.execute(
        "SELECT object AS name, ancestor, type_blocks_json FROM objects WHERE object = ?", [name]
    ))
    if not obj_rows:
        return None

    ancestor_name: str | None = obj_rows[0].get("ancestor")
    type_blocks_json: str | None = obj_rows[0].get("type_blocks_json")

    event_rows = rows(conn.execute(
        "SELECT proc_name AS name, owner, instr_graph_json FROM procedures "
        "WHERE object = ? AND proc_type = 'event'",
        [name],
    ))
    events = [
        {
            "name": r["name"],
            "owner": r["owner"],
            "body": [],
            "instrGraph": json.loads(r["instr_graph_json"]) if r.get("instr_graph_json") else None,
        }
        for r in event_rows
    ]

    func_rows = rows(conn.execute(
        "SELECT proc_name AS name, owner, instr_graph_json FROM procedures "
        "WHERE object = ? AND proc_type IN ('function', 'subroutine')",
        [name],
    ))
    functions = [
        {
            "name": r["name"],
            "owner": r["owner"] or name,
            "body": [],
            "instrGraph": json.loads(r["instr_graph_json"]) if r.get("instr_graph_json") else None,
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
            "SELECT proc_name AS name, owner, proc_type, instr_graph_json FROM procedures "
            "WHERE object = ? AND proc_type IN ('event', 'function', 'subroutine')",
            [ancestor_name],
        ))
        for r in anc_rows:
            entry = {
                "name": r["name"],
                "owner": r["owner"] or ancestor_name,
                "body": [],
                "instrGraph": json.loads(r["instr_graph_json"]) if r.get("instr_graph_json") else None,
            }
            if r["proc_type"] == "event":
                ancestor_events.append(entry)
            else:
                ancestor_functions.append(entry)

    return {
        "typeBlocks": json.loads(type_blocks_json) if type_blocks_json else [],
        "events": events,
        "functions": functions,
        "variables": variables,
        "ancestorName": ancestor_name,
        "ancestorEvents": ancestor_events,
        "ancestorFunctions": ancestor_functions,
    }


def _load_layout_raw(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT layout_json, ancestor FROM objects WHERE object = ?", [name]
    ).fetchone()
    if not row or not row[0]:
        return None
    try:
        layout = json.loads(row[0])
        layout["_ancestor"] = row[1]  # carry ancestor for merging
        return layout
    except Exception:
        return None


def get_object_layout(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    """Return the parsed window layout JSON, enriched with inherited control dimensions.

    Inherited controls that only override x/y in the child window have no width/height
    in the child's layout_json.  Walk the ancestor chain (up to 8 levels) and fill
    in any missing numeric fields (width, height, text) from the matching parent control.
    """
    layout = _load_layout_raw(conn, name)
    if layout is None:
        return None

    # Build an index of controls by name for fast lookup
    child_by_name: dict[str, dict[str, Any]] = {
        c["name"]: c for c in layout.get("controls", [])
    }

    # Fields that may be inherited from parent controls
    INHERIT_FIELDS = ("width", "height", "text")

    visited: set[str] = {name}
    ancestor = layout.pop("_ancestor", None)

    while ancestor and ancestor not in visited:
        parent = _load_layout_raw(conn, ancestor)
        if parent is None:
            break
        visited.add(ancestor)
        ancestor = parent.pop("_ancestor", None)

        parent_by_name: dict[str, dict[str, Any]] = {
            c["name"]: c for c in parent.get("controls", [])
        }
        for ctrl_name, ctrl in child_by_name.items():
            parent_ctrl = parent_by_name.get(ctrl_name)
            if parent_ctrl is None:
                continue
            for field in INHERIT_FIELDS:
                if field not in ctrl and field in parent_ctrl:
                    ctrl[field] = parent_ctrl[field]

        # Stop once all controls have width and height
        if all("width" in c and "height" in c for c in child_by_name.values()):
            break

    return layout


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


def get_dw_queries(conn: duckdb.DuckDBPyConnection) -> dict[str, str]:
    """Return {dwObjectName: retrieveSql} for all DW objects with a retrieve clause."""
    result = conn.execute(
        "SELECT object, retrieve_sql FROM dw_objects WHERE retrieve_sql IS NOT NULL"
    ).fetchall()
    return {row[0]: row[1] for row in result}


def get_explore_tree(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    obj_rows = rows(conn.execute("SELECT object AS name, kind, file, category FROM objects WHERE file NOT LIKE '__stdlib__%' ORDER BY kind, object"))
    proc_rows = rows(
        conn.execute(
            "SELECT object, owner, proc_type, proc_name AS name, params, return_type, "
            "start_line, end_line, cyclomatic "
            "FROM procedures WHERE file NOT LIKE '__stdlib__%' ORDER BY object, proc_type, proc_name"
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
            "category": obj["category"],
            "file": fpath,
            "procedures": procs_by_obj.get(obj["name"], []),
        }
        libraries.setdefault(lib, []).append(obj_entry)

    result = [{"name": lib, "objects": objs} for lib, objs in sorted(libraries.items())]
    return {"libraries": result}
