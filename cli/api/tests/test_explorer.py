"""Tests for pb.api — API endpoints and render module."""

import shutil

import duckdb
import pytest

# ── Fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture(scope="module")
def client(db_path):
    from fastapi.testclient import TestClient
    from pb.api import create_app

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
    # sql_statements schema: file, object, proc_name, line, operation, tables, columns, raw_sql, parse_ok, error
    conn.execute(
        "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?)",
        ["", "fn_sqlerror", "fn_sqlerror", 0, "SELECT",
         "synthetic_test_table", "id",
         "SELECT id FROM synthetic_test_table WHERE id = 1", True, None],
    )
    # sql_statement_tables (Plan 157 Phase 4.5): all_sql_tables is now a VIEW
    # over this table (and dw_retrieve_tables) instead of CSV-splitting
    # sql_statements.tables -- the synthetic row above alone no longer
    # surfaces through /api/tables without this.
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sql_statement_tables (
            file TEXT, object TEXT, proc_name TEXT, line INTEGER,
            operation TEXT, namespace TEXT, table_name TEXT
        )
    """)
    conn.execute(
        "INSERT INTO sql_statement_tables (file, object, proc_name, line, operation, namespace, table_name) "
        "VALUES (?,?,?,?,?,?,?)",
        ["", "fn_sqlerror", "fn_sqlerror", 0, "SELECT", None, "synthetic_test_table"],
    )
    # sql_statement_columns (Plan 157 Phase 4.5): column_lineage's PS side now
    # reads per-column namespace/is_write from here (joined back to
    # sql_statements for the operation text) instead of CSV-splitting
    # sql_statements.columns/tables.
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sql_statement_columns (
            file TEXT, object TEXT, proc_name TEXT, line INTEGER,
            namespace TEXT, table_name TEXT, column_name TEXT, is_write BOOLEAN
        )
    """)
    conn.execute(
        "INSERT INTO sql_statement_columns "
        "(file, object, proc_name, line, namespace, table_name, column_name, is_write) "
        "VALUES (?,?,?,?,?,?,?,?)",
        ["", "fn_sqlerror", "fn_sqlerror", 0, None, "synthetic_test_table", "id", False],
    )
    # Column order must match PB.Pipeline.DuckDb's real schema
    # (file, object, namespace, table_name, column_name) — a hardcoded
    # positional INSERT with a different order previously landed values in
    # the wrong columns whenever db_path's real pbc run had already created
    # this table (making CREATE TABLE IF NOT EXISTS a silent no-op).
    conn.execute("""
        CREATE TABLE IF NOT EXISTS dw_retrieve_columns (
            file TEXT, object TEXT, namespace TEXT, table_name TEXT, column_name TEXT
        )
    """)
    conn.execute(
        "INSERT INTO dw_retrieve_columns (file, object, namespace, table_name, column_name) "
        "VALUES (?,?,?,?,?)",
        ["", "dw_synth", None, "synthetic_test_table", "id"],
    )
    # objects schema: file, kind, object, ancestor, layout_json, type_blocks_json, confidence, category
    # Add a child object that inherits from fn_sqlerror for impact-lineage tests.
    conn.execute(
        "INSERT INTO objects VALUES (?,?,?,?,?,?,?,?)",
        ["", "powerscript", "synthetic_child_obj", "fn_sqlerror", None, None, "confirmed", "userobject"],
    )
    conn.close()

    from fastapi.testclient import TestClient
    from pb.api import create_app

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


def test_list_objects_filter_category(client):
    r = client.get("/api/objects", params={"category": "function"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] > 0
    for item in data["items"]:
        assert item["category"] == "function"


def test_list_objects_filter_category_structure(client):
    """Standalone `.srs` structures get `objects.category='structure'` directly
    (Phase 3a) -- the Structure tab reuses the plain category filter, no join."""
    r = client.get("/api/objects", params={"category": "structure"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] > 0
    for item in data["items"]:
        assert item["category"] == "structure"
        assert item["file"].endswith(".srs")


def test_list_objects_filter_category_system_includes_stdlib(client):
    r = client.get("/api/objects", params={"category": "system"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] > 0
    for item in data["items"]:
        assert item["category"] == "system"
        assert item["file"].startswith("__stdlib__/")


def test_list_objects_default_excludes_stdlib(client):
    r = client.get("/api/objects")
    assert r.status_code == 200
    data = r.json()
    for item in data["items"]:
        assert not item["file"].startswith("__stdlib__/")


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
    assert "source_original" in data


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
    r2 = client.get(f"/api/datawindow/{dw_name}")
    assert r2.status_code == 200
    dw = r2.json()
    assert dw["name"] == dw_name
    assert "controls" in dw
    assert "retrieve_tables" in dw
    assert isinstance(dw["controls"], list)


def test_dw_not_found(client):
    r = client.get("/api/datawindow/__nonexistent_dw__")
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


def test_diagram_dw_tables_dw_filter(client):
    r = client.get("/api/diagram/dw-tables", params={"dw": "nonexistent_dw"})
    assert r.status_code == 200
    assert "image/svg+xml" in r.headers["content-type"]


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
    assert "source_original" in data
    assert "sql_statements" in data


def test_explore_procedure_not_found(client):
    r = client.get("/api/explore/procedure/__no_obj__/__no_proc__")
    assert r.status_code == 404


# ── Tables ────────────────────────────────────────────────────────────────────


def test_list_tables_returns_ranked_list(client_with_sql):
    r = client_with_sql.get("/api/tables")
    assert r.status_code == 200
    data = r.json()
    assert isinstance(data, list)
    assert len(data) > 0
    counts = [row["dw_count"] + row["ps_count"] for row in data]
    assert counts == sorted(counts, reverse=True)


def test_list_tables_has_required_fields(client_with_sql):
    r = client_with_sql.get("/api/tables")
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) > 0
    row = rows[0]
    assert "table_name" in row
    assert "dw_count" in row
    assert "ps_count" in row
    assert "file_count" in row
    # The injected synthetic row must appear somewhere with ps_count >= 1
    by_name = {r["table_name"]: r for r in rows}
    assert "synthetic_test_table" in by_name
    assert by_name["synthetic_test_table"]["ps_count"] >= 1


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
    assert "object" in data["datawindows"][0]
    assert "file" in data["datawindows"][0]


def test_get_table_detail_404_unknown(client):
    r = client.get("/api/tables/__nonexistent_table__")
    assert r.status_code == 404



def test_table_detail_columns_detail_dw_and_ps(client_with_sql):
    r = client_with_sql.get("/api/tables/synthetic_test_table")
    assert r.status_code == 200
    data = r.json()
    by_col = {c["column"]: c for c in data["columns_detail"]}
    assert "id" in by_col
    col = by_col["id"]
    assert col["dw_readers"] == ["dw_synth"]
    assert len(col["ps_readers"]) == 1
    assert col["ps_readers"][0]["operation"] == "SELECT"
    assert col["ps_writers"] == []
    assert col["read_count"] == 2
    assert col["write_count"] == 0


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


# ── Impact tab + proc-tables diagram ───────────────────────────────────────────


def test_table_detail_impact(client_with_sql):
    r = client_with_sql.get("/api/tables/synthetic_test_table")
    assert r.status_code == 200
    data = r.json()
    assert "impact" in data
    impact = data["impact"]
    assert {"direct", "inherited"} == set(impact)

    direct_objects = {row["object"] for row in impact["direct"]}
    assert "fn_sqlerror" in direct_objects

    inherited_by_descendant = {row["descendant"]: row for row in impact["inherited"]}
    assert "synthetic_child_obj" in inherited_by_descendant
    child_row = inherited_by_descendant["synthetic_child_obj"]
    assert child_row["ancestor"] == "fn_sqlerror"
    assert child_row["depth"] == 1


def test_diagram_proc_tables(client_with_sql):
    r = client_with_sql.get("/api/diagram/proc-tables")
    assert r.status_code == 200
    assert "image/svg+xml" in r.headers["content-type"]
    assert "<svg" in r.text


def test_diagram_proc_tables_filtered(client_with_sql):
    r = client_with_sql.get("/api/diagram/proc-tables", params={"table": "synthetic_test_table"})
    assert r.status_code == 200
    assert "<svg" in r.text


# ── /api/diagnostics ─────────────────────────────────────────────────────────


@pytest.fixture(scope="module")
def client_with_errors(db_path, tmp_path_factory):
    """Client backed by a DB copy with synthetic parse_errors rows."""
    tmp = tmp_path_factory.mktemp("db_errors_route")
    db_copy = str(tmp / "test_errors.duckdb")
    shutil.copy(db_path, db_copy)

    conn = duckdb.connect(db_copy)
    # Clear existing SQL parse errors so the fixture sees only the two synthetic rows
    conn.execute("UPDATE sql_statements SET parse_ok = true WHERE NOT parse_ok")
    # parse_errors schema: file TEXT, error TEXT, line INTEGER
    conn.execute(
        "INSERT INTO parse_errors VALUES (?,?,?)",
        ["a.srw", "lex error at line 3", 3],
    )
    conn.execute(
        "INSERT INTO parse_errors VALUES (?,?,?)",
        ["b.srw", "Invalid expression: SELECT * FROM (", None],
    )
    conn.close()

    from fastapi.testclient import TestClient
    from pb.api import create_app

    app = create_app(db_copy)
    return TestClient(app)


def test_list_diagnostics(client_with_errors):
    r = client_with_errors.get("/api/diagnostics")
    assert r.status_code == 200
    data = r.json()
    assert data["total"] == 2
    assert len(data["items"]) == 2
    files = {item["file"] for item in data["items"]}
    assert files == {"a.srw", "b.srw"}


def test_list_diagnostics_filter_by_message(client_with_errors):
    r = client_with_errors.get("/api/diagnostics", params={"q": "Invalid"})
    assert r.status_code == 200
    data = r.json()
    assert data["total"] == 1
    assert data["items"][0]["file"] == "b.srw"


# ── SQL execute endpoint ───────────────────────────────────────────────────────


def test_sql_execute_translates_question_mark_to_percent_s(client, monkeypatch):
    """? placeholders must become %s before reaching mysql-connector-python.

    mysql-connector-python raises "Not all parameters were used" if it receives
    ? markers — it only understands %s.  This test mocks the connector to
    assert the translation happens server-side, independent of a live DB.
    """
    import unittest.mock as mock

    captured: dict = {}

    mock_cursor = mock.MagicMock()
    mock_cursor.description = [("kodkrat",), ("desckrat",)]
    mock_cursor.fetchall.return_value = [{"kodkrat": "PEN", "desckrat": "PENALTY"}]
    mock_cursor.rowcount = 1

    mock_conn = mock.MagicMock()
    mock_conn.cursor.return_value.__enter__ = lambda s: mock_cursor
    mock_conn.cursor.return_value.__exit__ = mock.MagicMock(return_value=False)
    mock_conn.cursor.return_value = mock_cursor
    mock_conn.is_connected.return_value = True

    def fake_execute(sql, params):
        captured["sql"] = sql
        captured["params"] = params

    mock_cursor.execute = fake_execute

    with monkeypatch.context() as m:
        import mysql.connector as _mc
        m.setattr(_mc, "connect", lambda **_kw: mock_conn)
        r = client.post(
            "/api/sql/execute",
            json={
                "sql": "SELECT kodkrat FROM misth_zpkrat WHERE kodxrisi = ? LIMIT 1",
                "params": ["0001"],
            },
        )

    assert r.status_code == 200
    assert "?" not in captured["sql"], "? should have been replaced with %s"
    assert "%s" in captured["sql"]
    assert captured["params"] == ["0001"]
