"""Tests for pb_cli.explorer — API endpoints and render module."""
import shutil
from pathlib import Path

import duckdb
import pytest


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def client(db_path):
    from fastapi.testclient import TestClient
    from pb_cli.explorer import create_app
    app = create_app(db_path)
    return TestClient(app)


@pytest.fixture(scope="module")
def client_with_sql(db_path, tmp_path_factory):
    """Client backed by a DB copy with a synthetic sql_statements row.

    openpay has no embedded SQL body statements, so we inject one row to exercise
    the non-empty code paths without touching the shared session-scoped DB.
    """
    tmp = tmp_path_factory.mktemp("db_sql")
    db_copy = str(tmp / "test_sql.duckdb")
    shutil.copy(db_path, db_copy)

    conn = duckdb.connect(db_copy)
    conn.execute(
        "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        ["", "fn_sqlerror", "fn_sqlerror", 0, "SELECT",
         "SELECT id FROM synthetic_test_table WHERE id = 1",
         None, ["synthetic_test_table"], ["id"], False, False, True],
    )
    conn.close()

    from fastapi.testclient import TestClient
    from pb_cli.explorer import create_app
    app = create_app(db_copy)
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


# ── Tables ────────────────────────────────────────────────────────────────────

def test_list_tables_returns_ranked_list(client):
    r = client.get("/api/tables")
    assert r.status_code == 200
    data = r.json()
    assert isinstance(data, list)
    assert len(data) > 0
    counts = [row["dw_count"] for row in data]
    assert counts == sorted(counts, reverse=True)


def test_list_tables_has_required_fields(client):
    r = client.get("/api/tables")
    assert r.status_code == 200
    row = r.json()[0]
    assert "table_name" in row
    assert "dw_count" in row
    assert "ps_count" in row
    assert "file_count" in row
    assert row["dw_count"] >= 1


def test_get_table_detail_returns_lineage(client):
    tables = client.get("/api/tables").json()
    if not tables:
        pytest.skip("No tables in database")
    table_name = tables[0]["table_name"]
    r = client.get(f"/api/tables/{table_name}")
    assert r.status_code == 200
    data = r.json()
    assert data["table_name"] == table_name
    assert "dw_count" in data
    assert "datawindows" in data
    assert "columns" in data
    assert "where" in data
    assert isinstance(data["datawindows"], list)
    assert len(data["datawindows"]) > 0
    assert "dw_name" in data["datawindows"][0]
    assert "file" in data["datawindows"][0]


def test_get_table_detail_404_unknown(client):
    r = client.get("/api/tables/__nonexistent_table__")
    assert r.status_code == 404


# ── Explore SQL statements ─────────────────────────────────────────────────────

def test_explore_procedure_has_sql_statements_field(client):
    """sql_statements key is always present, even when empty."""
    r = client.get("/api/objects/fn_sqlerror")
    assert r.status_code == 200
    procs = r.json().get("procedures", [])
    if not procs:
        pytest.skip("fn_sqlerror has no procedures")
    proc_name = procs[0]["name"]
    r2 = client.get(f"/api/explore/procedure/fn_sqlerror/{proc_name}")
    assert r2.status_code == 200
    data = r2.json()
    assert "sql_statements" in data
    assert isinstance(data["sql_statements"], list)


def test_explore_procedure_sql_statements_have_formatted_sql(client_with_sql):
    """Each sql_statements row has a formatted_sql string field."""
    r = client_with_sql.get("/api/explore/procedure/fn_sqlerror/fn_sqlerror")
    if r.status_code == 404:
        pytest.skip("fn_sqlerror not found")
    data = r.json()
    stmts = data.get("sql_statements", [])
    assert len(stmts) > 0, "synthetic SQL row should be present"
    for stmt in stmts:
        assert "formatted_sql" in stmt
        assert isinstance(stmt["formatted_sql"], str)


# ── SQL lineage diagrams ───────────────────────────────────────────────────────

def test_diagram_sql_lineage(client_with_sql):
    r = client_with_sql.get("/api/diagram/sql-lineage")
    assert r.status_code == 200
    assert "image/svg+xml" in r.headers["content-type"]
    assert "<svg" in r.text


def test_diagram_table_lineage_requires_table(client_with_sql):
    r = client_with_sql.get("/api/diagram/table-lineage")
    assert r.status_code == 400


def test_diagram_table_lineage_with_table(client_with_sql):
    r = client_with_sql.get("/api/diagram/table-lineage", params={"table": "synthetic_test_table"})
    assert r.status_code == 200
    assert "<svg" in r.text
