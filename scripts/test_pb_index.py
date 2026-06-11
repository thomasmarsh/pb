"""
Integration tests for pb_index.py.

Requires:
  - cabal build (pb-runner must be compiled)
  - duckdb Python package
  - pytest

Run:
  pytest scripts/test_pb_index.py
"""
import json
import os
import subprocess
import sys
import tempfile

import duckdb
import pytest

SCRIPTS_DIR = os.path.dirname(__file__)
REPO_ROOT   = os.path.dirname(SCRIPTS_DIR)
OPENPAY_DIR = os.path.join(REPO_ROOT, 'example', 'openpay')


@pytest.fixture(scope='module')
def db_conn():
    """Build pb.duckdb from the openpay corpus in a temp file; yield a connection."""
    tmp_dir = tempfile.mkdtemp()
    db_path = os.path.join(tmp_dir, 'test.duckdb')

    runner = subprocess.run(
        ['cabal', 'run', 'pb-runner', '-v0', '--', '-i', OPENPAY_DIR, '--jsonl'],
        capture_output=True, cwd=REPO_ROOT,
    )
    assert runner.returncode == 0, f"pb-runner failed: {runner.stderr.decode()[:500]}"

    indexer_env = dict(os.environ, PYTHONPATH=SCRIPTS_DIR)
    indexer = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS_DIR, 'pb_index.py'), db_path],
        input=runner.stdout,
        capture_output=True,
        env=indexer_env,
    )
    assert indexer.returncode == 0, f"pb_index failed: {indexer.stderr.decode()[:500]}"

    conn = duckdb.connect(db_path, read_only=True)
    yield conn
    conn.close()
    os.unlink(db_path)
    os.rmdir(tmp_dir)


def q(conn, sql: str):
    return conn.execute(sql).fetchone()[0]


# ---------------------------------------------------------------------------

def test_objects_table_populated(db_conn):
    count = q(db_conn, "SELECT count(*) FROM objects")
    assert count > 0, "objects table is empty"
    # only known kinds
    kinds = {r[0] for r in db_conn.execute("SELECT DISTINCT kind FROM objects").fetchall()}
    assert kinds <= {'powerscript', 'datawindow', 'pipeline', 'project'}, \
        f"unexpected kind values: {kinds - {'powerscript','datawindow','pipeline','project'}}"
    # one row per file
    file_count = q(db_conn, "SELECT count(DISTINCT file) FROM objects")
    assert file_count == count, "duplicate objects rows (more than one per file)"


def test_procedures_table_has_functions(db_conn):
    fn_count = q(db_conn, "SELECT count(*) FROM procedures WHERE proc_type = 'function'")
    assert fn_count > 0, "no function rows in procedures table"
    ev_count = q(db_conn, "SELECT count(*) FROM procedures WHERE proc_type = 'event'")
    assert ev_count > 0, "no event rows in procedures table"
    # all procedures rows have a non-empty name
    unnamed = q(db_conn, "SELECT count(*) FROM procedures WHERE name IS NULL OR name = ''")
    assert unnamed == 0, f"{unnamed} procedures rows have empty name"


def test_dw_controls_table_has_band(db_conn):
    total = q(db_conn, "SELECT count(*) FROM dw_controls")
    assert total > 0, "dw_controls table is empty"
    with_band = q(db_conn, "SELECT count(*) FROM dw_controls WHERE band IS NOT NULL")
    assert with_band > 0, "no dw_controls rows have a band value"


def test_inherits_edges_match_declared_ancestors(db_conn):
    count = q(db_conn, "SELECT count(*) FROM inherits")
    assert count > 200, f"expected >200 inherits rows, got {count}"
    # every from_object in inherits should appear in objects
    orphans = q(db_conn, """
        SELECT count(*) FROM inherits i
        LEFT JOIN objects o ON i.from_object = o.name
        WHERE o.name IS NULL
    """)
    assert orphans == 0, f"{orphans} inherits.from_object values not in objects table"


def test_dw_retrieve_tables_populated_when_e2_done(db_conn):
    count = q(db_conn, "SELECT count(*) FROM dw_retrieve_tables")
    assert count > 0, "dw_retrieve_tables is empty — E2 PBSELECT data missing?"
    # every referenced dw_name should be a known DW file
    unknown = q(db_conn, """
        SELECT count(*) FROM dw_retrieve_tables dt
        LEFT JOIN objects o ON dt.file = o.file
        WHERE o.file IS NULL
    """)
    assert unknown == 0, f"{unknown} dw_retrieve_tables rows reference unknown files"
