"""Object-related business logic extracted from route handlers."""

from __future__ import annotations

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
        conditions.append("(o.name ILIKE ? OR o.file ILIKE ?)")
        params += [f"%{q}%", f"%{q}%"]
    if kind:
        conditions.append("o.kind = ?")
        params.append(kind)
    where = "WHERE " + " AND ".join(conditions) if conditions else ""

    safe_sorts = {"name", "kind", "file"}
    sort_col = sort if sort in safe_sorts else "name"
    sort_dir = "DESC" if order.lower() == "desc" else "ASC"

    count_row = conn.execute(f"SELECT count(*) FROM objects o {where}", params).fetchone()
    total = count_row[0] if count_row else 0

    items = rows(
        conn.execute(
            f"SELECT o.name, o.kind, o.file, o.ancestor "
            f"FROM objects o {where} "
            f"ORDER BY o.{sort_col} {sort_dir} "
            f"LIMIT ? OFFSET ?",
            params + [limit, offset],
        )
    )
    return {"total": total, "offset": offset, "limit": limit, "items": items}


def get_object_detail(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    obj_rows = rows(conn.execute("SELECT name, kind, file, ancestor FROM objects WHERE name = ?", [name]))
    if not obj_rows:
        return None
    obj = obj_rows[0]

    metrics = rows(conn.execute("SELECT * FROM object_metrics WHERE object = ?", [name]))
    obj["metrics"] = metrics[0] if metrics else None

    procs = rows(
        conn.execute(
            "SELECT object, proc_type, name, modifiers, params, return_type, "
            "start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? ORDER BY proc_type, name",
            [name],
        )
    )
    obj["procedures"] = procs

    ancestors = rows(conn.execute("SELECT to_object AS parent FROM inherits WHERE from_object = ?", [name]))
    obj["ancestors"] = [a["parent"] for a in ancestors]

    descendants = rows(conn.execute("SELECT from_object AS child FROM inherits WHERE to_object = ?", [name]))
    obj["descendants"] = [d["child"] for d in descendants]

    callers = rows(conn.execute("SELECT DISTINCT object AS caller FROM calls WHERE to_name = ?", [name]))
    obj["callers"] = [c["caller"] for c in callers]

    callees = rows(conn.execute("SELECT DISTINCT to_name AS callee FROM calls WHERE object = ?", [name]))
    obj["callees"] = [c["callee"] for c in callees]

    dws = rows(conn.execute(
        "SELECT DISTINCT c.to_name AS dw_name "
        "FROM calls c "
        "JOIN objects o ON o.name = c.to_name AND o.kind = 'datawindow' "
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
        "       SELECT DISTINCT c.to_name FROM calls c "
        "       JOIN objects o ON o.name = c.to_name AND o.kind = 'datawindow' "
        "       WHERE c.object = ?)) "
        "ORDER BY t.table_name",
        [name, name],
    ))
    obj["tables_accessed"] = [t["table_name"] for t in tables if t.get("table_name")]

    return obj


def get_object_source(conn: duckdb.DuckDBPyConnection, name: str) -> dict[str, Any] | None:
    obj_rows = rows(conn.execute("SELECT name, kind, file, source_text FROM objects WHERE name = ?", [name]))
    if not obj_rows:
        return None

    file_path = obj_rows[0]["file"]
    lines = []
    if file_path:
        root = _get_root(conn)
        disk_path = (root / file_path) if root else Path(file_path)
        if disk_path.exists():
            try:
                with open(disk_path, "r", errors="replace") as f:
                    lines = f.read().splitlines()
            except OSError:
                pass
    if not lines and obj_rows[0].get("source_text"):
        lines = obj_rows[0]["source_text"].splitlines()

    procs = rows(
        conn.execute(
            "SELECT p.name, p.proc_type, p.modifiers, p.params, p.return_type, "
            "p.start_line, p.end_line, p.cyclomatic, "
            "COUNT(DISTINCT c_in.object || '.' || c_in.from_proc) AS caller_count, "
            "COUNT(DISTINCT c_out.to_name) AS callee_count "
            "FROM procedures p "
            "LEFT JOIN calls c_in ON c_in.to_name = p.name "
            "LEFT JOIN calls c_out ON c_out.object = p.object AND c_out.from_proc = p.name "
            "WHERE p.object = ? "
            "AND p.start_line IS NOT NULL AND p.end_line IS NOT NULL "
            "GROUP BY p.name, p.proc_type, p.modifiers, p.params, p.return_type, "
            "         p.start_line, p.end_line, p.cyclomatic "
            "ORDER BY p.start_line",
            [name],
        )
    )

    known_objects = rows(conn.execute("SELECT name, kind FROM objects WHERE name != ? ORDER BY name", [name]))

    known_procs = rows(
        conn.execute(
            "SELECT DISTINCT p.name, p.object, p.proc_type, "
            "p.params, p.return_type, p.modifiers, p.start_line, p.end_line, p.cyclomatic "
            "FROM procedures p "
            "JOIN calls c ON c.to_name = p.name "
            "WHERE c.object = ? "
            "UNION "
            "SELECT DISTINCT p.name, p.object, p.proc_type, "
            "p.params, p.return_type, p.modifiers, p.start_line, p.end_line, p.cyclomatic "
            "FROM procedures p "
            "WHERE p.object = ? AND p.proc_type IN ('function', 'subroutine') "
            "ORDER BY p.name",
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


def get_explore_tree(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    obj_rows = rows(conn.execute("SELECT name, kind, file FROM objects ORDER BY kind, name"))
    proc_rows = rows(
        conn.execute(
            "SELECT object, proc_type, name, modifiers, params, return_type, "
            "start_line, end_line, cyclomatic "
            "FROM procedures ORDER BY object, proc_type, name"
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
