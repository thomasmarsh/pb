"""Procedure business logic extracted from route handlers."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows
from pb_cli.explorer.services.objects import _get_root


def get_procedure_detail(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str) -> dict[str, Any] | None:
    proc_rows = rows(
        conn.execute(
            "SELECT file, object, proc_type, proc_name AS name, params, "
            "return_type, start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? AND proc_name = ?",
            [object_name, proc_name],
        )
    )
    if not proc_rows:
        return None
    proc = proc_rows[0]

    source_file = proc.get("file")
    start = proc.get("start_line")
    end = proc.get("end_line")

    source_original = None
    if source_file and start and end:
        # Try the source_files table first (self-contained DB source).
        src_row = conn.execute(
            "SELECT lines FROM source_files WHERE file = ?", [source_file]
        ).fetchone()
        if src_row and src_row[0]:
            all_lines = src_row[0].splitlines()
            source_original = "\n".join(all_lines[max(0, start - 1) : end])
        else:
            # Fallback: read from disk.
            root = _get_root(conn)
            disk_path = (root / source_file) if root else Path(source_file)
            if disk_path.exists():
                try:
                    with open(disk_path, "r", errors="replace") as f:
                        all_lines = f.readlines()
                    source_original = "".join(all_lines[max(0, start - 1) : end])
                except (OSError, IndexError):
                    pass

    proc["source_original"] = source_original

    callers = rows(conn.execute(
        "SELECT DISTINCT c.object AS caller_object, c.from_proc AS caller_proc "
        "FROM call_sites c "
        "WHERE c.to_name = ? "
        "ORDER BY c.object, c.from_proc",
        [proc_name],
    ))
    proc["callers"] = [{"object": c["caller_object"], "proc": c["caller_proc"]} for c in callers]

    callees = rows(conn.execute(
        "SELECT DISTINCT c.to_name AS callee "
        "FROM call_sites c "
        "WHERE c.object = ? AND c.from_proc = ? "
        "ORDER BY c.to_name",
        [object_name, proc_name],
    ))
    proc["callees"] = [c["callee"] for c in callees]

    sql_stmts = rows(conn.execute(
        "SELECT line, operation, raw_sql, tables, columns, parse_ok "
        "FROM sql_statements WHERE object = ? AND proc_name = ? ORDER BY line",
        [object_name, proc_name],
    ))
    proc["sql_statements"] = sql_stmts

    return proc


def list_procedures(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    result = rows(conn.execute(
        "SELECT p.object, p.proc_type, p.proc_name AS name, p.params, p.return_type, "
        "p.cyclomatic, "
        "COUNT(DISTINCT c.object || '.' || c.from_proc) AS caller_count "
        "FROM procedures p "
        "LEFT JOIN call_sites c ON c.to_name = p.proc_name "
        "GROUP BY p.object, p.proc_type, p.proc_name, p.params, p.return_type, p.cyclomatic "
        "ORDER BY p.object, p.proc_name"
    ))
    return result


def get_procedure_explore(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str) -> dict[str, Any] | None:
    proc_rows = rows(
        conn.execute(
            "SELECT proc_type, params, return_type, start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? AND proc_name = ?",
            [object_name, proc_name],
        )
    )
    if not proc_rows:
        return None
    row = proc_rows[0]
    sql_stmts = rows(
        conn.execute(
            "SELECT line, operation, raw_sql, tables, columns, parse_ok "
            "FROM sql_statements WHERE object = ? AND proc_name = ? ORDER BY line",
            [object_name, proc_name],
        )
    )
    import sqlglot as _sqlglot

    for stmt in sql_stmts:
        raw = stmt.get("raw_sql") or ""
        try:
            stmt["formatted_sql"] = _sqlglot.transpile(raw, read="oracle", write="oracle", pretty=True)[0]
        except Exception:
            stmt["formatted_sql"] = raw

    return {
        "source_original": None,
        "proc_type": row.get("proc_type"),
        "params": row.get("params"),
        "return_type": row.get("return_type"),
        "modifiers": None,
        "start_line": row.get("start_line"),
        "end_line": row.get("end_line"),
        "cyclomatic": row.get("cyclomatic"),
        "sql_statements": sql_stmts,
    }
