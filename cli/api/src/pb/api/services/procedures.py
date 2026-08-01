"""Procedure business logic extracted from route handlers."""

from __future__ import annotations

from typing import Any

import duckdb
from pb.api.routes.dependencies import rows
from pb.api.services.objects import get_known_objects, get_resolved_calls, get_resolved_var_refs, read_source_lines


def _sql_stmts_with_lint(conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str) -> list[dict[str, Any]]:
    """sql_statements for one procedure, each row carrying its
    sql_lint_issues issue_codes (PB.Analysis.SqlLint) as lint_warnings."""
    return rows(conn.execute(
        "SELECT s.line, s.operation, s.raw_sql, s.tables, s.columns, s.parse_ok, s.error, "
        "COALESCE(list(l.issue_code) FILTER (WHERE l.issue_code IS NOT NULL), []) AS lint_warnings "
        "FROM sql_statements s "
        "LEFT JOIN sql_lint_issues l "
        "  ON l.object = s.object AND l.proc_name = s.proc_name AND l.line = s.line "
        "WHERE s.object = ? AND s.proc_name = ? "
        "GROUP BY s.line, s.operation, s.raw_sql, s.tables, s.columns, s.parse_ok, s.error "
        "ORDER BY s.line",
        [object_name, proc_name],
    ))


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
        all_lines = read_source_lines(conn, source_file)
        if all_lines is not None:
            source_original = "\n".join(all_lines[max(0, start - 1) : end])

    proc["source_original"] = source_original

    callers = rows(conn.execute(
        "SELECT DISTINCT c.object AS caller_object, c.proc_name AS caller_proc "
        "FROM call_sites c "
        "WHERE c.to_name = ? "
        "ORDER BY c.object, c.proc_name",
        [proc_name],
    ))
    proc["callers"] = [{"object": c["caller_object"], "proc": c["caller_proc"]} for c in callers]

    callees = rows(conn.execute(
        "SELECT DISTINCT c.to_name AS callee "
        "FROM call_sites c "
        "WHERE c.object = ? AND c.proc_name = ? "
        "ORDER BY c.to_name",
        [object_name, proc_name],
    ))
    proc["callees"] = [c["callee"] for c in callees]

    proc["sql_statements"] = _sql_stmts_with_lint(conn, object_name, proc_name)

    proc["knownObjects"] = get_known_objects(conn, object_name)
    proc["resolvedCalls"] = get_resolved_calls(conn, object_name)
    proc["resolvedVarRefs"] = get_resolved_var_refs(conn, object_name, proc_name)

    return proc


def list_procedures(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    result = rows(conn.execute(
        "SELECT p.object, p.proc_type, p.proc_name AS name, p.params, p.return_type, "
        "p.cyclomatic, "
        "COUNT(DISTINCT c.object || '.' || c.proc_name) AS caller_count "
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
    sql_stmts = _sql_stmts_with_lint(conn, object_name, proc_name)
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
