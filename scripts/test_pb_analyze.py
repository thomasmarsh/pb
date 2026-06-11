"""
Tests for scripts/pb_analyze.py.

Run from repo root:
  pytest scripts/test_pb_analyze.py

Requires:
  - cabal build (pb-runner compiled)
  - duckdb, networkx Python packages
"""
import json
import os
import subprocess
import sys
import tempfile

import duckdb
import pytest

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT   = os.path.dirname(SCRIPTS_DIR)
OPENPAY_DIR = os.path.join(REPO_ROOT, 'example', 'openpay')

sys.path.insert(0, SCRIPTS_DIR)
from pb_analyze import count_branches, extract_calls, compute_cyclomatic, compute_metrics
from pb_common import create_schema


# ---------------------------------------------------------------------------
# Module-scoped fixture: build temp db from openpay corpus, run pb_analyze
# ---------------------------------------------------------------------------

@pytest.fixture(scope='module')
def analyzed_conn():
    tmp_dir = tempfile.mkdtemp()
    db_path = os.path.join(tmp_dir, 'test.duckdb')

    runner = subprocess.run(
        ['cabal', 'run', 'pb-runner', '-v0', '--', '-i', OPENPAY_DIR, '--jsonl'],
        capture_output=True, cwd=REPO_ROOT,
    )
    assert runner.returncode == 0, f"pb-runner failed: {runner.stderr.decode()[:500]}"

    env = dict(os.environ, PYTHONPATH=SCRIPTS_DIR)
    indexer = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS_DIR, 'pb_index.py'), db_path],
        input=runner.stdout, capture_output=True, env=env,
    )
    assert indexer.returncode == 0, f"pb_index failed: {indexer.stderr.decode()[:500]}"

    analyzer = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS_DIR, 'pb_analyze.py'), db_path],
        capture_output=True, env=env,
    )
    assert analyzer.returncode == 0, (
        f"pb_analyze failed:\n{analyzer.stderr.decode()[:1000]}"
    )

    conn = duckdb.connect(db_path, read_only=True)
    yield conn
    conn.close()
    os.unlink(db_path)
    os.rmdir(tmp_dir)


def q(conn, sql: str):
    return conn.execute(sql).fetchone()[0]


# ---------------------------------------------------------------------------
# Unit test: count_branches (pure function, no DB)
# ---------------------------------------------------------------------------

def test_cyclomatic_nonzero_for_function_with_if():
    body = [{
        "tag": "if",
        "cond": {"tag": "raw", "tokens": []},
        "then": [{"tag": "return", "expr": None}],
        "elseIfs": [],
        "else": None,
    }]
    assert count_branches(body) == 1, "one 'if' node should count as one branch"
    # McCabe: branches + 1 = cyclomatic
    assert count_branches(body) + 1 == 2

    # Nested: if inside for — two branches
    nested = [{"tag": "for", "body": body}]
    assert count_branches(nested) == 2

    # No branches — empty body
    assert count_branches([]) == 0


# ---------------------------------------------------------------------------
# Integration tests against the full openpay corpus
# ---------------------------------------------------------------------------

def test_calls_table_populated_after_extract(analyzed_conn):
    count = q(analyzed_conn, "SELECT count(*) FROM calls")
    assert count > 0, "calls table is empty after extract_calls"

    call_types = {r[0] for r in analyzed_conn.execute(
        "SELECT DISTINCT call_type FROM calls"
    ).fetchall()}
    # At minimum, function calls should be present
    assert 'call_expr' in call_types, f"no call_expr rows; found types: {call_types}"


def test_object_metrics_has_all_objects(analyzed_conn):
    call_objects = q(analyzed_conn, "SELECT count(DISTINCT object) FROM calls")
    metric_objects = q(analyzed_conn, "SELECT count(*) FROM object_metrics")
    assert metric_objects > 0, "object_metrics table is empty"
    # Every src object in calls should be in object_metrics
    missing = q(analyzed_conn, """
        SELECT count(DISTINCT c.object) FROM calls c
        LEFT JOIN object_metrics m ON c.object = m.object
        WHERE m.object IS NULL
    """)
    assert missing == 0, (
        f"{missing} objects appear in calls but not in object_metrics"
    )


def test_pagerank_sums_to_one(analyzed_conn):
    total = analyzed_conn.execute(
        "SELECT sum(pagerank) FROM object_metrics WHERE pagerank IS NOT NULL"
    ).fetchone()[0]
    assert total is not None, "no pagerank values in object_metrics"
    assert abs(total - 1.0) < 0.01, f"pagerank sum {total:.4f} is not close to 1.0"


def test_high_fanin_objects_identified(analyzed_conn):
    top = analyzed_conn.execute(
        "SELECT object, in_degree FROM object_metrics ORDER BY in_degree DESC LIMIT 1"
    ).fetchone()
    assert top is not None, "no rows in object_metrics"
    obj, indegree = top
    assert indegree > 5, (
        f"top in_degree object '{obj}' has only {indegree} incoming edges — "
        "expected a recognisable utility hub with more callers"
    )
