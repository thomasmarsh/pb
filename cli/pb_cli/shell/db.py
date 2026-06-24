"""Database connection management and compat-layer setup for the new DuckDB schema.

After pb-runner --db creates a fresh DuckDB with the Haskell-native schema,
setup_compat_layer() adds:
  - compat_objects / compat_procedures / compat_calls / compat_inherits views
    that expose the old column names (name instead of object/proc_name, plus
    NULL stubs for dropped columns like body_json / type_blocks_json).
  - compat_metadata table (key-value store for ingestion_root, etc.)
  - object_metrics table (written by compute_metrics after indexing)

These compat_* views are explicitly named as legacy so they can be removed once
the explorer services are migrated to the new column names.
"""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import duckdb

Conn = duckdb.DuckDBPyConnection

_SQL_DIR = Path(__file__).parent.parent / "sql"
_COUNT_SQL_PARSE_FAILURES = (_SQL_DIR / "count_sql_parse_failures.sql").read_text()

_COMPAT_DDL = """
CREATE OR REPLACE VIEW compat_objects AS
  SELECT file, object AS name, kind, ancestor,
         NULL::TEXT AS source_text,
         NULL::TEXT AS type_blocks_json,
         NULL::TEXT AS dw_json
  FROM objects;

CREATE OR REPLACE VIEW compat_procedures AS
  SELECT file, object, proc_name AS name, object AS owner, proc_type,
         start_line, end_line,
         NULL::TEXT AS body_json,
         NULL::TEXT AS modifiers,
         params, return_type, cyclomatic, cfg_json, cps_graph_json
  FROM procedures;

CREATE OR REPLACE VIEW compat_calls AS
  SELECT file, object, from_proc, to_name, call_type
  FROM call_sites;

CREATE OR REPLACE VIEW compat_inherits AS
  SELECT object AS from_object, ancestor AS to_object
  FROM objects WHERE ancestor IS NOT NULL;

CREATE OR REPLACE VIEW compat_dw_controls AS
  SELECT file, object AS dw_name, band, control_type, name AS control_name,
         x, y, width, height, expression,
         NULL::INTEGER AS tab_seq, NULL::INTEGER AS source_line
  FROM dw_controls;

CREATE OR REPLACE VIEW compat_dead_procedures AS
  SELECT object, proc_name AS name, proc_type, cyclomatic, confidence,
         caller_count_naive, caller_count_scoped
  FROM dead_code;

CREATE OR REPLACE VIEW compat_global_vars AS
  SELECT file, object, var_name, var_type, mods AS modifiers, NULL::TEXT AS scope
  FROM global_vars;

CREATE OR REPLACE VIEW all_sql_tables AS
  SELECT
    s.file,
    s.object,
    'powerscript' AS source,
    s.operation,
    TRIM(t) AS table_name,
    s.proc_name,
    s.line
  FROM sql_statements s,
       unnest(string_split(s.tables, ',')) t(t)
  WHERE s.tables IS NOT NULL AND s.tables != '';

CREATE TABLE IF NOT EXISTS compat_metadata (
  key TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS object_metrics (
  object         TEXT NOT NULL,
  in_degree      INT,
  out_degree     INT,
  betweenness    DOUBLE,
  pagerank       DOUBLE,
  max_cyclomatic INT,
  avg_cyclomatic DOUBLE,
  dit            INT,
  cbo            INT
);
"""


@contextmanager
def db_connection(path: str | Path, read_only: bool = False) -> Generator[Conn, None, None]:
    conn = duckdb.connect(str(path), read_only=read_only)
    try:
        yield conn
    finally:
        conn.close()


def setup_compat_layer(conn: Conn) -> None:
    """Create compat_* views and helper tables on a freshly-written Haskell DuckDB."""
    for stmt in _COMPAT_DDL.split(";"):
        stmt = stmt.strip()
        if stmt:
            conn.execute(stmt)


def count_sql_parse_failures(conn: Conn) -> int:
    """Count SQL statements that looked like SQL but sqlglot couldn't parse."""
    row = conn.execute(_COUNT_SQL_PARSE_FAILURES).fetchone()
    return row[0] if row else 0


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
