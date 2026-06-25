"""Shared fixtures — session-scoped to avoid rebuilding pbc output 4x."""

import subprocess

import duckdb
import pytest
from pb.pipeline.build import find_binary, find_repo
from pb.pipeline.db import db_connection, setup_db_extras
from pb.pipeline.metrics import compute_metrics
from pb.pipeline.reporter import LiveReporter

REPO_ROOT = find_repo()
OPENPAY_DIR = REPO_ROOT / "example" / "openpay-0.1.1b-extract"


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
