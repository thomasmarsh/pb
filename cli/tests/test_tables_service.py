"""Unit tests for pb_cli.explorer.services.tables."""

from __future__ import annotations

import duckdb

from pb_cli.explorer.services.tables import (
    column_lineage,
    get_table_detail,
    get_table_stats,
    impact_lineage,
    list_tables,
)


def test_list_tables_returns_ranked_list(db_conn: duckdb.DuckDBPyConnection):
    result = list_tables(db_conn)
    assert isinstance(result, list)
    # all_sql_tables only has rows when PB_SQL_WORKER (SQL bridge) is active.
    if not result:
        return
    counts = [row["dw_count"] + row["ps_count"] for row in result]
    assert counts == sorted(counts, reverse=True)


def test_column_lineage_returns_list(db_conn: duckdb.DuckDBPyConnection):
    tables = list_tables(db_conn)
    if not tables:
        return
    table_name = tables[0]["table_name"]
    result = column_lineage(db_conn, table_name)
    assert isinstance(result, list)
    if result:
        entry = result[0]
        assert set(entry) == {"column", "dw_readers", "ps_readers", "ps_writers", "read_count", "write_count"}


def test_impact_lineage_empty_for_unknown(db_conn: duckdb.DuckDBPyConnection):
    result = impact_lineage(db_conn, "__nonexistent_table__")
    assert result == {"direct": [], "inherited": []}


def test_get_table_detail(db_conn: duckdb.DuckDBPyConnection):
    tables = list_tables(db_conn)
    if not tables:
        return
    table_name = tables[0]["table_name"]
    result = get_table_detail(db_conn, table_name)
    assert result is not None
    assert result["table_name"] == table_name
    assert "datawindows" in result
    assert "columns" in result
    assert "where" in result
    assert "columns_detail" in result
    assert "impact" in result


def test_get_table_detail_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_table_detail(db_conn, "__nonexistent_table__") is None


def test_get_table_stats(db_conn: duckdb.DuckDBPyConnection):
    result = get_table_stats(db_conn)
    assert "objects" in result
    assert "procedures" in result
    assert result["objects"] > 0
    assert result["procedures"] > 0
    assert "by_kind" in result
    assert "top_complex" in result
    assert "top_pagerank" in result
