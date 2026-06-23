"""Procedure business logic extracted from route handlers."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows
from pb_cli.explorer.services.objects import _get_root


def get_procedure_detail(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str) -> dict[str, Any] | None:
    proc_rows = rows(
        conn.execute(
            "SELECT file, object, proc_type, name, modifiers, params, "
            "return_type, start_line, end_line, body_json, cyclomatic "
            "FROM procedures WHERE object = ? AND name = ?",
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
    if start and end:
        obj_rows = rows(conn.execute(
            "SELECT source_text FROM objects WHERE name = ?", [object_name]
        ))
        if obj_rows and obj_rows[0].get("source_text"):
            all_lines = obj_rows[0]["source_text"].splitlines(keepends=True)
            source_original = "".join(all_lines[max(0, start - 1) : end])

    if not source_original and source_file and start and end:
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
        "FROM calls c "
        "WHERE c.to_name = ? "
        "ORDER BY c.object, c.from_proc",
        [proc_name],
    ))
    proc["callers"] = [{"object": c["caller_object"], "proc": c["caller_proc"]} for c in callers]

    callees = rows(conn.execute(
        "SELECT DISTINCT c.to_name AS callee "
        "FROM calls c "
        "WHERE c.object = ? AND c.from_proc = ? "
        "ORDER BY c.to_name",
        [object_name, proc_name],
    ))
    proc["callees"] = [c["callee"] for c in callees]

    sql_stmts = rows(conn.execute(
        "SELECT line, operation, raw_sql, tables, columns, has_into, has_cursor, parse_ok "
        "FROM sql_statements WHERE object = ? AND proc_name = ? ORDER BY line",
        [object_name, proc_name],
    ))
    proc["sql_statements"] = sql_stmts

    return proc


def list_procedures(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    result = rows(conn.execute(
        "SELECT p.object, p.proc_type, p.name, p.modifiers, p.params, p.return_type, "
        "p.cyclomatic, "
        "COUNT(DISTINCT c.object || '.' || c.from_proc) AS caller_count "
        "FROM procedures p "
        "LEFT JOIN calls c ON c.to_name = p.name "
        "GROUP BY p.object, p.proc_type, p.name, p.modifiers, p.params, p.return_type, p.cyclomatic "
        "ORDER BY p.object, p.name"
    ))
    return result


def get_procedure_explore(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str) -> dict[str, Any] | None:
    proc_rows = rows(
        conn.execute(
            "SELECT body_json, proc_type, params, return_type, "
            "modifiers, start_line, end_line, cyclomatic "
            "FROM procedures WHERE object = ? AND name = ?",
            [object_name, proc_name],
        )
    )
    if not proc_rows:
        return None
    row = proc_rows[0]
    body_json = row.get("body_json")
    if body_json is None:
        ast = None
    elif isinstance(body_json, str):
        ast = json.loads(body_json)
    else:
        ast = body_json

    start = row.get("start_line")
    end = row.get("end_line")
    source_original: str | None = None
    if start and end:
        obj_rows = rows(conn.execute(
            "SELECT source_text FROM objects WHERE name = ?", [object_name]
        ))
        if obj_rows and obj_rows[0].get("source_text"):
            all_lines = obj_rows[0]["source_text"].splitlines(keepends=True)
            source_original = "".join(all_lines[max(0, start - 1) : end])

    sql_stmts = rows(
        conn.execute(
            "SELECT line, operation, raw_sql, tables, columns, "
            "has_into, has_cursor, parse_ok "
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
        "ast": ast,
        "source_original": source_original,
        "proc_type": row.get("proc_type"),
        "params": row.get("params"),
        "return_type": row.get("return_type"),
        "modifiers": row.get("modifiers"),
        "start_line": start,
        "end_line": end,
        "cyclomatic": row.get("cyclomatic"),
        "sql_statements": sql_stmts,
    }
