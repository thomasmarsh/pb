"""Shared fixtures — session-scoped to avoid rebuilding pbc output 4x."""

import os
import subprocess

import duckdb
import pytest
from pb.pipeline.build import find_binary, find_repo, find_sql_worker
from pb.pipeline.db import db_connection, setup_db_extras
from pb.pipeline.metrics import compute_metrics
from pb.pipeline.reporter import LiveReporter

REPO_ROOT = find_repo()
OPENPAY_DIR = REPO_ROOT / "example" / "openpay-0.1.1b-extract"
OPENPAY_DDL = REPO_ROOT / "example" / "openpay-0.1.1b" / "schema-0.1.1.sql"


@pytest.fixture(scope="session")
def db_path(tmp_path_factory) -> str:
    """Create an analyzed DuckDB once for the entire session via pbc --db."""
    tmp = tmp_path_factory.mktemp("db")
    db = str(tmp / "test.duckdb")

    binary = find_binary(REPO_ROOT)
    result = subprocess.run(
        [str(binary), "-i", str(OPENPAY_DIR), "--db", db],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr

    reporter = LiveReporter()
    with db_connection(db) as conn:
        setup_db_extras(conn)
        with reporter.analyze_progress() as progress:
            compute_metrics(conn, progress)

    return db


@pytest.fixture(scope="session")
def db_conn(db_path: str):
    """Read-only connection to the session-scoped database."""
    conn = duckdb.connect(db_path, read_only=True)
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def schema_db_path(tmp_path_factory) -> str:
    """Build a second DuckDB with the DDL catalog + SQL bridge enabled.

    `Sch` (Plan 148: schema_objects/schema_morphisms/catalog_*/
    sql_statement_columns) is only fully populated when both --ddl and the
    sqlglot bridge (PB_SQL_WORKER) are active. The shared `db_path` fixture
    has neither, so Plan 153's D2/D6 tests need their own build rather than
    silently asserting against an empty Sch.
    """
    sql_worker = find_sql_worker()
    assert sql_worker is not None, "pb-sql-worker not found — build cli/.venv first"

    tmp = tmp_path_factory.mktemp("schema_db")
    db = str(tmp / "schema_test.duckdb")

    binary = find_binary(REPO_ROOT)
    run_env = os.environ.copy()
    run_env["PB_SQL_WORKER"] = str(sql_worker)
    result = subprocess.run(
        [str(binary), "-i", str(OPENPAY_DIR), "--db", db, "--ddl", str(OPENPAY_DDL)],
        capture_output=True,
        text=True,
        env=run_env,
    )
    assert result.returncode == 0, result.stderr

    with db_connection(db) as conn:
        setup_db_extras(conn)

    return db


@pytest.fixture(scope="session")
def schema_db_conn(schema_db_path: str):
    """Read-only connection to the DDL+bridge-enabled session-scoped database."""
    conn = duckdb.connect(schema_db_path, read_only=True)
    yield conn
    conn.close()
