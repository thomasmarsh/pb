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

Conn = duckdb.DuckDBPyConnection


@contextmanager
def db_connection(path: str | Path, read_only: bool = False) -> Generator[Conn, None, None]:
    conn = duckdb.connect(str(path), read_only=read_only)
    try:
        yield conn
    finally:
        conn.close()


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS objects (
    file        TEXT NOT NULL,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    ancestor    TEXT,
    source_text TEXT
);

CREATE TABLE IF NOT EXISTS procedures (
    file             TEXT NOT NULL,
    object           TEXT NOT NULL,
    proc_type        TEXT NOT NULL,
    name             TEXT NOT NULL,
    modifiers        TEXT,
    params           TEXT,
    return_type      TEXT,
    start_line       INT,
    end_line         INT,
    body_json        JSON,
    source_rendered  TEXT,
    cyclomatic       INT
);

CREATE TABLE IF NOT EXISTS calls (
    file       TEXT,
    object     TEXT,
    from_proc  TEXT,
    to_name    TEXT,
    call_type  TEXT
);

CREATE TABLE IF NOT EXISTS dw_controls (
    file         TEXT NOT NULL,
    dw_name      TEXT NOT NULL,
    control_name TEXT,
    control_type TEXT,
    band         TEXT,
    x            INT,
    y            INT,
    width        INT,
    height       INT,
    expression   TEXT,
    tab_seq      INT,
    source_line  INT
);

CREATE TABLE IF NOT EXISTS dw_retrieve_tables (
    file       TEXT NOT NULL,
    dw_name    TEXT NOT NULL,
    table_name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dw_retrieve_columns (
    file        TEXT NOT NULL,
    dw_name     TEXT NOT NULL,
    column_fqn  TEXT NOT NULL,
    table_name  TEXT,
    column_name TEXT
);

CREATE TABLE IF NOT EXISTS dw_retrieve_where (
    file    TEXT NOT NULL,
    dw_name TEXT NOT NULL,
    idx     INT  NOT NULL,
    exp1    TEXT,
    op      TEXT,
    exp2    TEXT,
    logic   TEXT
);

CREATE TABLE IF NOT EXISTS dw_arguments (
    file     TEXT NOT NULL,
    dw_name  TEXT NOT NULL,
    arg_name TEXT NOT NULL,
    arg_type TEXT
);

CREATE TABLE IF NOT EXISTS inherits (
    from_object TEXT NOT NULL,
    to_object   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sql_statements (
    file        TEXT NOT NULL,
    object      TEXT NOT NULL,
    proc_name   TEXT NOT NULL,
    line    INT  NOT NULL,
    operation   TEXT,
    raw_sql     TEXT,
    parsed_json JSON,
    tables      TEXT[],
    columns     TEXT[],
    has_into    BOOLEAN,
    has_cursor  BOOLEAN,
    parse_ok    BOOLEAN
);

CREATE TABLE IF NOT EXISTS parse_errors (
    file        TEXT NOT NULL,
    error_kind  TEXT NOT NULL,
    message     TEXT NOT NULL,
    object      TEXT,
    proc_name   TEXT,
    line        INT,
    snippet     TEXT
);
"""

_ALL_SQL_TABLES_VIEW = """
CREATE OR REPLACE VIEW all_sql_tables AS
    SELECT
        t.file,
        t.dw_name   AS object,
        'datawindow' AS source,
        'retrieve'   AS operation,
        t.table_name,
        NULL         AS proc_name,
        NULL::INT    AS line
    FROM dw_retrieve_tables t

    UNION ALL

    SELECT
        s.file,
        s.object,
        'powerscript' AS source,
        s.operation,
        unnest(s.tables) AS table_name,
        s.proc_name,
        s.line
    FROM sql_statements s
    WHERE s.tables IS NOT NULL AND len(s.tables) > 0
"""

INSERT = {
    "objects": "INSERT INTO objects VALUES (?,?,?,?,?)",
    "procedures": "INSERT INTO procedures VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
    "calls": "INSERT INTO calls VALUES (?,?,?,?,?)",
    "dw_controls": "INSERT INTO dw_controls VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
    "dw_retrieve_tables": "INSERT INTO dw_retrieve_tables VALUES (?,?,?)",
    "dw_retrieve_columns": "INSERT INTO dw_retrieve_columns VALUES (?,?,?,?,?)",
    "dw_retrieve_where": "INSERT INTO dw_retrieve_where VALUES (?,?,?,?,?,?,?)",
    "dw_arguments": "INSERT INTO dw_arguments VALUES (?,?,?,?)",
    "inherits": "INSERT INTO inherits VALUES (?,?)",
    "sql_statements": "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
    "parse_errors": "INSERT INTO parse_errors VALUES (?,?,?,?,?,?,?)",
}


def create_schema(conn: Conn) -> None:
    for stmt in SCHEMA_SQL.split(";"):
        stmt = stmt.strip()
        if stmt:
            conn.execute(stmt)
    conn.execute(_ALL_SQL_TABLES_VIEW)


def count_sql_parse_failures(conn: Conn) -> int:
    """Count SQL statements that looked like SQL but sqlglot couldn't parse.

    Excludes statements that are intentionally never parsed (cursor ops,
    CONNECT/DISCONNECT, EXECUTE IMMEDIATE/PROCEDURE, DECLARE ... DYNAMIC
    CURSOR FOR <prepared-stmt-id>, DECLARE ... PROCEDURE FOR <storedproc> —
    see sql.py's _SKIP_RE), since those report parse_ok=False by design,
    not by failure.
    """
    row = conn.execute(
        "SELECT count(*) FROM sql_statements "
        "WHERE NOT parse_ok "
        "AND operation NOT IN "
        "('CONNECT', 'DISCONNECT', 'EXECUTE', 'OPEN', 'FETCH', 'CLOSE') "
        "AND NOT (operation = 'DECLARE' "
        "AND regexp_matches(raw_sql, 'DYNAMIC\\s+CURSOR\\s+FOR\\s+\\w+\\s*;?\\s*$', 'i'))"
        "AND NOT (operation = 'DECLARE' "
        "AND regexp_matches(raw_sql, '\\w+\\s+PROCEDURE\\s+FOR\\s+\\w+', 'i'))"
    ).fetchone()
    return row[0] if row else 0


def insert_parse_errors(conn: Conn, rows: list[ParseErrorRow]) -> None:
    if rows:
        conn.executemany(INSERT["parse_errors"], rows)


def drop_tables(conn: Conn) -> None:
    """Drop all data tables and file_state (full reset)."""
    conn.execute("DROP VIEW IF EXISTS all_sql_tables")
    for t in TABLES + ["file_state"]:
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


def parse_sql_file(path: Path) -> tuple[str, list[tuple[str, str, str | None]], str]:
    """Return (description, params, sql).

    Leading comment block is consumed; remainder is executed verbatim.
    Param lines: ``-- :name TYPE [default]``
    """
    lines = path.read_text().splitlines()
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
            pname, ptype, pdefault = m.groups()
            params.append((pname, ptype.upper(), pdefault))
        elif not description:
            description = line.lstrip("-").strip()
    return description, params, "\n".join(lines[sql_start:]).strip()
