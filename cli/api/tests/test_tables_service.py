"""Unit tests for pb.api.services.tables."""

from __future__ import annotations

import duckdb
from pb.api.services.tables import (
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


def test_get_table_stats_ddl_not_loaded(db_conn: duckdb.DuckDBPyConnection):
    # db_conn is built without --ddl or the SQL bridge (see conftest.py).
    # catalog_columns/catalog_fks/sql_statement_columns are empty, but
    # dw_joins (native Haskell AST parsing, no bridge needed) is NOT — so
    # get_fk_graph's "unenforced" bucket is every dw_join edge (none can be
    # corroborated with no DDL to check against), not 0. This is the exact
    # silent-degradation trap Plan 154 exists to surface: without ddl_loaded,
    # a nonzero unenforced_fk_count means "can't check", not "checked, found
    # 52 real violations". corroborated/unused genuinely are 0 (both require
    # catalog_fks). dead_column_count/co_update_* genuinely are 0 too
    # (catalog_columns and sql_statement_columns are both bridge/DDL-gated).
    result = get_table_stats(db_conn)
    assert result["ddl_loaded"] is False
    assert result["unenforced_fk_count"] == 52
    assert result["unused_fk_count"] == 0
    assert result["corroborated_fk_count"] == 0
    assert result["dead_column_count"] == 0
    assert result["co_update_pair_count"] == 0
    assert result["co_update_violation_count"] == 0


def test_get_table_stats_with_ddl_loaded(schema_db_conn: duckdb.DuckDBPyConnection):
    # schema_db_conn is built with --ddl + the SQL bridge — pinned to the
    # same real openpay counts test_schema_service.py's D1/D2/D4 tests
    # already verify independently (47/5/36 FKs, 4 dead columns, 45 pairs /
    # 0 violations at the default min_support=2).
    result = get_table_stats(schema_db_conn)
    assert result["ddl_loaded"] is True
    assert result["corroborated_fk_count"] == 47
    assert result["unenforced_fk_count"] == 5
    assert result["unused_fk_count"] == 36
    assert result["dead_column_count"] == 4
    assert result["co_update_pair_count"] == 45
    assert result["co_update_violation_count"] == 0
