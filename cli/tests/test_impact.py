"""Tests for pb impact command."""
import pytest
from pb_cli.impact import run_impact


@pytest.fixture
def impact_db(tmp_path):
    """Minimal DuckDB with one table reference and one inheritance edge."""
    import duckdb
    db = str(tmp_path / "test.duckdb")
    conn = duckdb.connect(db)
    conn.execute("""
        CREATE TABLE sql_statements (
            file TEXT, object TEXT, proc_name TEXT, stmt_idx INT,
            operation TEXT, raw_sql TEXT, parsed_json TEXT,
            tables TEXT[], columns TEXT[], has_into BOOL, has_cursor BOOL, parse_ok BOOL
        )
    """)
    conn.execute("""
        INSERT INTO sql_statements VALUES (
            'f.sru', 'w_base', 'ue_load', 0, 'SELECT',
            'SELECT id, name FROM customer', NULL,
            ['customer'], ['id', 'name'], false, false, true
        )
    """)
    conn.execute("""
        CREATE TABLE inherits (from_object TEXT, to_object TEXT)
    """)
    conn.execute("INSERT INTO inherits VALUES ('w_child', 'w_base')")
    conn.execute("""
        CREATE TABLE dw_retrieve_columns (
            file TEXT, dw_name TEXT, column_fqn TEXT, table_name TEXT, column_name TEXT
        )
    """)
    conn.execute("""
        CREATE VIEW all_sql_tables AS
        SELECT file, object, 'powerscript' AS source, operation,
               unnest(tables) AS table_name, proc_name, stmt_idx
        FROM sql_statements WHERE tables IS NOT NULL
    """)
    conn.close()
    return db


def test_impact_direct(impact_db, capsys):
    run_impact("customer", db=impact_db)
    out = capsys.readouterr().out
    assert "w_base" in out
    assert "DIRECT" in out


def test_impact_inherited(impact_db, capsys):
    run_impact("customer", db=impact_db)
    out = capsys.readouterr().out
    assert "w_child" in out
    assert "INHERITED" in out


def test_impact_column(impact_db, capsys):
    run_impact("customer", column="name", db=impact_db)
    out = capsys.readouterr().out
    assert "w_base" in out


def test_impact_no_results(impact_db, capsys):
    run_impact("nonexistent_table", db=impact_db)
    out = capsys.readouterr().out
    assert "No references" in out
