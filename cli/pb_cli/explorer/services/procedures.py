"""Procedure business logic extracted from route handlers."""

from __future__ import annotations

import json
import os
from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows


def get_procedure_detail(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str) -> dict[str, Any] | None:
    proc_rows = rows(
        conn.execute(
            "SELECT file, object, proc_type, name, modifiers, params, "
            "return_type, start_line, end_line, body_json, cyclomatic, source_rendered "
            "FROM procedures WHERE object = ? AND name = ?",
            [object_name, proc_name],
        )
    )
    if not proc_rows:
        return None
    proc = proc_rows[0]

    proc["source_rendered"] = proc.get("source_rendered") or ""

    source_file = proc.get("file")
    start = proc.get("start_line")
    end = proc.get("end_line")
    if source_file and start and end and os.path.exists(source_file):
        try:
            with open(source_file, "r", errors="replace") as f:
                all_lines = f.readlines()
            snippet = "".join(all_lines[max(0, start - 1) : end])
            proc["source_original"] = snippet
        except (OSError, IndexError):
            proc["source_original"] = None
    else:
        proc["source_original"] = None

    return proc


def get_procedure_explore(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str) -> dict[str, Any] | None:
    proc_rows = rows(
        conn.execute(
            "SELECT body_json, source_rendered, proc_type, params, return_type, "
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
