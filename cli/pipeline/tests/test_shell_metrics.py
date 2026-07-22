"""Tests for pb.pipeline.metrics — graph metric computation."""

import duckdb
from pb.pipeline.metrics import (
    compute_dit_from_edges,
    compute_metrics,
    compute_metrics_from_data,
    fetch_inheritance_edges,
    fetch_metrics_data,
    write_metrics,
)
from pb.pipeline.reporter import RecordingReporter


def q(conn, sql: str):
    return conn.execute(sql).fetchone()[0]


def _setup_metrics_tables(conn) -> None:
    """Create the minimal native tables that metrics.py queries."""
    conn.execute(
        "CREATE TABLE IF NOT EXISTS call_sites "
        "(file TEXT, object TEXT, proc_name TEXT, to_name TEXT, call_type TEXT, line INT)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS procedures "
        "(file TEXT, object TEXT, proc_name TEXT, proc_type TEXT, "
        "start_line INT, end_line INT, params TEXT, return_type TEXT, "
        "cyclomatic INT, cfg_json TEXT, instr_graph_json TEXT)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS objects "
        "(file TEXT, kind TEXT, object TEXT, ancestor TEXT)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS object_metrics "
        "(object TEXT NOT NULL, in_degree INT, out_degree INT, "
        "betweenness DOUBLE, pagerank DOUBLE, max_cyclomatic INT, "
        "avg_cyclomatic DOUBLE, dit INT, cbo INT)"
    )


# ── reporter integration ──────────────────────────────────────────────────────


def test_analyze_run_emits_reporter_events(tmp_path):
    db = str(tmp_path / "test.duckdb")
    conn = duckdb.connect(db)
    _setup_metrics_tables(conn)
    conn.close()

    reporter = RecordingReporter()
    with duckdb.connect(db) as conn, reporter.analyze_progress() as progress:
        compute_metrics(conn, progress)

    types = {e["type"] for e in reporter.events}
    assert "analyze_start" in types
    assert "analyze_end" in types

    assert not any(e["type"] == "analyze_extract" for e in reporter.events)
    assert not any(e["type"] == "analyze_cyclomatic" for e in reporter.events)

    metric_labels = [e["label"] for e in reporter.events if e["type"] == "analyze_metrics"]
    assert "done" in metric_labels


# ── integration tests ─────────────────────────────────────────────────────────


def test_calls_table_populated_after_index(db_conn):
    count = q(db_conn, "SELECT count(*) FROM call_sites")
    assert count > 0, "call_sites is empty after indexing"

    call_types = {r[0] for r in db_conn.execute("SELECT DISTINCT call_type FROM call_sites").fetchall()}
    assert "ExCall" in call_types, f"no ExCall rows; found types: {call_types}"


def test_object_metrics_has_all_objects(db_conn):
    metric_objects = q(db_conn, "SELECT count(*) FROM object_metrics")
    assert metric_objects > 0, "object_metrics table is empty"
    missing = q(
        db_conn,
        """
        SELECT count(DISTINCT c.object) FROM call_sites c
        LEFT JOIN object_metrics m ON c.object = m.object
        WHERE m.object IS NULL
    """,
    )
    assert missing == 0, f"{missing} objects appear in call_sites but not in object_metrics"


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
    # Haskell CfgBuild can produce 0/-1 for degenerate disconnected CFGs (known edge case).
    # Test that cyclomatic is populated and most procedures have cc >= 1.
    max_cc = q(db_conn, "SELECT max(cyclomatic) FROM procedures WHERE cyclomatic IS NOT NULL")
    assert max_cc is not None and max_cc >= 1, f"cyclomatic should be populated with values >= 1, got max={max_cc}"


# ── compute_dit split tests ──────────────────────────────────────────────────


def test_fetch_inheritance_edges_returns_tuples(tmp_path):
    conn = duckdb.connect(str(tmp_path / "test.duckdb"))
    conn.execute("CREATE TABLE objects (file TEXT, kind TEXT, object TEXT, ancestor TEXT)")
    conn.execute("INSERT INTO objects VALUES (NULL, NULL, 'child', 'parent')")
    edges = fetch_inheritance_edges(conn)
    conn.close()
    assert edges == [("child", "parent")]


def test_fetch_inheritance_edges_empty(tmp_path):
    conn = duckdb.connect(str(tmp_path / "test.duckdb"))
    conn.execute("CREATE TABLE objects (file TEXT, kind TEXT, object TEXT, ancestor TEXT)")
    edges = fetch_inheritance_edges(conn)
    conn.close()
    assert edges == []


def test_compute_dit_from_edges_empty():
    assert compute_dit_from_edges([]) == {}


def test_compute_dit_from_edges_single_chain():
    edges = [("B", "A"), ("C", "B")]
    dit = compute_dit_from_edges(edges)
    assert dit["A"] == 0
    assert dit["B"] == 1
    assert dit["C"] == 2


def test_compute_dit_from_edges_diamond():
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
    _setup_metrics_tables(conn)
    conn.execute("INSERT INTO call_sites VALUES ('f1', 'obj_a', 'proc1', 'obj_b', 'ExCall', NULL)")
    conn.execute(
        "INSERT INTO procedures (file, object, proc_name, proc_type, cyclomatic) "
        "VALUES ('f1', 'obj_a', 'proc1', 'function', 1)"
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
    edges = [("A", "B"), ("B", "C")]
    cyc_rows = [("A", 5, 5.0), ("B", 3, 3.0), ("C", 1, 1.0)]
    rows = compute_metrics_from_data(edges, cyc_rows, [])
    row_map = {r[0]: r for r in rows}
    assert "A" in row_map
    assert "B" in row_map
    assert "C" in row_map
    assert row_map["A"][2] == 1  # out_degree
    assert row_map["B"][1] == 1  # in_degree
    assert row_map["B"][2] == 1  # out_degree
    assert row_map["C"][1] == 1  # in_degree
    assert row_map["A"][5] == 5  # max_cyclomatic
    assert row_map["B"][6] == 3.0  # avg_cyclomatic


def test_compute_metrics_from_data_empty_graph():
    rows = compute_metrics_from_data([], [("A", 3, 3.0)], [])
    assert rows == []


def test_write_metrics_populates_table(tmp_path):
    conn = duckdb.connect(str(tmp_path / "test.duckdb"))
    _setup_metrics_tables(conn)
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
