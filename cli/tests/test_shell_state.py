"""Unit tests for pb_cli.shell.state — uses in-memory DuckDB."""

from pb_cli.shell.db import create_schema, db_connection
from pb_cli.shell.state import (
    create_state_table,
    delete_file_rows,
    load_file_state,
    save_file_state,
)


def test_load_file_state_empty_db(tmp_path):
    with db_connection(str(tmp_path / "test.duckdb")) as conn:
        result = load_file_state(conn)
        assert result == {}


def test_load_file_state_with_data(tmp_path):
    with db_connection(str(tmp_path / "test.duckdb")) as conn:
        create_schema(conn)
        create_state_table(conn)
        save_file_state(conn, {"a.srw": "abc", "b.sru": "def"})
        result = load_file_state(conn)
        assert result == {"a.srw": "abc", "b.sru": "def"}


def test_delete_file_rows_cleans_inherits(tmp_path):
    with db_connection(str(tmp_path / "test.duckdb")) as conn:
        create_schema(conn)
        create_state_table(conn)
        conn.execute(
            "INSERT INTO objects VALUES (?, ?, ?, ?, ?)",
            ("child.srw", "w_child", "powerscript", None, None),
        )
        conn.execute("INSERT INTO inherits VALUES (?, ?)", ("w_child", "w_base"))
        delete_file_rows(conn, "child.srw")
        assert conn.execute("SELECT count(*) FROM objects").fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM inherits").fetchone()[0] == 0


def test_delete_file_rows_no_objects(tmp_path):
    with db_connection(str(tmp_path / "test.duckdb")) as conn:
        create_schema(conn)
        create_state_table(conn)
        save_file_state(conn, {"orphan.srw": "abc"})
        delete_file_rows(conn, "orphan.srw")
        assert load_file_state(conn) == {}


def test_save_file_state_idempotent(tmp_path):
    with db_connection(str(tmp_path / "test.duckdb")) as conn:
        create_schema(conn)
        create_state_table(conn)
        save_file_state(conn, {"a.srw": "v1"})
        save_file_state(conn, {"a.srw": "v2"})
        result = load_file_state(conn)
        assert result == {"a.srw": "v2"}


def test_save_file_state_empty_dict(tmp_path):
    with db_connection(str(tmp_path / "test.duckdb")) as conn:
        create_schema(conn)
        create_state_table(conn)
        save_file_state(conn, {})
        assert load_file_state(conn) == {}
