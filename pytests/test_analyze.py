"""Tests for pbtools.analyze."""
import os
import subprocess
import tempfile

import duckdb
import pytest

REPO_ROOT   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OPENPAY_DIR = os.path.join(REPO_ROOT, 'example', 'openpay-src')


@pytest.fixture(scope='module')
def db_path():
    tmp_dir = tempfile.mkdtemp()
    path = os.path.join(tmp_dir, 'test.duckdb')

    runner = subprocess.run(
        ['cabal', 'run', 'pb-runner', '-v0', '--', '-i', OPENPAY_DIR, '--jsonl'],
        capture_output=True, cwd=REPO_ROOT,
    )
    assert runner.returncode == 0, f"pb-runner failed: {runner.stderr.decode()[:500]}"

    from pbtools.index import run_from_jsonl_lines
    from pbtools.analyze import run as analyze_run

    lines = runner.stdout.decode().splitlines()
    run_from_jsonl_lines(lines, path)
    analyze_run(path)

    yield path

    os.unlink(path)
    os.rmdir(tmp_dir)


@pytest.fixture(scope='module')
def analyzed_conn(db_path):
    conn = duckdb.connect(db_path, read_only=True)
    yield conn
    conn.close()


def q(conn, sql: str):
    return conn.execute(sql).fetchone()[0]


# ── unit tests (no db needed) ─────────────────────────────────────────────────

def test_cyclomatic_nonzero_for_function_with_if():
    from pbtools.analyze import count_branches
    body = [{
        "tag": "if",
        "cond": {"tag": "raw", "tokens": []},
        "then": [{"tag": "return", "expr": None}],
        "elseIfs": [],
        "else": None,
    }]
    assert count_branches(body) == 1
    assert count_branches(body) + 1 == 2

    nested = [{"tag": "for", "body": body}]
    assert count_branches(nested) == 2

    assert count_branches([]) == 0


# ── reporter integration ──────────────────────────────────────────────────────

def test_analyze_run_emits_reporter_events(db_path):
    from pbtools.analyze import run as analyze_run
    from pbtools.reporter import RecordingReporter

    reporter = RecordingReporter()
    analyze_run(db_path, reporter)

    types = {e['type'] for e in reporter.events}
    assert 'analyze_start' in types
    assert 'analyze_end' in types

    n_procs = next(e['n_procs'] for e in reporter.events if e['type'] == 'analyze_start')
    assert n_procs > 0

    extract_count    = sum(1 for e in reporter.events if e['type'] == 'analyze_extract')
    cyclomatic_count = sum(1 for e in reporter.events if e['type'] == 'analyze_cyclomatic')
    assert extract_count == n_procs
    assert cyclomatic_count == n_procs

    metric_labels = [e['label'] for e in reporter.events if e['type'] == 'analyze_metrics']
    assert 'done' in metric_labels


# ── integration tests ─────────────────────────────────────────────────────────

def test_calls_table_populated_after_extract(analyzed_conn):
    count = q(analyzed_conn, "SELECT count(*) FROM calls")
    assert count > 0, "calls table is empty after extract_calls"

    call_types = {r[0] for r in analyzed_conn.execute(
        "SELECT DISTINCT call_type FROM calls"
    ).fetchall()}
    assert 'call_expr' in call_types, f"no call_expr rows; found types: {call_types}"


def test_object_metrics_has_all_objects(analyzed_conn):
    metric_objects = q(analyzed_conn, "SELECT count(*) FROM object_metrics")
    assert metric_objects > 0, "object_metrics table is empty"
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
        f"top in_degree object '{obj}' has only {indegree} incoming edges"
    )
