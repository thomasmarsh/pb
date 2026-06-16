"""Shared DuckDB schema and INSERT statements for pb_index and friends."""
from __future__ import annotations

from typing import NamedTuple, TypedDict

import duckdb

Conn = duckdb.DuckDBPyConnection


# ── Row types (one NamedTuple per table) ───────────────────────────────────────

class ObjectRow(NamedTuple):
    file: str
    name: str
    kind: str
    ancestor: str | None
    source_text: str | None


class ProcedureRow(NamedTuple):
    file: str
    object: str
    proc_type: str
    name: str
    modifiers: str | None
    params: str | None
    return_type: str | None
    start_line: int | None
    end_line: int | None
    body_json: str | None
    source_rendered: str | None
    cyclomatic: int


class CallRow(NamedTuple):
    file: str
    object: str
    from_proc: str
    to_name: str
    call_type: str


class DwControlRow(NamedTuple):
    file: str
    dw_name: str
    control_name: str | None
    control_type: str | None
    band: str | None
    x: int | None
    y: int | None
    width: int | None
    height: int | None
    expression: str | None
    tab_seq: int | None
    source_line: int | None


class DwRetrieveTableRow(NamedTuple):
    file: str
    dw_name: str
    table_name: str


class DwRetrieveColumnRow(NamedTuple):
    file: str
    dw_name: str
    column_fqn: str
    table_name: str | None
    column_name: str


class DwRetrieveWhereRow(NamedTuple):
    file: str
    dw_name: str
    idx: int
    exp1: str | None
    op: str | None
    exp2: str | None
    logic: str | None


class DwArgumentRow(NamedTuple):
    file: str
    dw_name: str
    arg_name: str
    arg_type: str | None


class InheritsRow(NamedTuple):
    from_object: str
    to_object: str


class SqlStatementRow(NamedTuple):
    file: str
    object: str
    proc_name: str
    stmt_idx: int
    operation: str | None
    raw_sql: str
    parsed_json: str | None
    tables: list[str] | None
    columns: list[str] | None
    has_into: bool
    has_cursor: bool
    parse_ok: bool


# ── Batch container ────────────────────────────────────────────────────────────

class RowBatch(TypedDict):
    objects: list[ObjectRow]
    procedures: list[ProcedureRow]
    calls: list[CallRow]
    dw_controls: list[DwControlRow]
    dw_retrieve_tables: list[DwRetrieveTableRow]
    dw_retrieve_columns: list[DwRetrieveColumnRow]
    dw_retrieve_where: list[DwRetrieveWhereRow]
    dw_arguments: list[DwArgumentRow]
    inherits: list[InheritsRow]
    sql_statements: list[SqlStatementRow]


def new_row_batch() -> RowBatch:
    return RowBatch(
        objects=[],
        procedures=[],
        calls=[],
        dw_controls=[],
        dw_retrieve_tables=[],
        dw_retrieve_columns=[],
        dw_retrieve_where=[],
        dw_arguments=[],
        inherits=[],
        sql_statements=[],
    )


TABLES = [
    'objects',
    'procedures',
    'calls',
    'dw_controls',
    'dw_retrieve_tables',
    'dw_retrieve_columns',
    'dw_retrieve_where',
    'dw_arguments',
    'inherits',
    'sql_statements',
]

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
    stmt_idx    INT  NOT NULL,
    operation   TEXT,
    raw_sql     TEXT,
    parsed_json JSON,
    tables      TEXT[],
    columns     TEXT[],
    has_into    BOOLEAN,
    has_cursor  BOOLEAN,
    parse_ok    BOOLEAN
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
        NULL::INT    AS stmt_idx
    FROM dw_retrieve_tables t

    UNION ALL

    SELECT
        s.file,
        s.object,
        'powerscript' AS source,
        s.operation,
        unnest(s.tables) AS table_name,
        s.proc_name,
        s.stmt_idx
    FROM sql_statements s
    WHERE s.tables IS NOT NULL AND len(s.tables) > 0
"""

INSERT = {
    'objects':             'INSERT INTO objects VALUES (?,?,?,?,?)',
    'procedures':          'INSERT INTO procedures VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
    'calls':               'INSERT INTO calls VALUES (?,?,?,?,?)',
    'dw_controls':         'INSERT INTO dw_controls VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
    'dw_retrieve_tables':  'INSERT INTO dw_retrieve_tables VALUES (?,?,?)',
    'dw_retrieve_columns': 'INSERT INTO dw_retrieve_columns VALUES (?,?,?,?,?)',
    'dw_retrieve_where':   'INSERT INTO dw_retrieve_where VALUES (?,?,?,?,?,?,?)',
    'dw_arguments':        'INSERT INTO dw_arguments VALUES (?,?,?,?)',
    'inherits':            'INSERT INTO inherits VALUES (?,?)',
    'sql_statements':      'INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
}


def create_schema(conn: Conn) -> None:
    for stmt in SCHEMA_SQL.split(';'):
        stmt = stmt.strip()
        if stmt:
            conn.execute(stmt)
    conn.execute(_ALL_SQL_TABLES_VIEW)


def drop_tables(conn: Conn) -> None:
    """Drop all data tables and file_state (full reset)."""
    conn.execute("DROP VIEW IF EXISTS all_sql_tables")
    for t in TABLES + ['file_state']:
        conn.execute(f"DROP TABLE IF EXISTS {t}")
