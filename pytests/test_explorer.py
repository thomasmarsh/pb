"""Tests for pbtools.explorer — API endpoints and render module."""
import os
import subprocess
import tempfile
from pathlib import Path

import duckdb
import pytest

REPO_ROOT   = Path(__file__).parent.parent
OPENPAY_DIR = REPO_ROOT / "example" / "openpay-src"


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def db_path():
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
    yield db
    os.unlink(db)
    os.rmdir(tmp)


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


# ── Explore tree ──────────────────────────────────────────────────────────────

def test_explore_tree(client):
    r = client.get("/api/explore/tree")
    assert r.status_code == 200
    data = r.json()
    assert "libraries" in data
    assert isinstance(data["libraries"], list)
    assert len(data["libraries"]) > 0
    lib = data["libraries"][0]
    assert "name" in lib
    assert "objects" in lib
    assert isinstance(lib["objects"], list)
    if lib["objects"]:
        obj = lib["objects"][0]
        assert "name" in obj
        assert "kind" in obj
        assert "procedures" in obj
        assert isinstance(obj["procedures"], list)


def test_explore_procedure(client):
    r = client.get("/api/objects")
    objs = r.json()["items"]
    if not objs:
        pytest.skip("No objects in database")
    obj_name = objs[0]["name"]
    r2 = client.get(f"/api/objects/{obj_name}")
    procs = r2.json().get("procedures", [])
    if not procs:
        pytest.skip("No procedures in database")
    proc_name = procs[0]["name"]
    r3 = client.get(f"/api/explore/procedure/{obj_name}/{proc_name}")
    assert r3.status_code == 200
    data = r3.json()
    assert "ast" in data


def test_explore_procedure_not_found(client):
    r = client.get("/api/explore/procedure/__no_obj__/__no_proc__")
    assert r.status_code == 404


# ── Render module ─────────────────────────────────────────────────────────────

def test_render_body_empty():
    from pbtools.explorer.render import render_body
    assert render_body("[]") == ""
    assert render_body([]) == ""


def test_render_body_empty_passthrough():
    # Sanity: empty body always works regardless of format
    from pbtools.explorer.render import render_body
    assert render_body("[]") == ""
    assert render_body([]) == ""


# ── render tests: new JSON format (genericToJSON / aeson-typescript) ──────────
# These use the actual tag names and "contents" structure emitted by pb-runner
# after the 6fa3e1a serialise rewrite.  Each test must FAIL before render.py
# is updated and PASS after.

_lv = lambda *names: {"segments": [{"name": n, "subscript": None} for n in names]}
_exlv = lambda *names: {"tag": "ExLvalue", "contents": _lv(*names)}
_exint = lambda n: {"tag": "ExInt", "contents": str(n)}
_excall = lambda fn, *args: {
    "tag": "ExCall",
    "callee": _lv(fn),
    "args": list(args),
}


def test_render_new_bs_call():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsCall", "contents": _excall("setnull", ["x"])}]
    result = render_body(body)
    assert "setnull" in result, f"BsCall not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_bs_return_with_expr():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsReturn", "contents": {"tag": "ExBool", "contents": True}}]
    result = render_body(body)
    assert "return" in result, f"BsReturn not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_bs_assign():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsAssign", "contents": [_lv("ls_result"), _exlv("ls_value")]}]
    result = render_body(body)
    assert "ls_result" in result and "ls_value" in result, f"BsAssign not rendered; got: {result!r}"
    assert "=" in result
    assert "/* unknown" not in result


def test_render_new_bs_local_var():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsLocalVar", "contents": ["string", "ls_name"]}]
    result = render_body(body)
    assert "string" in result and "ls_name" in result, f"BsLocalVar not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_bs_if():
    from pbtools.explorer.render import render_body
    body = [{
        "tag": "BsIf",
        "contents": {
            "cond": {"tag": "ExBool", "contents": True},
            "then": [{"tag": "BsReturn", "contents": _exint(1)}],
            "elseIfs": [],
            "else": None,
        },
    }]
    result = render_body(body)
    assert "if" in result and "end if" in result, f"BsIf not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_bs_for():
    from pbtools.explorer.render import render_body
    body = [{
        "tag": "BsFor",
        "contents": {
            "var": _lv("i"),
            "from": _exint(1),
            "to": _exint(10),
            "step": None,
            "body": [{"tag": "BsContinue"}],
        },
    }]
    result = render_body(body)
    assert "for" in result and "next" in result, f"BsFor not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_bs_exit_continue():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsExit"}, {"tag": "BsContinue"}]
    result = render_body(body)
    assert "exit" in result and "continue" in result, f"BsExit/Continue not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_bs_destroy():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsDestroy", "contents": _lv("lds_obj")}]
    result = render_body(body)
    assert "destroy" in result and "lds_obj" in result, f"BsDestroy not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_bs_raw():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsRaw", "contents": "FETCH cur_x INTO :ll_id;"}]
    result = render_body(body)
    assert "FETCH" in result, f"BsRaw not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_ex_call_callee_name():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsCall", "contents": _excall("MessageBox", ["'Info'"], ["'Hello'"])}]
    result = render_body(body)
    assert "MessageBox" in result, f"ExCall callee name not rendered; got: {result!r}"


def test_render_new_ex_lvalue_dotted():
    from pbtools.explorer.render import render_body
    body = [{"tag": "BsAssign", "contents": [_lv("dw_1", "object"), _exlv("dw_2", "object")]}]
    result = render_body(body)
    assert "dw_1.object" in result, f"dotted lvalue not rendered; got: {result!r}"


def test_render_new_ex_binop():
    from pbtools.explorer.render import render_body
    binop = {
        "tag": "ExBinOp",
        "lhs": _exlv("x"),
        "op": "BopEq",
        "rhs": _exint(0),
    }
    body = [{"tag": "BsReturn", "contents": binop}]
    result = render_body(body)
    assert "x" in result and "0" in result, f"ExBinOp not rendered; got: {result!r}"
    assert "/* unknown" not in result


def test_render_new_ex_method_call():
    from pbtools.explorer.render import render_body
    method_expr = {
        "tag": "ExMethodCall",
        "receiver": _excall("getparent"),
        "method": "Reset",
        "args": [],
    }
    body = [{"tag": "BsCall", "contents": method_expr}]
    result = render_body(body)
    assert "Reset" in result, f"ExMethodCall not rendered; got: {result!r}"
    assert "/* unknown" not in result
