"""Database schema DDL, connection management, and SQL-file query parsing."""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import duckdb

from pb_cli.core.models import TABLES, ParseErrorRow
from pb_cli.shell.bulk import bulk_insert

Conn = duckdb.DuckDBPyConnection

_SQL_DIR = Path(__file__).parent.parent / "sql"
_SCHEMA_SQL = (_SQL_DIR / "schema.sql").read_text()
_VIEWS_SQL = (_SQL_DIR / "views.sql").read_text()
_COUNT_SQL_PARSE_FAILURES = (_SQL_DIR / "count_sql_parse_failures.sql").read_text()



@contextmanager
def db_connection(path: str | Path, read_only: bool = False) -> Generator[Conn, None, None]:
    conn = duckdb.connect(str(path), read_only=read_only)
    try:
        yield conn
    finally:
        conn.close()


def create_schema(conn: Conn) -> None:
    for stmt in _SCHEMA_SQL.split(";"):
        stmt = stmt.strip()
        if stmt:
            conn.execute(stmt)
    conn.execute(_VIEWS_SQL)


def count_sql_parse_failures(conn: Conn) -> int:
    """Count SQL statements that looked like SQL but sqlglot couldn't parse.

    Excludes statements that are intentionally never parsed (cursor ops,
    CONNECT/DISCONNECT, EXECUTE IMMEDIATE/PROCEDURE, DECLARE ... DYNAMIC
    CURSOR FOR <prepared-stmt-id>, DECLARE ... PROCEDURE FOR <storedproc> —
    see sql.py's _SKIP_RE), since those report parse_ok=False by design,
    not by failure.
    """
    row = conn.execute(_COUNT_SQL_PARSE_FAILURES).fetchone()
    return row[0] if row else 0


def insert_parse_errors(conn: Conn, rows: list[ParseErrorRow]) -> None:
    bulk_insert(conn, "parse_errors", list(ParseErrorRow._fields), [tuple(r) for r in rows])


def drop_tables(conn: Conn) -> None:
    """Drop all data tables and file_state (full reset)."""
    conn.execute("DROP VIEW IF EXISTS all_sql_tables")
    for t in TABLES + [
        "file_state", "metadata",
        "resolved_types", "resolved_calls",
        "object_metrics",
        "proc_defs", "proc_uses",
        "interproc_edges", "procedure_summaries",
        "taint_sources", "taint_sinks", "taint_paths", "taint_annotations",
        "dead_procedures",
    ]:
        conn.execute(f"DROP TABLE IF EXISTS {t}")


def open_db(db_path: str) -> Conn:
    if not os.path.exists(db_path):
        sys.exit(f"error: database not found: {db_path}")
    return duckdb.connect(db_path, read_only=True)


@contextmanager
def connect(db_path: str) -> Generator[Conn, None, None]:
    conn = open_db(db_path)
    try:
        yield conn
    finally:
        conn.close()


def parse_sql_file(
    path: Path,
) -> tuple[str, list[tuple[str, str, str | None]], str, dict[str, str]]:
    """Return (description, params, sql, entity_types).

    Leading comment block is consumed; remainder is executed verbatim.
    Param lines: ``-- :name TYPE [default]``
    Entity annotation lines: ``-- @entity col_name entity_type``
    """
    lines = path.read_text().splitlines()
    description = ""
    params: list[tuple[str, str, str | None]] = []
    entity_types: dict[str, str] = {}
    sql_start = len(lines)
    for i, raw in enumerate(lines):
        line = raw.strip()
        if not line.startswith("--"):
            sql_start = i
            break
        entity_m = re.match(r"^--\s+@entity\s+(\w+)\s+(\w+)$", line)
        if entity_m:
            entity_types[entity_m.group(1)] = entity_m.group(2)
            continue
        param_m = re.match(r"^--\s+:(\w+)\s+(\w+)(?:\s+(\S+))?$", line)
        if param_m:
            pname, ptype, pdefault = param_m.groups()
            params.append((pname, ptype.upper(), pdefault))
        elif not description:
            description = line.lstrip("-").strip()
    return description, params, "\n".join(lines[sql_start:]).strip(), entity_types
