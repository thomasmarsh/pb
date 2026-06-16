"""Tests for pb_cli.storage (DB-boundary: schema, connection, inserts, state)."""

from pb_cli.storage import (
    create_schema,
    create_state_table,
    db_connection,
    ingest_batch,
    load_file_state,
    parse_sql_file,
    save_file_state,
)


def test_create_drop_schema(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        conn.execute(
            "INSERT INTO objects VALUES (?, ?, ?, ?, ?)",
            ("test.srw", "w_test", "powerscript", None, None),
        )
        row = conn.execute("SELECT name FROM objects").fetchone()
        assert row[0] == "w_test"


def test_ingest_batch(tmp_path):
    from pb_cli.core.ingestion import ingest_file
    from pb_cli.core.models import new_row_batch

    db = str(tmp_path / "test.duckdb")
    obj = {"file": "test.srw", "kind": "powerscript", "meta": {"object": "w_test"}}
    with db_connection(db) as conn:
        create_schema(conn)
        rows = new_row_batch()
        ingest_file(obj, rows)
        count = ingest_batch([obj], conn)
        assert count > 0


def test_file_state_roundtrip(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_state_table(conn)
        save_file_state(conn, {"a.srw": "abc123"})
        state = load_file_state(conn)
        assert state == {"a.srw": "abc123"}


def test_parse_sql_file_with_params(tmp_path):
    sql_file = tmp_path / "test.sql"
    sql_file.write_text("-- My query\n-- :name TEXT\n-- :limit INT 10\nSELECT * FROM t\n")
    desc, params, sql = parse_sql_file(sql_file)
    assert desc == "My query"
    assert len(params) == 2
    assert params[0] == ("name", "TEXT", None)
    assert params[1] == ("limit", "INT", "10")
    assert "SELECT * FROM t" in sql
