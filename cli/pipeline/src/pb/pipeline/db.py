"""Database connection management for the DuckDB schema."""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import duckdb

Conn = duckdb.DuckDBPyConnection

_SQL_DIR = Path(__file__).resolve().parents[4] / "sql"
_COUNT_SQL_PARSE_FAILURES = (_SQL_DIR / "count_sql_parse_failures.sql").read_text()

_EXTRAS_DDL = """
CREATE TABLE IF NOT EXISTS metadata (
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


def setup_db_extras(conn: Conn) -> None:
    """Create helper tables (metadata, object_metrics) on a freshly-written Haskell DuckDB."""
    for stmt in _EXTRAS_DDL.split(";"):
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
