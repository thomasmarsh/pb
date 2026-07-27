"""Tests for pb.pipeline.db (DB-boundary operations)."""


from pb.pipeline.db import count_sql_parse_failures, db_connection, parse_sql_file

_CREATE_SQL_STATEMENTS = """
    CREATE TABLE sql_statements (
        file TEXT, object TEXT, proc_name TEXT, line INTEGER,
        operation TEXT, tables TEXT, columns TEXT, raw_sql TEXT, parse_ok BOOLEAN,
        error TEXT
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
                "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("f.srw", "obj", "proc", 1, op, None, None, raw, False, None),
            )
        assert count_sql_parse_failures(conn) == 0


def test_count_sql_parse_failures_excludes_dynamic_cursor_declare(tmp_path):
    """DECLARE ... DYNAMIC CURSOR FOR <bareword> must not count as a failure."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        conn.execute(_CREATE_SQL_STATEMENTS)
        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?)",
            ("f.srw", "obj", "proc", 1, "DECLARE",
             None, None, "DECLARE cur DYNAMIC CURSOR FOR SQLSA;", False, None),
        )
        assert count_sql_parse_failures(conn) == 0

        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?)",
            ("f.srw", "obj", "proc", 2, "DECLARE",
             None, None, "DECLARE cur_order CURSOR FOR SELECT garbage(((", False, None),
        )
        assert count_sql_parse_failures(conn) == 1


def test_count_sql_parse_failures_counts_real_failures(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        conn.execute(_CREATE_SQL_STATEMENTS)
        conn.execute(
            "INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?)",
            ("f.srw", "obj", "proc", 1, "SELECT", None, None, "SELECT 1 FROM", False, None),
        )
        assert count_sql_parse_failures(conn) == 1


def test_setup_db_extras_creates_tables(tmp_path):
    """setup_db_extras should create the metadata and object_metrics tables."""
    from pb.pipeline.db import setup_db_extras
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        setup_db_extras(conn)
        conn.execute("SELECT key, value FROM metadata LIMIT 1")
        conn.execute("INSERT INTO metadata VALUES ('k', 'v')")
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
