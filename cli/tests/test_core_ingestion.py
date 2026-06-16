from pb_cli.core.ingestion import _extract_sql, _walk_body_raw, ingest_file
from pb_cli.core.models import new_row_batch


def test_ingest_powerscript_object():
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
    ingest_file(obj, rows)
    assert len(rows["objects"]) == 1
    assert rows["objects"][0].name == "w_main"
    assert rows["objects"][0].ancestor == "w_base"
    assert len(rows["inherits"]) == 1
    assert len(rows["procedures"]) == 1
    assert rows["procedures"][0].name == "uf_init"


def test_ingest_datawindow_object():
    obj = {
        "file": "d_test.srd",
        "kind": "datawindow",
        "meta": {"object": "d_test"},
        "controls": [
            {"name": "col_1", "type": "column", "band": "detail", "x": 10, "y": 20, "width": 100, "height": 24}
        ],
    }
    rows = new_row_batch()
    ingest_file(obj, rows)
    assert len(rows["dw_controls"]) == 1
    assert rows["dw_controls"][0].control_name == "col_1"


# ── _walk_body_raw ────────────────────────────────────────────────────────────


def test_walk_body_raw_top_level():
    stmts = [{"tag": "raw", "text": "SELECT 1"}]
    assert list(_walk_body_raw(stmts)) == [(0, "SELECT 1")]


def test_walk_body_raw_nested_in_if():
    stmts = [
        {
            "tag": "if",
            "cond": {},
            "then": [{"tag": "raw", "text": "SELECT id FROM t"}],
            "elseIfs": [],
            "else": None,
        }
    ]
    assert list(_walk_body_raw(stmts)) == [(0, "SELECT id FROM t")]


def test_walk_body_raw_nested_in_for():
    stmts = [
        {
            "tag": "for",
            "var": {},
            "from": {},
            "to": {},
            "step": None,
            "body": [{"tag": "raw", "text": "INSERT INTO log VALUES (1)"}],
        }
    ]
    assert list(_walk_body_raw(stmts)) == [(0, "INSERT INTO log VALUES (1)")]


def test_walk_body_raw_nested_in_do():
    stmts = [
        {
            "tag": "do",
            "cond": None,
            "body": [{"tag": "raw", "text": "FETCH cur INTO :ls_val"}],
            "loop": None,
        }
    ]
    assert list(_walk_body_raw(stmts)) == [(0, "FETCH cur INTO :ls_val")]


def test_walk_body_raw_nested_in_choose():
    stmts = [
        {
            "tag": "choose",
            "expr": {},
            "clauses": [
                {"body": [{"tag": "raw", "text": "UPDATE t SET x = 1"}]},
                {"body": [{"tag": "raw", "text": "DELETE FROM t"}]},
            ],
        }
    ]
    results = list(_walk_body_raw(stmts))
    assert len(results) == 2
    assert results[0][1] == "UPDATE t SET x = 1"
    assert results[1][1] == "DELETE FROM t"


def test_walk_body_raw_nested_in_elseif():
    stmts = [
        {
            "tag": "if",
            "cond": {},
            "then": [],
            "elseIfs": [
                {"body": [{"tag": "raw", "text": "SELECT 1 FROM dual"}]}
            ],
            "else": None,
        }
    ]
    assert list(_walk_body_raw(stmts)) == [(0, "SELECT 1 FROM dual")]


def test_walk_body_raw_nested_in_else():
    stmts = [
        {
            "tag": "if",
            "cond": {},
            "then": [],
            "elseIfs": [],
            "else": [{"tag": "raw", "text": "ROLLBACK"}],
        }
    ]
    assert list(_walk_body_raw(stmts)) == [(0, "ROLLBACK")]


def test_walk_body_raw_multiple_nesting():
    stmts = [
        {
            "tag": "for",
            "var": {},
            "from": {},
            "to": {},
            "step": None,
            "body": [
                {
                    "tag": "if",
                    "cond": {},
                    "then": [{"tag": "raw", "text": "SELECT count(*) INTO :ll_n FROM t"}],
                    "elseIfs": [],
                    "else": None,
                }
            ],
        }
    ]
    assert list(_walk_body_raw(stmts)) == [(0, "SELECT count(*) INTO :ll_n FROM t")]


def test_walk_body_raw_non_sql_raw_skipped():
    stmts = [{"tag": "raw", "text": "event clicked()"}]
    results = list(_walk_body_raw(stmts))
    assert len(results) == 1
    assert results[0][1] == "event clicked()"


def test_walk_body_raw_empty():
    assert list(_walk_body_raw([])) == []
    assert list(_walk_body_raw(None)) == []


# ── _extract_sql ──────────────────────────────────────────────────────────────


def _make_func_body(body):
    return json.dumps(body)


import json


def test_extract_sql_top_level_raw():
    body = _make_func_body([{"tag": "raw", "text": "SELECT 1 FROM dual"}])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].raw_sql == "SELECT 1 FROM dual"
    assert rows["sql_statements"][0].operation == "SELECT"


def test_extract_sql_nested_in_if():
    body = _make_func_body([
        {
            "tag": "if",
            "cond": {},
            "then": [{"tag": "raw", "text": "SELECT id FROM users WHERE active = 1"}],
            "elseIfs": [],
            "else": None,
        }
    ])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert "users" in rows["sql_statements"][0].tables


def test_extract_sql_nested_in_for():
    body = _make_func_body([
        {
            "tag": "for",
            "var": {},
            "from": {},
            "to": {},
            "step": None,
            "body": [{"tag": "raw", "text": "INSERT INTO audit_log (msg) VALUES ('loop')"}],
        }
    ])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].operation == "INSERT"


def test_extract_sql_nested_in_do():
    body = _make_func_body([
        {
            "tag": "do",
            "cond": None,
            "body": [{"tag": "raw", "text": "FETCH cur_data INTO :ls_val;COMMIT"}],
            "loop": None,
        }
    ])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].operation == "FETCH"


def test_extract_sql_nested_in_choose():
    body = _make_func_body([
        {
            "tag": "choose",
            "expr": {},
            "clauses": [
                {"body": [{"tag": "raw", "text": "UPDATE accounts SET bal = 0"}]},
                {"body": [{"tag": "raw", "text": "DELETE FROM temp WHERE id > 100"}]},
            ],
        }
    ])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 2
    ops = {s.operation for s in rows["sql_statements"]}
    assert ops == {"UPDATE", "DELETE"}


def test_extract_sql_nested_in_elseif():
    body = _make_func_body([
        {
            "tag": "if",
            "cond": {},
            "then": [],
            "elseIfs": [{"body": [{"tag": "raw", "text": "SELECT 1 FROM dual"}]}],
            "else": None,
        }
    ])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1


def test_extract_sql_nested_in_else():
    body = _make_func_body([
        {
            "tag": "if",
            "cond": {},
            "then": [],
            "elseIfs": [],
            "else": [{"tag": "raw", "text": "ROLLBACK USING SQLCA"}],
        }
    ])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 1
    assert rows["sql_statements"][0].operation == "ROLLBACK"


def test_extract_sql_multiple_nesting():
    body = _make_func_body([
        {
            "tag": "for",
            "var": {},
            "from": {},
            "to": {},
            "step": None,
            "body": [
                {
                    "tag": "if",
                    "cond": {},
                    "then": [{"tag": "raw", "text": "SELECT count(*) INTO :ll_n FROM items"}],
                    "elseIfs": [],
                    "else": [{"tag": "raw", "text": "INSERT INTO items (name) VALUES ('default')"}],
                }
            ],
        }
    ])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 2


def test_extract_sql_non_sql_raw_skipped():
    body = _make_func_body([{"tag": "raw", "text": "event open()"}])
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", body, "oracle", rows)
    assert len(rows["sql_statements"]) == 0


def test_extract_sql_empty_body():
    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", None, "oracle", rows)
    assert len(rows["sql_statements"]) == 0

    rows = new_row_batch()
    _extract_sql("test.srw", "w_main", "uf_init", "[]", "oracle", rows)
    assert len(rows["sql_statements"]) == 0
