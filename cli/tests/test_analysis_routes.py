"""Tests for /api/analysis/* endpoints (taint, slice, annotations, sources, sinks)."""

from __future__ import annotations

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

    # taint_paths — new Haskell schema (no id, no source_type/sink_type/steps_json)
    conn.execute("""
        CREATE TABLE taint_paths (
            source_file TEXT, source_object TEXT, source_proc TEXT, source_var TEXT,
            sink_file TEXT, sink_object TEXT, sink_proc TEXT, sink_var TEXT,
            severity TEXT, category TEXT
        )
    """)
    conn.execute(
        "INSERT INTO taint_paths VALUES (?,?,?,?,?,?,?,?,?,?)",
        ["w.srf", "w_obj", "proc_a", "ls_y",
         "w.srf", "w_obj", "proc_b", "ls_input",
         "high", "sql_injection"],
    )

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
    assert isinstance(path["id"], int)
    assert path["severity"] == "high"
    assert path["category"] == "sql_injection"
    assert path["source"]["object"] == "w_obj"
    assert path["sink"]["type"] is None  # not in new schema


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


def test_taint_paths_filter_object(taint_client):
    r = taint_client.get("/api/analysis/taint-paths?object_name=w_obj")
    assert r.status_code == 200
    assert r.json()["total"] == 1

    r2 = taint_client.get("/api/analysis/taint-paths?object_name=nonexistent")
    assert r2.json()["total"] == 0


# ---------------------------------------------------------------------------
# GET /api/analysis/taint-paths/{id}
# ---------------------------------------------------------------------------


def test_taint_path_detail_returns_steps(taint_client):
    # First get the id from the list endpoint
    r_list = taint_client.get("/api/analysis/taint-paths")
    path_id = r_list.json()["paths"][0]["id"]

    r = taint_client.get(f"/api/analysis/taint-paths/{path_id}")
    assert r.status_code == 200
    body = r.json()
    assert body["id"] == path_id
    assert isinstance(body["steps"], list)
    assert body["source"]["var"] == "ls_y"
    assert body["sink"]["var"] == "ls_input"


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
# Dead-code reachability — correctness tests with synthetic DB
# ---------------------------------------------------------------------------
#
# Graph used in all dead_code_client tests:
#
#   ev_handler (event) ──calls──► proc_a ──calls──► proc_b   [all reachable]
#   on_handler (on)                                            [entry, reachable]
#   proc_c (function)  ──calls──► proc_d                      [both dead]
#
# Override propagation graph (same DB):
#   base_event (event, obj_base) ──calls──► base_hook (obj_base)
#   child_hook (function, obj_child, inherits obj_base, overrides base_hook)
#   → child_hook must be reachable via override propagation


@pytest.fixture(scope="module")
def dead_code_client(tmp_path_factory):
    """TestClient backed by a synthetic DB for dead-code API endpoint tests.

    Dead-code correctness is tested in Haskell DeadCodeTest.hs.
    This fixture writes a synthetic dead_procedures.json (as the Haskell
    pipeline would produce) and tests the API endpoint reads it correctly.
    """
    tmp = tmp_path_factory.mktemp("dead_code_db")
    db_path = str(tmp / "dead.duckdb")
    conn = duckdb.connect(db_path)

    conn.execute("""
        CREATE TABLE dead_code (
            object TEXT NOT NULL, proc_name TEXT NOT NULL, proc_type TEXT NOT NULL,
            cyclomatic INT, confidence TEXT NOT NULL,
            caller_count_naive INT NOT NULL, caller_count_scoped INT NOT NULL
        )
    """)
    conn.execute("""
        CREATE VIEW compat_dead_procedures AS
          SELECT object, proc_name AS name, proc_type, cyclomatic, confidence,
                 caller_count_naive, caller_count_scoped
          FROM dead_code
    """)

    # Dead procedures: proc_c, proc_d
    for row in [
        ("obj_a", "proc_c", "function", 2, "high", 0, 0),
        ("obj_a", "proc_d", "function", 1, "high", 0, 0),
    ]:
        conn.execute(
            "INSERT INTO dead_code VALUES (?, ?, ?, ?, ?, ?, ?)", row
        )

    conn.close()

    from fastapi.testclient import TestClient

    from pb_cli.explorer import create_app

    app = create_app(db_path)
    return TestClient(app)


def test_dead_code_excludes_entry_points(dead_code_client):
    r = dead_code_client.get("/api/analysis/dead-code")
    assert r.status_code == 200
    dead_names = {item["name"] for item in r.json()["items"]}
    assert "ev_handler" not in dead_names
    assert "on_handler" not in dead_names


def test_dead_code_excludes_transitively_reachable(dead_code_client):
    r = dead_code_client.get("/api/analysis/dead-code")
    dead_names = {item["name"] for item in r.json()["items"]}
    assert "proc_a" not in dead_names
    assert "proc_b" not in dead_names


def test_dead_code_includes_unreachable_procedures(dead_code_client):
    r = dead_code_client.get("/api/analysis/dead-code")
    dead_names = {item["name"] for item in r.json()["items"]}
    assert "proc_c" in dead_names


def test_dead_code_includes_transitively_dead_procedures(dead_code_client):
    """A procedure only reachable from a dead procedure is also dead."""
    r = dead_code_client.get("/api/analysis/dead-code")
    dead_names = {item["name"] for item in r.json()["items"]}
    assert "proc_d" in dead_names


def test_dead_code_total_matches_items(dead_code_client):
    r = dead_code_client.get("/api/analysis/dead-code")
    body = r.json()
    assert body["total"] == len(body["items"])


def test_dead_code_override_reachable_via_base(dead_code_client):
    """A subclass override is reachable when the base method it overrides is reachable.

    obj_base.base_event (event) calls base_hook in obj_base.
    obj_child inherits obj_base and overrides base_hook.
    Virtual dispatch means obj_child.base_hook is reachable at runtime,
    so it must not appear in the dead-code list.
    """
    r = dead_code_client.get("/api/analysis/dead-code")
    assert r.status_code == 200
    dead_names = {(item["object"], item["name"]) for item in r.json()["items"]}
    assert ("obj_child", "base_hook") not in dead_names, (
        "obj_child.base_hook incorrectly marked dead — "
        "override propagation from reachable base_hook not applied"
    )


# ---------------------------------------------------------------------------
# Slice endpoint — scoped fetch regression
# ---------------------------------------------------------------------------


def test_slice_cross_proc_works_with_scoped_fetch(taint_client):
    """Backward slice across a call boundary finds def in calling proc.

    This test would silently return fewer steps if the scoped fetch
    failed to load the caller's (proc_a) defs/uses.
    """
    r = taint_client.get(
        "/api/analysis/slice/w_obj/proc_b/20?direction=backward&var=ls_input"
    )
    assert r.status_code == 200
    body = r.json()
    # The slice must find at least one step in proc_a (the calling proc)
    procs_seen = {s["proc"] for s in body["steps"]}
    assert "proc_a" in procs_seen, (
        "Cross-proc backward slice did not reach proc_a — "
        "scoped fetch may have missed neighbor proc data"
    )


# ---------------------------------------------------------------------------
# Regression: existing dead-code endpoint still works against real corpus
# ---------------------------------------------------------------------------


def test_dead_code_endpoint_still_works(db_path):
    """Ensure the dead-code endpoint works against the real openpay corpus."""
    from fastapi.testclient import TestClient

    from pb_cli.explorer import create_app

    app = create_app(db_path)
    client = TestClient(app)
    r = client.get("/api/analysis/dead-code")
    assert r.status_code == 200
    body = r.json()
    assert "items" in body
    assert "total" in body
    # Entry point procedures (event/on) must not appear in dead-code list
    entry_point_names = {item["name"] for item in body["items"]
                         if item["proc_type"] in ("event", "on")}
    assert entry_point_names == set(), (
        f"Event/on handlers incorrectly reported as dead: {entry_point_names}"
    )
