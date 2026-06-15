"""Tests for pb_cli.analyze."""
import pytest


def q(conn, sql: str):
    return conn.execute(sql).fetchone()[0]


# ── unit tests (no db needed) ─────────────────────────────────────────────────

def test_count_branches_uses_bs_tags():
    # Tags in body_json are BsIf/BsFor/BsDo/BsChoose (Haskell constructor names),
    # not the old short forms 'if'/'for'/'do'/'choose'.
    from pb_cli.analyze import count_branches
    bs_if = {
        "tag": "BsIf",
        "contents": {
            "cond": {"tag": "ExBool", "contents": True},
            "then": [{"tag": "BsReturn", "contents": None}],
            "elseIfs": [],
            "else": None,
        },
    }
    assert count_branches([bs_if]) == 1, "BsIf should count as one branch"

    bs_for = {"tag": "BsFor", "contents": {"body": [bs_if]}}
    assert count_branches([bs_for]) == 2, "BsFor + nested BsIf should count as 2"

    assert count_branches([]) == 0


def test_count_branches_old_tags_not_matched():
    # Regression: old tag names ('if', 'for') must NOT match — they no longer
    # appear in pb-runner output after the aeson-typescript rewrite.
    from pb_cli.analyze import count_branches
    old_if = {"tag": "if", "cond": {}, "then": [], "elseIfs": [], "else": None}
    assert count_branches([old_if]) == 0, "old 'if' tag must not be counted"


def test_walk_calls_ex_call():
    from pb_cli.analyze import walk_calls
    node = {
        "tag": "ExCall",
        "callee": {"segments": [{"name": "isnull", "subscript": None}]},
        "args": [["x"]],
    }
    results = walk_calls(node)
    assert any(name == "isnull" for name, _ in results), (
        f"ExCall callee 'isnull' not extracted; got {results}"
    )


def test_walk_calls_ex_method_call():
    from pb_cli.analyze import walk_calls
    node = {
        "tag": "ExMethodCall",
        "receiver": {"tag": "ExLvalue", "contents": {"segments": [{"name": "dw_1", "subscript": None}]}},
        "method": "Reset",
        "args": [],
    }
    results = walk_calls(node)
    assert any(name == "Reset" for name, _ in results), (
        f"ExMethodCall method 'Reset' not extracted; got {results}"
    )


def test_walk_calls_ex_dispatch():
    from pb_cli.analyze import walk_calls
    node = {
        "tag": "ExDispatch",
        "contents": {
            "name": "ie_checkmenu",
            "mode": "DmTrigger",
            "dynamic": True,
            "event": True,
            "object": None,
            "args": [],
        },
    }
    results = walk_calls(node)
    assert any(name == "ie_checkmenu" for name, _ in results), (
        f"ExDispatch name 'ie_checkmenu' not extracted; got {results}"
    )


# ── reporter integration ──────────────────────────────────────────────────────

def test_analyze_run_emits_reporter_events(db_path):
    from pb_cli.analyze import run as analyze_run
    from pb_cli.reporter import RecordingReporter

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

def test_calls_table_populated_after_extract(db_conn):
    count = q(db_conn, "SELECT count(*) FROM calls")
    assert count > 0, "calls table is empty after extract_calls"

    call_types = {r[0] for r in db_conn.execute(
        "SELECT DISTINCT call_type FROM calls"
    ).fetchall()}
    assert 'ExCall' in call_types, f"no ExCall rows; found types: {call_types}"


def test_object_metrics_has_all_objects(db_conn):
    metric_objects = q(db_conn, "SELECT count(*) FROM object_metrics")
    assert metric_objects > 0, "object_metrics table is empty"
    missing = q(db_conn, """
        SELECT count(DISTINCT c.object) FROM calls c
        LEFT JOIN object_metrics m ON c.object = m.object
        WHERE m.object IS NULL
    """)
    assert missing == 0, (
        f"{missing} objects appear in calls but not in object_metrics"
    )


def test_pagerank_sums_to_one(db_conn):
    total = db_conn.execute(
        "SELECT sum(pagerank) FROM object_metrics WHERE pagerank IS NOT NULL"
    ).fetchone()[0]
    assert total is not None, "no pagerank values in object_metrics"
    assert abs(total - 1.0) < 0.01, f"pagerank sum {total:.4f} is not close to 1.0"


def test_high_fanin_objects_identified(db_conn):
    top = db_conn.execute(
        "SELECT object, in_degree FROM object_metrics ORDER BY in_degree DESC LIMIT 1"
    ).fetchone()
    assert top is not None, "no rows in object_metrics"
    obj, indegree = top
    assert indegree > 5, (
        f"top in_degree object '{obj}' has only {indegree} incoming edges"
    )
