"""Shared fixtures — session-scoped to avoid rebuilding pb-runner output 4x."""

import io
import subprocess

import duckdb
import pytest

from pb_cli.shell.build import find_repo
from pb_cli.shell.db import db_connection
from pb_cli.shell.dead_code import build_dead_code_table
from pb_cli.shell.importing import run_from_jsonl_lines
from pb_cli.shell.metrics import compute_metrics
from pb_cli.shell.reporter import LiveReporter
from pb_cli.shell.type_resolution import build_type_tables

REPO_ROOT = find_repo()
OPENPAY_DIR = REPO_ROOT / "example" / "openpay-src"


@pytest.fixture(scope="session")
def jsonl_text() -> str:
    """Run pb-runner once for the entire test session."""
    runner = subprocess.run(
        [
            "cabal",
            "run",
            "--project-dir",
            str(REPO_ROOT / "parser"),
            "pb-runner",
            "-v0",
            "--",
            "-i",
            str(OPENPAY_DIR),
            "--jsonl",
        ],
        capture_output=True,
        cwd=str(REPO_ROOT / "parser"),
    )
    assert runner.returncode == 0, runner.stderr.decode()
    return runner.stdout.decode()


@pytest.fixture(scope="session")
def db_path(jsonl_text: str, tmp_path_factory) -> str:
    """Create an analyzed DuckDB once for the entire session."""
    tmp = tmp_path_factory.mktemp("db")
    db = str(tmp / "test.duckdb")

    run_from_jsonl_lines(io.StringIO(jsonl_text), db)

    reporter = LiveReporter()
    with db_connection(db) as conn, reporter.analyze_progress() as progress:
        compute_metrics(conn, progress)
        build_type_tables(conn)
        build_dead_code_table(conn)

    return db


@pytest.fixture(scope="session")
def db_conn(db_path: str):
    """Connection to the session-scoped database."""
    conn = duckdb.connect(db_path, read_only=True)
    yield conn
    conn.close()
