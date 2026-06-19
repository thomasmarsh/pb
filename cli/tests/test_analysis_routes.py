"""Tests for /api/analysis/* endpoints (taint, slice, annotations, sources, sinks)."""

from __future__ import annotations

import json

import duckdb
import pytest


# ---------------------------------------------------------------------------
# Synthetic DB fixture
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def taint_client(tmp_path_factory):
    """TestClient backed by a synthetic DB with all taint/slice tables populated."""
    tmp = tmp_path_factory.mktemp("taint_db")
    db_path = str(tmp / "taint.duckdb")
    conn = duckdb.connect(db_path)

    # proc_defs / proc_uses
    conn.execute("""
        CREATE TABLE proc_defs (
            file TEXT, object TEXT, proc_name TEXT, var_name TEXT,
            block_id TEXT, stmt_index INT, line INT, kind TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE proc_uses (
            file TEXT, object TEXT, proc_name TEXT, var_name TEXT,
            block_id TEXT, stmt_index INT, line INT, kind TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE interproc_edges (
            caller_object TEXT, caller_proc TEXT, caller_line INT,
            callee_object TEXT, callee_proc TEXT,
            edge_kind TEXT, var_name TEXT,
            caller_context TEXT, callee_context TEXT
        )
    """)

    # proc_a: ls_y defined at line 5; ls_x defined at line 10 (using ls_y)
    conn.execute("INSERT INTO proc_defs VALUES (?,?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_a", "ls_y", "b0", 0, 5, "local_var"])
    conn.execute("INSERT INTO proc_defs VALUES (?,?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_a", "ls_x", "b0", 1, 10, "assign"])
    conn.execute("INSERT INTO proc_uses VALUES (?,?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_a", "ls_y", "b0", 0, 10, "rhs"])

    # proc_b: ls_input defined at line 1 (parameter); used at line 20
    conn.execute("INSERT INTO proc_defs VALUES (?,?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_b", "ls_input", "b0", 0, 1, "local_var"])
    conn.execute("INSERT INTO proc_uses VALUES (?,?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_b", "ls_input", "b0", 0, 20, "rhs"])

    # arg edge: proc_a passes ls_x at line 15 → proc_b receives as ls_input
    conn.execute("INSERT INTO interproc_edges VALUES (?,?,?,?,?,?,?,?,?)",
                 ["w_obj", "proc_a", 15, "w_obj", "proc_b",
                  "arg", "ls_x", "ls_x", "ls_input"])

    # taint_sources
    conn.execute("""
        CREATE TABLE taint_sources (
            file TEXT, object TEXT, proc_name TEXT, var_name TEXT,
            line INT, source_type TEXT
        )
    """)
    conn.execute("INSERT INTO taint_sources VALUES (?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_a", "ls_y", 5, "db_read"])

    # taint_sinks
    conn.execute("""
        CREATE TABLE taint_sinks (
            file TEXT, object TEXT, proc_name TEXT, var_name TEXT,
            line INT, sink_type TEXT, severity TEXT
        )
    """)
    conn.execute("INSERT INTO taint_sinks VALUES (?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_b", "ls_input", 20, "db_write", "high"])

    # taint_paths
    steps = json.dumps([
        {"object": "w_obj", "proc_name": "proc_a", "line": 5,
         "var_name": "ls_y", "step_kind": "source", "description": "taint source: db_read"},
        {"object": "w_obj", "proc_name": "proc_b", "line": 20,
         "var_name": "ls_input", "step_kind": "sink", "description": "taint sink: db_write"},
    ])
    conn.execute("""
        CREATE TABLE taint_paths (
            id INT, source_object TEXT, source_proc TEXT, source_var TEXT, source_line INT, source_type TEXT,
            sink_object TEXT, sink_proc TEXT, sink_var TEXT, sink_line INT, sink_type TEXT,
            severity TEXT, category TEXT, steps_json TEXT
        )
    """)
    conn.execute("INSERT INTO taint_paths VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                 [1, "w_obj", "proc_a", "ls_y", 5, "db_read",
                  "w_obj", "proc_b", "ls_input", 20, "db_write",
                  "high", "sql_injection", steps])

    # taint_annotations
    conn.execute("""
        CREATE TABLE taint_annotations (
            file TEXT, object TEXT, proc_name TEXT, block_id TEXT,
            is_taint_entry BOOLEAN, is_taint_sink BOOLEAN, tainted_vars TEXT
        )
    """)
    conn.execute("INSERT INTO taint_annotations VALUES (?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_a", "b0", True, False, '["ls_y"]'])
    conn.execute("INSERT INTO taint_annotations VALUES (?,?,?,?,?,?,?)",
                 ["w.srf", "w_obj", "proc_b", "b0", False, True, '["ls_input"]'])

    conn.close()

    from fastapi.testclient import TestClient
    from pb_cli.explorer import create_app

    app = create_app(db_path)
    return TestClient(app)


# ---------------------------------------------------------------------------
# GET /api/analysis/taint-paths
# ---------------------------------------------------------------------------


def test_taint_paths_returns_all(taint_client):
    r = taint_client.get("/api/analysis/taint-paths")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 1
    assert len(body["paths"]) == 1
    path = body["paths"][0]
    assert path["id"] == 1
    assert path["severity"] == "high"
    assert path["category"] == "sql_injection"
    assert path["source"]["object"] == "w_obj"
    assert path["sink"]["type"] == "db_write"


def test_taint_paths_filter_severity(taint_client):
    r = taint_client.get("/api/analysis/taint-paths?severity=high")
    assert r.status_code == 200
    assert r.json()["total"] == 1

    r2 = taint_client.get("/api/analysis/taint-paths?severity=critical")
    assert r2.status_code == 200
    assert r2.json()["total"] == 0


def test_taint_paths_filter_category(taint_client):
    r = taint_client.get("/api/analysis/taint-paths?category=sql_injection")
    assert r.status_code == 200
    assert r.json()["total"] == 1


def test_taint_paths_filter_source_type(taint_client):
    r = taint_client.get("/api/analysis/taint-paths?source_type=db_read")
    assert r.status_code == 200
    assert r.json()["total"] == 1

    r2 = taint_client.get("/api/analysis/taint-paths?source_type=request_param")
    assert r2.json()["total"] == 0


# ---------------------------------------------------------------------------
# GET /api/analysis/taint-paths/{id}
# ---------------------------------------------------------------------------


def test_taint_path_detail_returns_steps(taint_client):
    r = taint_client.get("/api/analysis/taint-paths/1")
    assert r.status_code == 200
    body = r.json()
    assert body["id"] == 1
    assert isinstance(body["steps"], list)
    assert len(body["steps"]) == 2
    assert body["steps"][0]["step_kind"] == "source"
    assert body["steps"][-1]["step_kind"] == "sink"


def test_taint_path_detail_404(taint_client):
    r = taint_client.get("/api/analysis/taint-paths/9999")
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# GET /api/analysis/taint-annotations/{object}/{proc}
# ---------------------------------------------------------------------------


def test_taint_annotations_returns_parsed_vars(taint_client):
    r = taint_client.get("/api/analysis/taint-annotations/w_obj/proc_a")
    assert r.status_code == 200
    body = r.json()
    assert "annotations" in body
    ann = body["annotations"]
    assert len(ann) == 1
    assert ann[0]["blockId"] == "b0"
    assert ann[0]["isTaintEntry"] is True
    assert ann[0]["isTaintSink"] is False
    assert ann[0]["taintedVars"] == ["ls_y"]


def test_taint_annotations_sink_block(taint_client):
    r = taint_client.get("/api/analysis/taint-annotations/w_obj/proc_b")
    assert r.status_code == 200
    ann = r.json()["annotations"]
    assert ann[0]["isTaintSink"] is True
    assert "ls_input" in ann[0]["taintedVars"]


def test_taint_annotations_404_for_unknown(taint_client):
    r = taint_client.get("/api/analysis/taint-annotations/no_obj/no_proc")
    assert r.status_code == 404


# ---------------------------------------------------------------------------
# GET /api/analysis/sources
# ---------------------------------------------------------------------------


def test_sources_returns_all(taint_client):
    r = taint_client.get("/api/analysis/sources")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 1
    assert body["sources"][0]["source_type"] == "db_read"


def test_sources_filter_type(taint_client):
    r = taint_client.get("/api/analysis/sources?source_type=db_read")
    assert r.status_code == 200
    assert r.json()["total"] == 1

    r2 = taint_client.get("/api/analysis/sources?source_type=request_param")
    assert r2.json()["total"] == 0


# ---------------------------------------------------------------------------
# GET /api/analysis/sinks
# ---------------------------------------------------------------------------


def test_sinks_returns_all(taint_client):
    r = taint_client.get("/api/analysis/sinks")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 1
    assert body["sinks"][0]["sink_type"] == "db_write"


def test_sinks_filter_severity(taint_client):
    r = taint_client.get("/api/analysis/sinks?severity=high")
    assert r.status_code == 200
    assert r.json()["total"] == 1

    r2 = taint_client.get("/api/analysis/sinks?severity=critical")
    assert r2.json()["total"] == 0


# ---------------------------------------------------------------------------
# GET /api/analysis/slice/{object}/{proc}/{line}
# ---------------------------------------------------------------------------


def test_slice_backward_returns_definition(taint_client):
    """Backward from ls_input at line 20 in proc_b: finds definition chain."""
    r = taint_client.get(
        "/api/analysis/slice/w_obj/proc_b/20?direction=backward&var=ls_input"
    )
    assert r.status_code == 200
    body = r.json()
    assert body["direction"] == "backward"
    assert body["origin"]["var"] == "ls_input"
    assert isinstance(body["steps"], list)
    kinds = [s["kind"] for s in body["steps"]]
    assert "definition" in kinds or "arg_pass" in kinds


def test_slice_forward_returns_use(taint_client):
    """Forward from ls_y at line 5 in proc_a: finds downstream uses."""
    r = taint_client.get(
        "/api/analysis/slice/w_obj/proc_a/5?direction=forward&var=ls_y"
    )
    assert r.status_code == 200
    body = r.json()
    assert body["direction"] == "forward"
    assert body["origin"]["var"] == "ls_y"
    kinds = [s["kind"] for s in body["steps"]]
    assert "use" in kinds


def test_slice_default_direction_is_backward(taint_client):
    r = taint_client.get("/api/analysis/slice/w_obj/proc_a/10?var=ls_x")
    assert r.status_code == 200
    assert r.json()["direction"] == "backward"


def test_slice_auto_detect_var(taint_client):
    """No var param: auto-detect from the line's definitions."""
    r = taint_client.get("/api/analysis/slice/w_obj/proc_a/10")
    assert r.status_code == 200
    body = r.json()
    assert body["origin"]["var"] != ""


def test_slice_unknown_proc_returns_empty(taint_client):
    r = taint_client.get("/api/analysis/slice/no_obj/no_proc/1?var=x")
    assert r.status_code == 200
    body = r.json()
    assert body["steps"] == []


def test_slice_invalid_direction(taint_client):
    r = taint_client.get("/api/analysis/slice/w_obj/proc_a/10?direction=sideways")
    assert r.status_code == 422


# ---------------------------------------------------------------------------
# Regression: existing dead-code endpoint still works
# ---------------------------------------------------------------------------


def test_dead_code_endpoint_still_works(db_path):
    """Ensure the existing dead-code endpoint wasn't broken by the new endpoints."""
    from fastapi.testclient import TestClient
    from pb_cli.explorer import create_app

    app = create_app(db_path)
    client = TestClient(app)
    r = client.get("/api/analysis/dead-code")
    assert r.status_code == 200
    body = r.json()
    assert "items" in body
    assert "total" in body
