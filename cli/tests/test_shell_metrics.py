"""Tests for pb_cli.shell.metrics — graph metric computation."""

import duckdb

from pb_cli.core.ast_walker import count_branches, walk_calls
from pb_cli.shell.db import create_schema
from pb_cli.shell.metrics import (
    compute_dit_from_edges,
    compute_metrics,
    compute_metrics_from_data,
    fetch_inheritance_edges,
    fetch_metrics_data,
    write_metrics,
)
from pb_cli.shell.reporter import RecordingReporter


def q(conn, sql: str):
    return conn.execute(sql).fetchone()[0]


# ── unit tests (no db needed) ─────────────────────────────────────────────────


def test_count_branches_uses_bs_tags():
    # Tags in body_json are BsIf/BsFor/BsDo/BsChoose (Haskell constructor names),
    # not the old short forms 'if'/'for'/'do'/'choose'.
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
    old_if = {"tag": "if", "cond": {}, "then": [], "elseIfs": [], "else": None}
    assert count_branches([old_if]) == 0, "old 'if' tag must not be counted"


def test_walk_calls_ex_call():
    node = {
        "tag": "ExCall",
        "callee": {"segments": [{"name": "isnull", "subscript": None}]},
        "args": [["x"]],
    }
    results = walk_calls(node)
    assert any(name == "isnull" for name, _ in results), f"ExCall callee 'isnull' not extracted; got {results}"


def test_walk_calls_ex_method_call():
    node = {
        "tag": "ExMethodCall",
        "receiver": {"tag": "ExLvalue", "contents": {"segments": [{"name": "dw_1", "subscript": None}]}},
        "method": "Reset",
        "args": [],
    }
    results = walk_calls(node)
    assert any(name == "Reset" for name, _ in results), f"ExMethodCall method 'Reset' not extracted; got {results}"


def test_walk_calls_ex_dispatch():
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


def test_analyze_run_emits_reporter_events(tmp_path):
    # Use an isolated DB so we don't conflict with the session-scoped read-only db_conn.
    db = str(tmp_path / "test.duckdb")
    conn = duckdb.connect(db)
    create_schema(conn)
    conn.close()

    reporter = RecordingReporter()
    with duckdb.connect(db) as conn, reporter.analyze_progress() as progress:
        compute_metrics(conn, progress)

    types = {e["type"] for e in reporter.events}
    assert "analyze_start" in types
    assert "analyze_end" in types

    # call extraction and cyclomatic are now done during indexing, not analyze
    assert not any(e["type"] == "analyze_extract" for e in reporter.events)
    assert not any(e["type"] == "analyze_cyclomatic" for e in reporter.events)

    metric_labels = [e["label"] for e in reporter.events if e["type"] == "analyze_metrics"]
    assert "done" in metric_labels


# ── integration tests ─────────────────────────────────────────────────────────


def test_calls_table_populated_after_extract(db_conn):
    count = q(db_conn, "SELECT count(*) FROM calls")
    assert count > 0, "calls table is empty after extract_calls"

    call_types = {r[0] for r in db_conn.execute("SELECT DISTINCT call_type FROM calls").fetchall()}
    assert "ExCall" in call_types, f"no ExCall rows; found types: {call_types}"


def test_object_metrics_has_all_objects(db_conn):
    metric_objects = q(db_conn, "SELECT count(*) FROM object_metrics")
    assert metric_objects > 0, "object_metrics table is empty"
    missing = q(
        db_conn,
        """
        SELECT count(DISTINCT c.object) FROM calls c
        LEFT JOIN object_metrics m ON c.object = m.object
        WHERE m.object IS NULL
    """,
    )
    assert missing == 0, f"{missing} objects appear in calls but not in object_metrics"


def test_pagerank_sums_to_one(db_conn):
    total = db_conn.execute("SELECT sum(pagerank) FROM object_metrics WHERE pagerank IS NOT NULL").fetchone()[0]
    assert total is not None, "no pagerank values in object_metrics"
    assert abs(total - 1.0) < 0.01, f"pagerank sum {total:.4f} is not close to 1.0"


def test_high_fanin_objects_identified(db_conn):
    top = db_conn.execute("SELECT object, in_degree FROM object_metrics ORDER BY in_degree DESC LIMIT 1").fetchone()
    assert top is not None, "no rows in object_metrics"
    obj, indegree = top
    assert indegree > 5, f"top in_degree object '{obj}' has only {indegree} incoming edges"


def test_betweenness_values_in_range(db_conn):
    rows = db_conn.execute("SELECT object, betweenness FROM object_metrics WHERE betweenness IS NOT NULL").fetchall()
    assert rows, "no betweenness values in object_metrics"
    out_of_range = [(obj, b) for obj, b in rows if not (0.0 <= b <= 1.0)]
    assert not out_of_range, f"betweenness values outside [0,1]: {out_of_range[:5]}"


def test_cyclomatic_populated_by_indexing(db_conn):
    null_count = q(db_conn, "SELECT count(*) FROM procedures WHERE body_json IS NOT NULL AND cyclomatic IS NULL")
    assert null_count == 0, (
        f"{null_count} procedures with body_json have NULL cyclomatic — cyclomatic should be set during indexing"
    )

    min_cc = q(db_conn, "SELECT min(cyclomatic) FROM procedures WHERE cyclomatic IS NOT NULL")
    assert min_cc >= 1, f"cyclomatic minimum should be 1 (no branches), got {min_cc}"


# ── compute_dit split tests ──────────────────────────────────────────────────


def test_fetch_inheritance_edges_returns_tuples(tmp_path):
    conn = duckdb.connect(str(tmp_path / "test.duckdb"))
    create_schema(conn)
    conn.execute("INSERT INTO inherits VALUES ('parent', 'child')")
    edges = fetch_inheritance_edges(conn)
    conn.close()
    assert edges == [("parent", "child")]


def test_fetch_inheritance_edges_empty(tmp_path):
    conn = duckdb.connect(str(tmp_path / "test.duckdb"))
    create_schema(conn)
    edges = fetch_inheritance_edges(conn)
    conn.close()
    assert edges == []


def test_compute_dit_from_edges_empty():
    assert compute_dit_from_edges([]) == {}


def test_compute_dit_from_edges_single_chain():
    # A → B → C means parent=A child=B, parent=B child=C
    # The graph edges are (child, parent) per existing code's DiGraph construction
    edges = [("B", "A"), ("C", "B")]
    dit = compute_dit_from_edges(edges)
    assert dit["A"] == 0
    assert dit["B"] == 1
    assert dit["C"] == 2


def test_compute_dit_from_edges_diamond():
    # Diamond: A→B, A→C, B→D, C→D
    edges = [("B", "A"), ("C", "A"), ("D", "B"), ("D", "C")]
    dit = compute_dit_from_edges(edges)
    assert dit["A"] == 0
    assert dit["B"] == 1
    assert dit["C"] == 1
    assert dit["D"] == 2


def test_compute_dit_matches_old_behavior():
    edges = [("X", "A"), ("Y", "X"), ("Z", "Y")]
    dit = compute_dit_from_edges(edges)
    assert dit["A"] == 0
    assert dit["X"] == 1
    assert dit["Y"] == 2
    assert dit["Z"] == 3


# ── compute_metrics split tests ──────────────────────────────────────────────


def test_fetch_metrics_data_returns_shapes(tmp_path):
    conn = duckdb.connect(str(tmp_path / "test.duckdb"))
    create_schema(conn)
    conn.execute("INSERT INTO calls VALUES ('f1', 'obj_a', 'proc1', 'obj_b', 'ExCall')")
    conn.execute(
        "INSERT INTO procedures VALUES ('f1', 'obj_a', 'function', 'proc1', '', '', 'int', 1, 10, '{\"tag\":\"BsReturn\"}', 'return 1', 1)"
    )
    edges, cyc_rows, inherit_edges = fetch_metrics_data(conn)
    conn.close()
    assert len(edges) >= 1
    assert edges[0] == ("obj_a", "obj_b")
    assert len(cyc_rows) >= 1
    assert isinstance(inherit_edges, list)


def test_compute_metrics_from_data_empty():
    rows = compute_metrics_from_data([], [], [])
    assert rows == []


def test_compute_metrics_from_data_linear():
    # Linear chain: A → B → C
    edges = [("A", "B"), ("B", "C")]
    cyc_rows = [("A", 5, 5.0), ("B", 3, 3.0), ("C", 1, 1.0)]
    rows = compute_metrics_from_data(edges, cyc_rows, [])
    row_map = {r[0]: r for r in rows}
    assert "A" in row_map
    assert "B" in row_map
    assert "C" in row_map
    # A has out_degree 1, B has in_degree 1 out_degree 1, C has in_degree 1
    assert row_map["A"][2] == 1  # out_degree
    assert row_map["B"][1] == 1  # in_degree
    assert row_map["B"][2] == 1  # out_degree
    assert row_map["C"][1] == 1  # in_degree
    # Cyclomatic mapping
    assert row_map["A"][5] == 5  # max_cyclomatic
    assert row_map["B"][6] == 3.0  # avg_cyclomatic


def test_compute_metrics_from_data_empty_graph():
    rows = compute_metrics_from_data([], [("A", 3, 3.0)], [])
    # Empty graph = no nodes, so no rows even though cyc data exists
    assert rows == []


def test_write_metrics_populates_table(tmp_path):
    conn = duckdb.connect(str(tmp_path / "test.duckdb"))
    create_schema(conn)
    conn.execute("""
        CREATE TABLE object_metrics (
            object TEXT, in_degree INT, out_degree INT,
            betweenness DOUBLE, pagerank DOUBLE,
            max_cyclomatic INT, avg_cyclomatic DOUBLE,
            dit INT, cbo INT
        )
    """)
    rows = [
        ("obj_a", 1, 2, 0.5, 0.3, 5, 5.0, 0, None),
        ("obj_b", 3, 0, 0.0, 0.7, None, None, 2, None),
    ]
    write_metrics(conn, rows)
    result = conn.execute("SELECT count(*) FROM object_metrics").fetchone()
    assert result is not None
    count = result[0]
    conn.close()
    assert count == 2
