"""Shared fixtures — session-scoped to avoid rebuilding pbc output 4x."""

import subprocess
import sys

import duckdb
import pytest
from pb.pipeline.build import find_binary, find_repo
from pb.pipeline.db import db_connection, setup_db_extras
from pb.pipeline.metrics import compute_metrics
from pb.pipeline.reporter import LiveReporter

REPO_ROOT = find_repo()
OPENPAY_DIR = REPO_ROOT / "example" / "openpay-0.1.1b-extract"
OPENPAY_DDL = REPO_ROOT / "example" / "openpay-0.1.1b" / "schema-0.1.1.sql"
OPENPAY_ARCHIVE_DDL = REPO_ROOT / "example" / "openpay-0.1.1b" / "schema-archive.sql"


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
    sqlglot bridge (via --sql-worker-python) are active. The shared `db_path`
    fixture has neither, so Plan 153's D2/D6 tests need their own build
    rather than silently asserting against an empty Sch.
    """
    tmp = tmp_path_factory.mktemp("schema_db")
    db = str(tmp / "schema_test.duckdb")

    binary = find_binary(REPO_ROOT)
    result = subprocess.run(
        [
            str(binary), "-i", str(OPENPAY_DIR), "--db", db,
            "--ddl", str(OPENPAY_DDL), "--sql-dialect", "mysql",
            "--sql-worker-python", sys.executable,
        ],
        capture_output=True,
        text=True,
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


@pytest.fixture(scope="session")
def multi_schema_db_path(tmp_path_factory) -> str:
    """Build a third DuckDB with two schema-tagged DDL files + a configured
    default namespace — the real multi-schema shape Plan 157 targets.

    `schema_db_path` above uses one untagged `--ddl`, so every catalog row's
    namespace is NULL and Plan 157's default-namespace resolution is a no-op
    by construction. This fixture instead tags OpenPay's real DDL as
    `OPENPAY` and adds a second, synthetic `OPENPAY_ARCHIVE` schema
    (`schema-archive.sql`) redefining `misth_zpkrat` — a table with real
    unqualified SQL/DW-retrieve usage in the corpus (`w_misth_zpkrat_form.srw`
    et al.). This is the closest thing to a real reindex against a
    multi-schema corpus without waiting for one to show up externally: real
    PowerScript/DataWindow source, a genuinely duplicated table name across
    two DDL-tagged schemas, and a configured default — the exact shape the
    `clinicalaccession`-in-3-schemas bug report had.
    """
    tmp = tmp_path_factory.mktemp("multi_schema_db")
    db = str(tmp / "multi_schema_test.duckdb")

    binary = find_binary(REPO_ROOT)
    result = subprocess.run(
        [
            str(binary), "-i", str(OPENPAY_DIR), "--db", db,
            "--ddl", f"OPENPAY:{OPENPAY_DDL}",
            "--ddl", f"OPENPAY_ARCHIVE:{OPENPAY_ARCHIVE_DDL}",
            "--sql-dialect", "mysql",
            "--sql-worker-python", sys.executable,
            # Deliberately uppercase, unlike the metadata write below: this
            # exercises PB.Analysis.SchemaCategory's case-insensitive
            # resolution (Plan 157 Phase 4/5 regression fix) on every build
            # of this fixture, not just in the dedicated Haskell unit test.
            "--default-namespace", "OPENPAY",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr

    with db_connection(db) as conn:
        setup_db_extras(conn)
        # Lowercase, matching what pb.pipeline.pipeline.run() actually
        # writes in production (it normalizes before this exact insert) --
        # this fixture calls the binary directly, bypassing run(), so it
        # must replicate that normalization by hand to stay representative.
        conn.execute(
            "INSERT OR REPLACE INTO metadata VALUES ('default_namespace', 'openpay')"
        )

    return db


@pytest.fixture(scope="session")
def multi_schema_db_conn(multi_schema_db_path: str):
    """Read-only connection to the multi-schema session-scoped database."""
    conn = duckdb.connect(multi_schema_db_path, read_only=True)
    yield conn
    conn.close()
