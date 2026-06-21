"""
Integration tests for pb_cli.index.

Requires:
  - cabal build (pb-runner compiled)
  - uv sync (duckdb Python package)

Run:
  uv run pytest tests/test_index.py
"""

from pb_cli.core.importing import _import_dw, _proc_row, import_file
from pb_cli.core.models import ProcedureRow, new_row_batch


def q(conn, sql: str):
    return conn.execute(sql).fetchone()[0]


def test_objects_table_populated(db_conn):
    count = q(db_conn, "SELECT count(*) FROM objects")
    assert count > 0, "objects table is empty"
    kinds = {r[0] for r in db_conn.execute("SELECT DISTINCT kind FROM objects").fetchall()}
    assert kinds <= {"powerscript", "datawindow", "pipeline", "project"}, (
        f"unexpected kind values: {kinds - {'powerscript', 'datawindow', 'pipeline', 'project'}}"
    )
    file_count = q(db_conn, "SELECT count(DISTINCT file) FROM objects")
    assert file_count == count, "duplicate objects rows (more than one per file)"


def test_procedures_table_has_functions(db_conn):
    fn_count = q(db_conn, "SELECT count(*) FROM procedures WHERE proc_type = 'function'")
    assert fn_count > 0, "no function rows in procedures table"
    ev_count = q(db_conn, "SELECT count(*) FROM procedures WHERE proc_type = 'event'")
    assert ev_count > 0, "no event rows in procedures table"
    unnamed = q(db_conn, "SELECT count(*) FROM procedures WHERE name IS NULL OR name = ''")
    assert unnamed == 0, f"{unnamed} procedures rows have empty name"


def test_dw_controls_table_has_band(db_conn):
    total = q(db_conn, "SELECT count(*) FROM dw_controls")
    assert total > 0, "dw_controls table is empty"
    with_band = q(db_conn, "SELECT count(*) FROM dw_controls WHERE band IS NOT NULL")
    assert with_band > 0, "no dw_controls rows have a band value"


def test_inherits_edges_match_declared_ancestors(db_conn):
    count = q(db_conn, "SELECT count(*) FROM inherits")
    assert count > 200, f"expected >200 inherits rows, got {count}"
    orphans = q(
        db_conn,
        """
        SELECT count(*) FROM inherits i
        LEFT JOIN objects o ON i.from_object = o.name
        WHERE o.name IS NULL
    """,
    )
    assert orphans == 0, f"{orphans} inherits.from_object values not in objects table"


def test_dw_retrieve_tables_populated_when_e2_done(db_conn):
    count = q(db_conn, "SELECT count(*) FROM dw_retrieve_tables")
    assert count > 0, "dw_retrieve_tables is empty — E2 PBSELECT data missing?"
    unknown = q(
        db_conn,
        """
        SELECT count(*) FROM dw_retrieve_tables dt
        LEFT JOIN objects o ON dt.file = o.file
        WHERE o.file IS NULL
    """,
    )
    assert unknown == 0, f"{unknown} dw_retrieve_tables rows reference unknown files"


# ---------------------------------------------------------------------------
# Unit tests for _import_dw tag dispatch (no DB, no pb-runner)
# ---------------------------------------------------------------------------


def _rows():
    return new_row_batch()


# ---------------------------------------------------------------------------
# Schema consistency guard
# ---------------------------------------------------------------------------


def test_proc_row_length_matches_named_tuple():
    """_proc_row must return a tuple whose length matches ProcedureRow._fields."""
    block = {
        "meta": {"object": "w_test", "startLine": 1, "endLine": 5},
        "sig": {"name": "f_test", "modifiers": [], "params": "", "returnType": "integer"},
        "body": [],
        "source_rendered": "",
    }
    row = _proc_row("test.sru", "function", block, [])
    assert len(row) == len(ProcedureRow._fields), (
        f"_proc_row returns {len(row)} values but ProcedureRow has {len(ProcedureRow._fields)} fields"
    )


# ---------------------------------------------------------------------------
# Cyclomatic complexity computed during indexing
# ---------------------------------------------------------------------------


def test_proc_row_cyclomatic_empty_body():
    block = {
        "meta": {"object": "w_test", "startLine": 1, "endLine": 5},
        "sig": {"name": "f_test", "modifiers": [], "params": "", "returnType": "integer"},
        "body": [],
        "source_rendered": "",
        "cfg": {"blocks": [{"id": "b0"}], "edges": [], "entry": "b0", "exits": ["b0"]},
    }
    row = _proc_row("test.sru", "function", block, [])
    assert row.cyclomatic == 1, f"empty body → cyclomatic=1, got {row.cyclomatic}"


def test_proc_row_cyclomatic_with_branches():
    body = [
        {"tag": "BsIf", "contents": {"cond": {}, "then": [], "elseIfs": [], "else": None}},
        {"tag": "BsFor", "contents": {"body": []}},
        {"tag": "BsChoose", "contents": {"expr": {}, "clauses": []}},
    ]
    # 3 blocks, 3 edges → cyclomatic = E - N + 2 = 3 - 3 + 2 = 2
    block = {
        "meta": {"object": "w_test", "startLine": 1, "endLine": 10},
        "sig": {"name": "f_test", "modifiers": [], "params": "", "returnType": "integer"},
        "body": body,
        "source_rendered": "",
        "cfg": {
            "blocks": [{"id": "b0"}, {"id": "b1"}, {"id": "b2"}],
            "edges": [
                {"src": "b0", "dst": "b1", "label": "T"},
                {"src": "b0", "dst": "b2", "label": "F"},
                {"src": "b1", "dst": "b2", "label": ""},
            ],
            "entry": "b0",
            "exits": ["b2"],
        },
    }
    row = _proc_row("test.sru", "function", block, body)
    assert row.cyclomatic == 2, f"E-N+2 = 3-3+2 = 2, got {row.cyclomatic}"


def test_proc_row_cyclomatic_nested():
    inner = {"tag": "BsIf", "contents": {"cond": {}, "then": [], "elseIfs": [], "else": None}}
    outer = {"tag": "BsFor", "contents": {"body": [inner]}}
    body = [outer]
    # 2 blocks, 2 edges → cyclomatic = E - N + 2 = 2 - 2 + 2 = 2
    block = {
        "meta": {"object": "w_test", "startLine": 1, "endLine": 10},
        "sig": {"name": "f_test", "modifiers": [], "params": "", "returnType": "integer"},
        "body": body,
        "source_rendered": "",
        "cfg": {
            "blocks": [{"id": "b0"}, {"id": "b1"}],
            "edges": [
                {"src": "b0", "dst": "b1", "label": "T"},
                {"src": "b0", "dst": "b1", "label": "F"},
            ],
            "entry": "b0",
            "exits": ["b1"],
        },
    }
    row = _proc_row("test.sru", "function", block, body)
    assert row.cyclomatic == 2, f"E-N+2 = 2-2+2 = 2, got {row.cyclomatic}"


# ---------------------------------------------------------------------------
# Call extraction during indexing
# ---------------------------------------------------------------------------


def _ps_obj_with_body(proc_name: str, body: list) -> dict:
    return {
        "file": "test.sru",
        "kind": "powerscript",
        "meta": {"object": "w_test"},
        "functions": [
            {
                "meta": {"object": "w_test", "startLine": 1, "endLine": 10},
                "sig": {"name": proc_name, "modifiers": [], "params": "", "returnType": "integer"},
                "body": body,
                "source_rendered": "",
            }
        ],
        "subroutines": [],
        "events": [],
        "onBlocks": [],
    }


def test_import_file_extracts_ex_call():
    rows = _rows()
    body = [{"tag": "ExCall", "callee": {"segments": [{"name": "messagebox", "subscript": None}]}, "args": []}]
    import_file(_ps_obj_with_body("f_test", body), rows)
    callee_names = {r[3] for r in rows["calls"]}
    assert "messagebox" in callee_names, f"ExCall not extracted; calls: {callee_names}"


def test_import_file_extracts_method_call():
    rows = _rows()
    body = [{"tag": "ExMethodCall", "method": "Reset", "receiver": {}, "args": []}]
    import_file(_ps_obj_with_body("f_test", body), rows)
    callee_names = {r[3] for r in rows["calls"]}
    assert "Reset" in callee_names, f"ExMethodCall not extracted; calls: {callee_names}"


def test_import_file_calls_linked_to_object():
    rows = _rows()
    body = [{"tag": "ExCall", "callee": {"segments": [{"name": "getitem", "subscript": None}]}, "args": []}]
    import_file(_ps_obj_with_body("f_query", body), rows)
    assert rows["calls"], "no calls rows produced"
    file, obj, proc, callee, call_type = rows["calls"][0]
    assert file == "test.sru"
    assert obj == "w_test"
    assert proc == "f_query"
    assert callee == "getitem"
    assert call_type == "ExCall"


def test_import_file_no_calls_in_empty_body():
    rows = _rows()
    import_file(_ps_obj_with_body("f_empty", []), rows)
    assert rows["calls"] == [], "empty body should produce no calls"


def _ok_retrieve(**extra):
    # New format from pb-runner (genericToJSON): {"tag":"DwRetrieveOk","contents":{...}}
    return {
        "tag": "DwRetrieveOk",
        "contents": {
            "version": 400,
            "tables": [],
            "columns": [],
            "arguments": [],
            "where": [],
            **extra,
        },
    }


def _dw_obj(retrieve=None):
    obj = {"file": "test.srd", "kind": "datawindow", "meta": {"object": "d_test"}, "controls": []}
    if retrieve is not None:
        obj["table"] = {"retrieve": retrieve}
    return obj


def test_tag_ok_inserts_table():
    rows = _rows()
    _import_dw(_dw_obj(_ok_retrieve(tables=["emp"])), "test.srd", rows)
    assert len(rows["dw_retrieve_tables"]) == 1


def test_tag_ok_inserts_columns_split():
    rows = _rows()
    _import_dw(_dw_obj(_ok_retrieve(columns=["emp.id", "emp.name"])), "test.srd", rows)
    assert len(rows["dw_retrieve_columns"]) == 2
    table_names = {r[3] for r in rows["dw_retrieve_columns"]}
    col_names = {r[4] for r in rows["dw_retrieve_columns"]}
    assert table_names == {"emp"}
    assert col_names == {"id", "name"}


def test_tag_ok_inserts_where():
    rows = _rows()
    where = [{"exp1": "t.id", "op": "=", "exp2": ":p", "logic": None}]
    _import_dw(_dw_obj(_ok_retrieve(where=where)), "test.srd", rows)
    assert len(rows["dw_retrieve_where"]) == 1


def test_tag_ok_inserts_arguments():
    rows = _rows()
    args = [{"name": "aid", "type": "string"}]
    _import_dw(_dw_obj(_ok_retrieve(arguments=args)), "test.srd", rows)
    assert len(rows["dw_arguments"]) == 1


def test_tag_raw_inserts_nothing():
    # New format: {"tag":"DwRetrieveRaw","contents":"SELECT ..."}
    rows = _rows()
    _import_dw(_dw_obj({"tag": "DwRetrieveRaw", "contents": "SELECT 1"}), "test.srd", rows)
    assert rows["dw_retrieve_tables"] == []
    assert rows["dw_retrieve_columns"] == []
    assert rows["dw_retrieve_where"] == []
    assert rows["dw_arguments"] == []


def test_no_retrieve_inserts_nothing():
    rows = _rows()
    _import_dw(_dw_obj(), "test.srd", rows)
    assert rows["dw_retrieve_tables"] == []
    assert rows["dw_retrieve_columns"] == []
    assert rows["dw_retrieve_where"] == []
    assert rows["dw_arguments"] == []


# ---------------------------------------------------------------------------
# Unit tests for SQL extraction from PowerScript procedure bodies
# ---------------------------------------------------------------------------


def _ps_obj(proc_name: str, body_nodes: list) -> dict:
    """Minimal PowerScript object fixture with one function containing body_nodes."""
    return {
        "file": "test.sru",
        "kind": "powerscript",
        "meta": {"object": "w_test"},
        "functions": [
            {
                "meta": {"object": "w_test", "startLine": 1, "endLine": 10},
                "sig": {
                    "name": proc_name,
                    "modifiers": [],
                    "params": "",
                    "returnType": "integer",
                },
                "body": body_nodes,
                "source_rendered": "",
            }
        ],
        "subroutines": [],
        "events": [],
        "onBlocks": [],
    }


def _sql_node(text: str, line: int = 1) -> dict:
    """Simulate a Located BsRaw JSON node as produced by pb-runner."""
    return {"line": line, "node": {"tag": "BsRaw", "contents": text}}


def test_select_extracted_from_proc():
    rows = _rows()
    obj = _ps_obj(
        "f_query",
        [_sql_node("SELECT cust_name INTO :ls_name FROM customer WHERE cust_id = :li_id", line=5)],
    )
    import_file(obj, rows)
    assert len(rows["sql_statements"]) == 1
    row = rows["sql_statements"][0]
    # (file, object, proc_name, line, operation, raw_sql, parsed_json,
    #  tables, columns, has_into, has_cursor, parse_ok)
    assert row[0] == "test.sru"
    assert row[1] == "w_test"
    assert row[2] == "f_query"
    assert row[3] == 5
    assert row[4] == "SELECT"
    assert row.tables is not None
    assert "customer" in row.tables
    assert row[9] is True  # has_into
    assert row[11] is True  # parse_ok


def test_non_sql_bsraw_not_extracted():
    rows = _rows()
    obj = _ps_obj("f_other", [_sql_node("CALL super::constructor")])
    import_file(obj, rows)
    assert rows["sql_statements"] == []


def test_multiple_sql_stmts_indexed():
    rows = _rows()
    obj = _ps_obj(
        "f_multi",
        [
            _sql_node("INSERT INTO audit_log (user_id, action) VALUES (:li_id, :ls_action)", line=2),
            _sql_node("COMMIT USING SQLCA", line=3),
        ],
    )
    import_file(obj, rows)
    assert len(rows["sql_statements"]) == 2
    ops = {r[4] for r in rows["sql_statements"]}
    assert ops == {"INSERT", "COMMIT"}


def test_sql_nested_in_if_is_extracted():
    """SQL wrapped in a conditional (the common error-check pattern) must not be skipped."""
    rows = _rows()
    obj = _ps_obj(
        "f_guarded",
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsIf",
                    "contents": {
                        "cond": {"tag": "ExBool", "contents": True},
                        "then": [_sql_node("SELECT id FROM orders", line=2)],
                        "elseIfs": [],
                        "else": None,
                    },
                },
            }
        ],
    )
    import_file(obj, rows)
    assert len(rows["sql_statements"]) == 1
    row = rows["sql_statements"][0]
    assert row.line == 2
    assert row.tables is not None
    assert "orders" in row.tables


def test_sql_nested_in_for_loop_is_extracted():
    rows = _rows()
    obj = _ps_obj(
        "f_loop",
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsFor",
                    "contents": {
                        "var": {"segments": [{"name": "i", "subscript": None}]},
                        "from": {"tag": "ExInt", "contents": "1"},
                        "to": {"tag": "ExInt", "contents": "10"},
                        "step": None,
                        "body": [_sql_node("UPDATE invoices SET paid = 1", line=2)],
                    },
                },
            }
        ],
    )
    import_file(obj, rows)
    assert len(rows["sql_statements"]) == 1
    tables = rows["sql_statements"][0].tables
    assert tables is not None
    assert "invoices" in tables


def test_sql_nested_in_choose_case_is_extracted():
    rows = _rows()
    obj = _ps_obj(
        "f_switch",
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsChoose",
                    "contents": {
                        "expr": {"tag": "ExInt", "contents": "1"},
                        "clauses": [
                            {"expr": ["1"], "body": [_sql_node("DELETE FROM sessions", line=2)]},
                        ],
                    },
                },
            }
        ],
    )
    import_file(obj, rows)
    assert len(rows["sql_statements"]) == 1
    tables = rows["sql_statements"][0].tables
    assert tables is not None
    assert "sessions" in tables


def test_all_sql_tables_view(db_conn):
    """all_sql_tables view must exist and include dw_retrieve_tables rows."""
    count = db_conn.execute("SELECT count(*) FROM all_sql_tables WHERE source = 'datawindow'").fetchone()[0]
    assert count > 0, "all_sql_tables should include DataWindow PBSELECT rows"


def test_sql_statements_populated_from_real_corpus(db_conn):
    """End-to-end regression test: openpay-0.1.1b-extract has real body-level SQL (selects,
    inserts, cursor ops) wrapped inside if/for/do blocks. This must come from the
    real pb-runner binary's output, not a hand-written fixture — a previous bug
    where ingestion code assumed the wrong JSON tag/wrapper shape passed every
    fixture-based unit test while silently extracting zero rows against real output."""
    count = db_conn.execute("SELECT count(*) FROM sql_statements").fetchone()[0]
    assert count > 0, "openpay-0.1.1b-extract has real body-level SQL; sql_statements must not be empty"

    ps_tables = {
        r[0]
        for r in db_conn.execute(
            "SELECT DISTINCT table_name FROM all_sql_tables WHERE source = 'powerscript'"
        ).fetchall()
    }
    assert "misth_final" in ps_tables, "known table referenced only inside nested control-flow SQL"
