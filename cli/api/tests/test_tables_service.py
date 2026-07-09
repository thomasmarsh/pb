"""Unit tests for pb.api.services.tables."""

from __future__ import annotations

import duckdb
from pb.api.services.tables import (
    column_lineage,
    get_default_namespace,
    get_table_detail,
    get_table_stats,
    impact_lineage,
    list_schemas,
    list_tables,
)


def _multi_namespace_conn() -> duckdb.DuckDBPyConnection:
    """Synthetic corpus: `clinicalaccession` defined identically in three
    schemas (the real-world case that motivated this) plus one table that
    only ever shows up via SQL usage, never in the DDL catalog at all."""
    conn = duckdb.connect(":memory:")
    conn.execute("CREATE TABLE catalog_columns (namespace TEXT, table_name TEXT, column_name TEXT, ordinal INTEGER)")
    conn.execute(
        "CREATE TABLE all_sql_tables "
        "(file TEXT, object TEXT, source TEXT, operation TEXT, table_name TEXT, proc_name TEXT, line INTEGER)"
    )
    conn.execute("CREATE TABLE objects (file TEXT, kind TEXT, object TEXT, ancestor TEXT)")
    conn.execute(
        "INSERT INTO catalog_columns VALUES "
        "('clims', 'clinicalaccession', 'id', 0), "
        "('clims_common', 'clinicalaccession', 'id', 0), "
        "('clims_archive', 'clinicalaccession', 'id', 0), "
        "('clims', 'patient', 'id', 0)"
    )
    conn.execute(
        "INSERT INTO all_sql_tables VALUES "
        "('f.srw', 'w_f', 'powerscript', 'select', 'clinicalaccession', 'p1', 1), "
        "('f.srw', 'w_f', 'powerscript', 'select', 'legacy_only', 'p2', 2)"
    )
    return conn


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


def test_list_schemas_single_default_namespace(db_conn: duckdb.DuckDBPyConnection):
    # db_conn has no --ddl, so catalog_columns is empty: the common single-
    # schema/no-DDL case must report zero real schemas, not error or crash.
    assert list_schemas(db_conn) == []


def test_list_schemas_empty_when_catalog_has_no_real_namespace():
    # A DDL catalog loaded without a --ddl schema tag (the common single-
    # schema case) has every row's namespace as NULL. That must report as
    # "no schema picker needed" (empty list), not a single null entry --
    # NULL isn't a navigable schema, it's the absence of one.
    conn = duckdb.connect(":memory:")
    conn.execute("CREATE TABLE catalog_columns (namespace TEXT, table_name TEXT, column_name TEXT, ordinal INTEGER)")
    conn.execute(
        "INSERT INTO catalog_columns VALUES (NULL, 't1', 'c1', 0), (NULL, 't1', 'c2', 1), (NULL, 't2', 'c1', 0)"
    )
    assert list_schemas(conn) == []


def test_list_schemas_multiple_namespaces_ranked_by_table_name():
    conn = _multi_namespace_conn()
    result = list_schemas(conn)
    assert result == [
        {"namespace": "clims", "table_count": 2},
        {"namespace": "clims_archive", "table_count": 1},
        {"namespace": "clims_common", "table_count": 1},
    ]


def test_list_tables_scoped_to_namespace_disambiguates_collisions():
    conn = _multi_namespace_conn()
    clims = list_tables(conn, namespace="clims")
    assert [t["table_name"] for t in clims] == ["clinicalaccession", "patient"]
    for t in clims:
        assert t["namespace"] == "clims"

    archive = list_tables(conn, namespace="clims_archive")
    assert [t["table_name"] for t in archive] == ["clinicalaccession"]
    # usage counts join on bare table_name (the SQL-usage index has no
    # namespace of its own), so the one all_sql_tables row for
    # clinicalaccession is visible from every namespace that defines it.
    assert archive[0]["ps_count"] == 1


def test_list_tables_unscoped_keeps_legacy_flat_behavior():
    conn = _multi_namespace_conn()
    result = list_tables(conn, namespace=None)
    assert {t["table_name"] for t in result} == {"clinicalaccession", "legacy_only"}
    assert all("namespace" not in t for t in result)


def test_get_table_detail_scoped_to_namespace():
    conn = _multi_namespace_conn()
    result = get_table_detail(conn, "clinicalaccession", namespace="clims_common")
    assert result is not None
    assert result["namespace"] == "clims_common"
    assert result["table_name"] == "clinicalaccession"


def test_get_table_detail_scoped_to_missing_namespace_is_not_found():
    conn = _multi_namespace_conn()
    assert get_table_detail(conn, "clinicalaccession", namespace="not_a_real_schema") is None


def test_get_table_stats(db_conn: duckdb.DuckDBPyConnection):
    result = get_table_stats(db_conn)
    assert "objects" in result
    assert "procedures" in result
    assert result["objects"] > 0
    assert result["procedures"] > 0
    assert "by_kind" in result
    assert "top_complex" in result
    assert "top_pagerank" in result


def test_get_default_namespace_returns_none_when_unset(db_conn: duckdb.DuckDBPyConnection):
    # db_conn's metadata table exists (setup_db_extras) but has no
    # default_namespace row -- the common single-schema corpus case.
    assert get_default_namespace(db_conn) is None


def test_get_default_namespace_returns_configured_value():
    conn = duckdb.connect(":memory:")
    conn.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT INTO metadata VALUES ('default_namespace', 'CLIMS')")
    assert get_default_namespace(conn) == "CLIMS"


def test_get_table_stats_includes_default_namespace_field(db_conn: duckdb.DuckDBPyConnection):
    result = get_table_stats(db_conn)
    assert "default_namespace" in result
    assert result["default_namespace"] is None


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
