"""Tests for pb_cli.shell.db, shell.importing, shell.state (DB-boundary operations)."""

from pb_cli.core.importing import import_file
from pb_cli.core.models import ParseErrorRow, new_row_batch
from pb_cli.shell.db import count_sql_parse_failures, create_schema, db_connection, insert_parse_errors, parse_sql_file
from pb_cli.shell.importing import import_batch
from pb_cli.shell.state import load_file_state, save_file_state


def test_create_drop_schema(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        conn.execute(
            "INSERT INTO objects VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("test.srw", "w_test", "powerscript", None, None, None, None),
        )
        row = conn.execute("SELECT name FROM objects").fetchone()
        assert row is not None
        assert row[0] == "w_test"


def test_import_batch(tmp_path):
    db = str(tmp_path / "test.duckdb")
    obj = {"file": "test.srw", "kind": "powerscript", "meta": {"object": "w_test"}}
    with db_connection(db) as conn:
        create_schema(conn)
        rows = new_row_batch()
        import_file(obj, rows)
        count = import_batch([obj], conn)
        assert count > 0


def test_count_sql_parse_failures_excludes_cursor_ops(tmp_path):
    """OPEN/FETCH/CLOSE are intentionally unparsed (see sql.py's _SKIP_RE) and
    must not be counted as real failures, even though their literal text never
    contains the word CURSOR (only the originating DECLARE does)."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        for op, raw in [
            ("OPEN", "OPEN DYNAMIC cur;"),
            ("FETCH", "FETCH cur into :ll_count;"),
            ("CLOSE", "CLOSE cur;"),
        ]:
            conn.execute(
                "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                ("f.srw", "obj", "proc", 1, op, raw, None, [], [], False, False, False),
            )
        assert count_sql_parse_failures(conn) == 0


def test_count_sql_parse_failures_excludes_dynamic_cursor_declare(tmp_path):
    """DECLARE ... DYNAMIC CURSOR FOR <prepared-stmt-id> has no inline SQL to
    extract and is skipped by design — must not count as a real failure. A
    DECLARE ... CURSOR FOR SELECT that genuinely fails to parse must still
    count, so the exclusion is keyed on the DYNAMIC ... FOR <bareword> shape."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                "f.srw",
                "obj",
                "proc",
                1,
                "DECLARE",
                "DECLARE cur DYNAMIC CURSOR FOR SQLSA;",
                None,
                [],
                [],
                False,
                True,
                False,
            ),
        )
        assert count_sql_parse_failures(conn) == 0

        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                "f.srw",
                "obj",
                "proc",
                2,
                "DECLARE",
                "DECLARE cur_order CURSOR FOR SELECT garbage(((",
                None,
                [],
                [],
                False,
                True,
                False,
            ),
        )
        assert count_sql_parse_failures(conn) == 1


def test_count_sql_parse_failures_counts_real_failures(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            ("f.srw", "obj", "proc", 1, "SELECT", "SELECT 1 FROM", None, [], [], False, False, False),
        )
        assert count_sql_parse_failures(conn) == 1


def test_insert_parse_errors_roundtrip(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        insert_parse_errors(
            conn,
            [
                ParseErrorRow("bad.srw", "powerscript", "lex error at line 3", None, None, 3, "garbled source"),
                ParseErrorRow("f.srw", "sql", "Invalid expression", "obj", "proc", 7, "SELECT * FROM ("),
            ],
        )
        rows = conn.execute("SELECT file, error_kind, message, object, proc_name, line, snippet FROM parse_errors ORDER BY file").fetchall()
        assert len(rows) == 2
        assert rows[0] == ("bad.srw", "powerscript", "lex error at line 3", None, None, 3, "garbled source")
        assert rows[1] == ("f.srw", "sql", "Invalid expression", "obj", "proc", 7, "SELECT * FROM (")


def test_file_state_roundtrip(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        save_file_state(conn, {"a.srw": "abc123"})
        state = load_file_state(conn)
        assert state == {"a.srw": "abc123"}


def test_parse_sql_file_with_params(tmp_path):
    sql_file = tmp_path / "test.sql"
    sql_file.write_text("-- My query\n-- :name TEXT\n-- :limit INT 10\nSELECT * FROM t\n")
    desc, params, sql, _ = parse_sql_file(sql_file)
    assert desc == "My query"
    assert len(params) == 2
    assert params[0] == ("name", "TEXT", None)
    assert params[1] == ("limit", "INT", "10")
    assert "SELECT * FROM t" in sql
