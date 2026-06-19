import json

from pb_cli.core.importing import _extract_sql, import_file
from pb_cli.core.models import new_row_batch


def test_import_powerscript_object():
    obj = {
        "file": "test.srw",
        "kind": "powerscript",
        "meta": {"object": "w_main", "ancestor": "w_base"},
        "functions": [
            {
                "sig": {"name": "uf_init", "modifiers": ["public"], "params": "()", "returnType": "void"},
                "body": [{"tag": "BsReturn", "contents": {}}],
            }
        ],
    }
    rows = new_row_batch()
    import_file(obj, rows)
    assert len(rows["objects"]) == 1
    assert rows["objects"][0].name == "w_main"
    assert rows["objects"][0].ancestor == "w_base"
    assert len(rows["inherits"]) == 1
    assert len(rows["procedures"]) == 1
    assert rows["procedures"][0].name == "uf_init"


def test_import_datawindow_object():
    obj = {
        "file": "d_test.srd",
        "kind": "datawindow",
        "meta": {"object": "d_test"},
        "controls": [
            {"name": "col_1", "type": "column", "band": "detail", "x": 10, "y": 20, "width": 100, "height": 24}
        ],
    }
    rows = new_row_batch()
    import_file(obj, rows)
    assert len(rows["dw_controls"]) == 1
    assert rows["dw_controls"][0].control_name == "col_1"


# ── _extract_sql ──────────────────────────────────────────────────────────────
#
# Body statements are [Located BodyStmt], i.e. every node (top-level and
# nested) is wrapped as {"line": N, "node": {"tag": ..., ...}}. Tags are the
# literal Haskell constructor names (BsRaw, BsIf, ...) and single
# positional-field constructors wrap their payload in "contents".


def _raw(text: str, line: int) -> dict:
    return {"line": line, "node": {"tag": "BsRaw", "contents": text}}


def _make_func_body(body):
    return json.dumps(body)


def test_extract_sql_top_level_raw():
    body = _make_func_body([_raw("SELECT 1 FROM dual", 1)])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].raw_sql == "SELECT 1 FROM dual"
    assert rows["sql_statements"][0].operation == "SELECT"
    assert rows["sql_statements"][0].line == 1


def test_extract_sql_nested_in_if():
    body = _make_func_body(
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsIf",
                    "contents": {
                        "cond": {},
                        "then": [_raw("SELECT id FROM users WHERE active = 1", 2)],
                        "elseIfs": [],
                        "else": None,
                    },
                },
            }
        ]
    )
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    tables = rows["sql_statements"][0].tables
    assert tables is not None
    assert "users" in tables
    assert rows["sql_statements"][0].line == 2


def test_extract_sql_nested_in_for():
    body = _make_func_body(
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsFor",
                    "contents": {
                        "var": {},
                        "from": {},
                        "to": {},
                        "step": None,
                        "body": [_raw("INSERT INTO audit_log (msg) VALUES ('loop')", 2)],
                    },
                },
            }
        ]
    )
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].operation == "INSERT"


def test_extract_sql_nested_in_do():
    body = _make_func_body(
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsDo",
                    "contents": {
                        "cond": None,
                        "body": [_raw("FETCH cur_data INTO :ls_val", 2)],
                        "loop": None,
                    },
                },
            }
        ]
    )
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].operation == "FETCH"


def test_extract_sql_nested_in_choose():
    body = _make_func_body(
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsChoose",
                    "contents": {
                        "expr": {},
                        "clauses": [
                            {"expr": None, "body": [_raw("UPDATE accounts SET bal = 0", 2)]},
                            {"expr": None, "body": [_raw("DELETE FROM temp WHERE id > 100", 3)]},
                        ],
                    },
                },
            }
        ]
    )
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 2
    ops = {s.operation for s in rows["sql_statements"]}
    assert ops == {"UPDATE", "DELETE"}


def test_extract_sql_nested_in_elseif():
    body = _make_func_body(
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsIf",
                    "contents": {
                        "cond": {},
                        "then": [],
                        "elseIfs": [{"cond": {}, "body": [_raw("SELECT 1 FROM dual", 2)]}],
                        "else": None,
                    },
                },
            }
        ]
    )
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1


def test_extract_sql_nested_in_else():
    body = _make_func_body(
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsIf",
                    "contents": {
                        "cond": {},
                        "then": [],
                        "elseIfs": [],
                        "else": [_raw("ROLLBACK USING SQLCA", 2)],
                    },
                },
            }
        ]
    )
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].operation == "ROLLBACK"


def test_extract_sql_multiple_nesting():
    body = _make_func_body(
        [
            {
                "line": 1,
                "node": {
                    "tag": "BsFor",
                    "contents": {
                        "var": {},
                        "from": {},
                        "to": {},
                        "step": None,
                        "body": [
                            {
                                "line": 2,
                                "node": {
                                    "tag": "BsIf",
                                    "contents": {
                                        "cond": {},
                                        "then": [_raw("SELECT count(*) INTO :ll_n FROM items", 3)],
                                        "elseIfs": [],
                                        "else": [_raw("INSERT INTO items (name) VALUES ('default')", 5)],
                                    },
                                },
                            }
                        ],
                    },
                },
            }
        ]
    )
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 2
    lines = {s.line for s in rows["sql_statements"]}
    assert lines == {3, 5}


def test_extract_sql_non_sql_raw_skipped():
    body = _make_func_body([_raw("event open()", 1)])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 0


def test_extract_sql_records_parse_error_row_on_failure():
    body = _make_func_body([_raw("SELECT * FROM (", 7)])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].parse_ok is False
    assert len(rows["parse_errors"]) == 1
    err = rows["parse_errors"][0]
    assert err.file == "test.srw"
    assert err.error_kind == "sql"
    assert err.object == "w_main"
    assert err.proc_name == "uf_init"
    assert err.line == 7
    assert err.message
    assert err.snippet == "SELECT * FROM ("


def test_extract_sql_no_parse_error_row_for_intentional_skips():
    """OPEN/CLOSE/etc. report parse_ok=False by design — not a parse_errors row."""
    body = _make_func_body([_raw("OPEN cur_order", 1)])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].parse_ok is False
    assert len(rows["parse_errors"]) == 0


def test_import_dw_table_names_lowercased():
    """DW retrieve table names and column FQN/column names must be lowercased on
    ingest — Oracle is case-insensitive, so MYTABLE and mytable are the same."""
    obj = {
        "file": "d_test.srd",
        "kind": "datawindow",
        "meta": {"object": "d_test"},
        "controls": [],
        "table": {
            "retrieve": {
                "tag": "DwRetrieveOk",
                "contents": {
                    "tables": ["MYTABLE", "OtherTable"],
                    "columns": ["MYTABLE.col1", "OtherTable.COL2"],
                    "where": [],
                },
            }
        },
    }
    rows = new_row_batch()
    import_file(obj, rows)
    assert [r.table_name for r in rows["dw_retrieve_tables"]] == ["mytable", "othertable"]
    cols = rows["dw_retrieve_columns"]
    assert [r.table_name for r in cols] == ["mytable", "othertable"]
    assert [r.column_fqn for r in cols] == ["mytable.col1", "othertable.col2"]
    assert [r.column_name for r in cols] == ["col1", "col2"]


def test_import_dw_extracts_calls_from_parsed_expression():
    obj = {
        "file": "d_test.srd",
        "kind": "datawindow",
        "meta": {"object": "d_test"},
        "controls": [
            {
                "name": "cmp1",
                "type": "compute",
                "band": "summary",
                "parsedExpression": {
                    "tag": "ExCall",
                    "callee": {"segments": [{"name": "fn_foo", "subscript": None}]},
                    "callArgs": [["bar"]],
                },
            }
        ],
    }
    rows = new_row_batch()
    import_file(obj, rows)
    call_rows = rows["calls"]
    assert len(call_rows) == 1
    assert call_rows[0].to_name == "fn_foo"
    assert call_rows[0].call_type == "ExCall"
    assert call_rows[0].object == "d_test"
    assert call_rows[0].from_proc == "cmp1"


def test_import_dw_expression_multiple_fn_calls():
    """Two ExCall nodes under an ExBinOp both get extracted."""
    obj = {
        "file": "d_test.srd",
        "kind": "datawindow",
        "meta": {"object": "d_test"},
        "controls": [
            {
                "name": "cmp2",
                "type": "compute",
                "band": "summary",
                "parsedExpression": {
                    "tag": "ExBinOp",
                    "lhs": {
                        "tag": "ExCall",
                        "callee": {"segments": [{"name": "fn_a", "subscript": None}]},
                        "callArgs": [],
                    },
                    "op": {"tag": "BopAdd"},
                    "rhs": {
                        "tag": "ExCall",
                        "callee": {"segments": [{"name": "fn_b", "subscript": None}]},
                        "callArgs": [],
                    },
                },
            }
        ],
    }
    rows = new_row_batch()
    import_file(obj, rows)
    names = {r.to_name for r in rows["calls"]}
    assert names == {"fn_a", "fn_b"}


def test_import_dw_no_parsed_expression_no_calls():
    """A control with no parsedExpression produces no calls rows."""
    obj = {
        "file": "d_test.srd",
        "kind": "datawindow",
        "meta": {"object": "d_test"},
        "controls": [
            {"name": "lbl1", "type": "text", "band": "header"}
        ],
    }
    rows = new_row_batch()
    import_file(obj, rows)
    assert rows["calls"] == []


def test_extract_sql_empty_body():
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", None, "oracle", rows)
    assert len(rows["sql_statements"]) == 0

    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", "[]", "oracle", rows)
    assert len(rows["sql_statements"]) == 0
