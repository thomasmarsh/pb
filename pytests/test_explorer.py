"""Tests for pbtools.explorer — API endpoints and render module."""
import os
import subprocess
import tempfile
from pathlib import Path

import duckdb
import pytest

REPO_ROOT   = Path(__file__).parent.parent
OPENPAY_DIR = REPO_ROOT / "example" / "openpay-src"
DB_PATH     = REPO_ROOT / "pb.duckdb"


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def db_path():
    if os.path.exists(DB_PATH):
        return str(DB_PATH)
    tmp = tempfile.mkdtemp()
    db = os.path.join(tmp, "test.duckdb")
    runner = subprocess.run(
        ["cabal", "run", "pb-runner", "-v0", "--", "-i", str(OPENPAY_DIR), "--jsonl"],
        capture_output=True, cwd=str(REPO_ROOT),
    )
    assert runner.returncode == 0, runner.stderr.decode()
    from pbtools.index import run_from_jsonl_lines
    import io
    run_from_jsonl_lines(io.StringIO(runner.stdout.decode()), db)
    from pbtools.analyze import run as analyze
    analyze(db)
    return db


@pytest.fixture(scope="module")
def client(db_path):
    from fastapi.testclient import TestClient
    from pbtools.explorer import create_app
    app = create_app(db_path)
    return TestClient(app)


# ── SPA ───────────────────────────────────────────────────────────────────────

def test_index_returns_html(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "pb explore" in r.text
    assert "<html" in r.text


def test_static_css(client):
    r = client.get("/static/style.css")
    assert r.status_code == 200
    assert "var(--bg-primary)" in r.text


def test_static_js(client):
    r = client.get("/static/index.html")
    assert r.status_code == 200
    assert "pb explore" in r.text


def test_static_core(client):
    r = client.get("/static/style.css")
    assert r.status_code == 200
    assert "var(--bg-primary)" in r.text


# ── Stats ─────────────────────────────────────────────────────────────────────

def test_stats_returns_counts(client):
    r = client.get("/api/stats")
    assert r.status_code == 200
    data = r.json()
    assert data["objects"] > 0
    assert data["procedures"] > 0
    assert "by_kind" in data
    assert "top_complex" in data
    assert "top_pagerank" in data


# ── Objects ───────────────────────────────────────────────────────────────────

def test_list_objects(client):
    r = client.get("/api/objects")
    assert r.status_code == 200
    data = r.json()
    assert data["total"] > 0
    assert len(data["items"]) > 0
    assert "name" in data["items"][0]
    assert "kind" in data["items"][0]


def test_list_objects_filter_kind(client):
    r = client.get("/api/objects", params={"kind": "datawindow"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] > 0
    for item in data["items"]:
        assert item["kind"] == "datawindow"


def test_list_objects_search(client):
    r = client.get("/api/objects", params={"q": "fn_"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] > 0


def test_list_objects_pagination(client):
    r = client.get("/api/objects", params={"limit": 5, "offset": 0})
    assert r.status_code == 200
    data = r.json()
    assert len(data["items"]) <= 5
    assert data["limit"] == 5
    assert data["offset"] == 0


def test_get_object(client):
    r = client.get("/api/objects/fn_sqlerror")
    assert r.status_code == 200
    data = r.json()
    assert data["name"] == "fn_sqlerror"
    assert "procedures" in data
    assert "metrics" in data
    assert "ancestors" in data
    assert "callers" in data
    assert "callees" in data


def test_get_object_not_found(client):
    r = client.get("/api/objects/__nonexistent__")
    assert r.status_code == 404


# ── Procedures ────────────────────────────────────────────────────────────────

def test_get_object_source(client):
    r = client.get("/api/objects/fn_sqlerror/source")
    assert r.status_code == 200
    data = r.json()
    assert "file" in data
    assert "lines" in data
    assert "procedures" in data
    assert isinstance(data["lines"], list)
    assert isinstance(data["procedures"], list)


def test_get_object_source_not_found(client):
    r = client.get("/api/objects/__nonexistent__/source")
    assert r.status_code == 404


def test_get_procedure(client):
    r = client.get("/api/procedures/fn_sqlerror/fn_sqlerror")
    assert r.status_code == 200
    data = r.json()
    assert data["object"] == "fn_sqlerror"
    assert data["name"] == "fn_sqlerror"
    assert "source_rendered" in data


def test_get_procedure_not_found(client):
    r = client.get("/api/procedures/__no_obj__/__no_proc__")
    assert r.status_code == 404


# ── Search ────────────────────────────────────────────────────────────────────

def test_search_returns_results(client):
    r = client.get("/api/search", params={"q": "fn_sqlerror"})
    assert r.status_code == 200
    data = r.json()
    assert len(data["objects"]) > 0 or len(data["procedures"]) > 0


def test_search_case_insensitive(client):
    r1 = client.get("/api/search", params={"q": "fn_sqlerror"})
    r2 = client.get("/api/search", params={"q": "FN_SQLERROR"})
    assert r1.status_code == 200
    assert r2.status_code == 200


# ── DataWindows ───────────────────────────────────────────────────────────────

def test_dw_detail(client):
    r = client.get("/api/objects", params={"kind": "datawindow", "limit": 1})
    data = r.json()
    if not data["items"]:
        pytest.skip("No DataWindows in database")
    dw_name = data["items"][0]["name"]
    r2 = client.get(f"/api/dw/{dw_name}")
    assert r2.status_code == 200
    dw = r2.json()
    assert dw["name"] == dw_name
    assert "controls" in dw
    assert "retrieve_tables" in dw
    assert isinstance(dw["controls"], list)


def test_dw_not_found(client):
    r = client.get("/api/dw/__nonexistent_dw__")
    assert r.status_code == 404


# ── Diagrams ──────────────────────────────────────────────────────────────────

def test_diagram_inheritance(client):
    r = client.get("/api/diagram/inheritance")
    assert r.status_code == 200
    assert "image/svg+xml" in r.headers["content-type"]
    assert "<svg" in r.text


def test_diagram_calls(client):
    r = client.get("/api/diagram/calls", params={"focal": "fn_sqlerror", "depth": 1})
    assert r.status_code == 200
    assert "<svg" in r.text


def test_diagram_heatmap(client):
    r = client.get("/api/diagram/heatmap")
    assert r.status_code == 200
    assert "<svg" in r.text


def test_diagram_dw_tables(client):
    r = client.get("/api/diagram/dw-tables")
    assert r.status_code == 200
    assert "<svg" in r.text


def test_diagram_invalid_kind(client):
    r = client.get("/api/diagram/invalid_kind")
    assert r.status_code == 400


# ── Queries ───────────────────────────────────────────────────────────────────

def test_list_queries(client):
    r = client.get("/api/queries")
    assert r.status_code == 200
    data = r.json()
    assert len(data["queries"]) > 0
    names = [q["name"] for q in data["queries"]]
    assert "top" in names
    assert "callers" in names


def test_run_query_top(client):
    r = client.get("/api/queries/top/run", params={"n": "5"})
    assert r.status_code == 200
    data = r.json()
    assert len(data["rows"]) == 5
    assert len(data["columns"]) > 0


def test_run_query_callers(client):
    r = client.get("/api/queries/callers/run", params={"name": "fn_sqlerror"})
    assert r.status_code == 200
    data = r.json()
    assert len(data["rows"]) > 0


def test_run_query_not_found(client):
    r = client.get("/api/queries/__nonexistent__/run")
    assert r.status_code == 404


# ── Render module ─────────────────────────────────────────────────────────────

def test_render_body_empty():
    from pbtools.explorer.render import render_body
    assert render_body("[]") == ""
    assert render_body([]) == ""


def test_render_body_simple_call():
    from pbtools.explorer.render import render_body
    body = [{"tag": "call", "expr": {"tag": "call_expr", "callee": {"segments": [{"name": "setnull"}]}, "args": [["x"]]} }]
    result = render_body(body)
    assert "setnull" in result


def test_render_body_return():
    from pbtools.explorer.render import render_body
    body = [{"tag": "return", "expr": {"tag": "lvalue", "segments": [{"name": "result"}]}}]
    result = render_body(body)
    assert "return" in result
    assert "result" in result


def test_render_body_if():
    from pbtools.explorer.render import render_body
    body = [{"tag": "if", "cond": {"tag": "lvalue", "segments": [{"name": "x"}]},
             "then": [{"tag": "return", "expr": {"tag": "lvalue", "segments": [{"name": "y"}]}}],
             "elseIfs": [], "else": None}]
    result = render_body(body)
    assert "if x then" in result
    assert "return y" in result
    assert "end if" in result


def test_render_body_exit_continue():
    from pbtools.explorer.render import render_body
    body = [{"tag": "exit"}, {"tag": "continue"}]
    result = render_body(body)
    assert "exit" in result
    assert "continue" in result


def test_render_body_assign():
    from pbtools.explorer.render import render_body
    body = [{"tag": "assign",
             "lhs": {"segments": [{"name": "ls_result"}]},
             "rhs": {"tag": "lvalue", "segments": [{"name": "ls_value"}]}}]
    result = render_body(body)
    assert "ls_result = ls_value" in result


def test_render_body_for():
    from pbtools.explorer.render import render_body
    body = [{"tag": "for",
             "var": {"segments": [{"name": "i"}]},
             "from": {"tag": "lvalue", "segments": [{"name": "1"}]},
             "to": {"tag": "lvalue", "segments": [{"name": "10"}]},
             "step": None,
             "body": [{"tag": "continue"}]}]
    result = render_body(body)
    assert "for i = 1 to 10" in result
    assert "continue" in result
    assert "next" in result
