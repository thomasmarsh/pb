"""Tests for pb_cli.shell.db (DB-boundary operations)."""


from pb_cli.shell.db import count_sql_parse_failures, db_connection, parse_sql_file

_CREATE_SQL_STATEMENTS = """
    CREATE TABLE sql_statements (
        file TEXT, object TEXT, proc_name TEXT, line INTEGER,
        operation TEXT, tables TEXT, columns TEXT, raw_sql TEXT, parse_ok BOOLEAN
    )
"""


def test_count_sql_parse_failures_excludes_cursor_ops(tmp_path):
    """OPEN/FETCH/CLOSE are intentionally unparsed and must not count as failures."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        conn.execute(_CREATE_SQL_STATEMENTS)
        for op, raw in [
            ("OPEN", "OPEN DYNAMIC cur;"),
            ("FETCH", "FETCH cur into :ll_count;"),
            ("CLOSE", "CLOSE cur;"),
        ]:
            conn.execute(
                "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?)",
                ("f.srw", "obj", "proc", 1, op, None, None, raw, False),
            )
        assert count_sql_parse_failures(conn) == 0


def test_count_sql_parse_failures_excludes_dynamic_cursor_declare(tmp_path):
    """DECLARE ... DYNAMIC CURSOR FOR <bareword> must not count as a failure."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        conn.execute(_CREATE_SQL_STATEMENTS)
        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?)",
            ("f.srw", "obj", "proc", 1, "DECLARE",
             None, None, "DECLARE cur DYNAMIC CURSOR FOR SQLSA;", False),
        )
        assert count_sql_parse_failures(conn) == 0

        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?)",
            ("f.srw", "obj", "proc", 2, "DECLARE",
             None, None, "DECLARE cur_order CURSOR FOR SELECT garbage(((", False),
        )
        assert count_sql_parse_failures(conn) == 1


def test_count_sql_parse_failures_counts_real_failures(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        conn.execute(_CREATE_SQL_STATEMENTS)
        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?)",
            ("f.srw", "obj", "proc", 1, "SELECT", None, None, "SELECT 1 FROM", False),
        )
        assert count_sql_parse_failures(conn) == 1


def test_setup_compat_layer_creates_views(tmp_path):
    """setup_compat_layer should create compat_* views on a Haskell-schema DB."""
    from pb_cli.shell.db import setup_compat_layer
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        conn.execute("CREATE TABLE objects (file TEXT, kind TEXT, object TEXT, ancestor TEXT)")
        conn.execute("CREATE TABLE procedures (file TEXT, object TEXT, proc_name TEXT, proc_type TEXT, start_line INT, end_line INT, cfg_json TEXT, cps_graph_json TEXT, params TEXT, return_type TEXT, cyclomatic INT)")
        conn.execute("CREATE TABLE call_sites (file TEXT, object TEXT, from_proc TEXT, to_name TEXT, call_type TEXT, line INT)")
        conn.execute("CREATE TABLE global_vars (file TEXT, object TEXT, var_name TEXT, var_type TEXT, mods TEXT)")
        conn.execute("CREATE TABLE dw_controls (file TEXT, object TEXT, band TEXT, control_type TEXT, name TEXT, x INT, y INT, width INT, height INT, expression TEXT)")
        conn.execute("CREATE TABLE dead_code (object TEXT, proc_name TEXT, proc_type TEXT, cyclomatic INT, confidence TEXT, caller_count_naive INT, caller_count_scoped INT)")
        conn.execute(_CREATE_SQL_STATEMENTS)
        setup_compat_layer(conn)
        # compat views should be queryable
        conn.execute("SELECT name FROM compat_objects LIMIT 1")
        conn.execute("SELECT name FROM compat_procedures LIMIT 1")
        conn.execute("SELECT count(*) FROM compat_calls")
        conn.execute("SELECT count(*) FROM object_metrics")


def test_parse_sql_file_with_params(tmp_path):
    sql_file = tmp_path / "test.sql"
    sql_file.write_text("-- My query\n-- :name TEXT\n-- :limit INT 10\nSELECT * FROM t\n")
    desc, params, sql, _ = parse_sql_file(sql_file)
    assert desc == "My query"
    assert len(params) == 2
    assert params[0] == ("name", "TEXT", None)
    assert params[1] == ("limit", "INT", "10")
    assert "SELECT * FROM t" in sql
