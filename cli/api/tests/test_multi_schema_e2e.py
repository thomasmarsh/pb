"""End-to-end regression tests for Plan 157 (default-namespace resolution)
against a real multi-schema reindex — `multi_schema_db_conn` (see
`cli/conftest.py`) runs the actual `pbc` binary over OpenPay tagged as two
DDL schemas (`OPENPAY`, and a synthetic `OPENPAY_ARCHIVE` redefining
`misth_zpkrat`), not a hand-built DuckDB fixture. `test_tables_service.py`'s
`_multi_namespace_conn()` already covers the Phase 2 query-layer logic at
the unit level; this file exists because that fixture can never catch a bug
in the *pipeline* itself (parsing, DDL ingestion, `buildSchema` resolution,
CLI-argument threading) — exactly the class of bug this fixture found on
its first real run (see the `--default-namespace` case-sensitivity fix,
`PB.Analysis.SchemaCategory.resolveTableRef` and `pb.pipeline.pipeline.run`).
"""

from __future__ import annotations

import duckdb
from pb.api.services.schema import get_column_affinity, get_decomposition_candidates
from pb.api.services.tables import (
    get_default_namespace,
    get_table_detail,
    list_schemas,
    list_tables,
)


def test_default_namespace_is_openpay(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_default_namespace(multi_schema_db_conn) == "openpay"


def test_list_schemas_shows_both_namespaces(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    schemas = {s["namespace"]: s["table_count"] for s in list_schemas(multi_schema_db_conn)}
    assert schemas.keys() == {"openpay", "openpay_archive"}
    # openpay carries OpenPay's real ~30-table DDL; the archive schema is
    # the synthetic single-table fixture (schema-archive.sql).
    assert schemas["openpay"] > 1
    assert schemas["openpay_archive"] == 1


def test_misth_zpkrat_exists_under_both_namespaces(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    assert get_table_detail(multi_schema_db_conn, "misth_zpkrat", namespace="openpay") is not None
    assert get_table_detail(multi_schema_db_conn, "misth_zpkrat", namespace="openpay_archive") is not None


def test_default_namespace_table_shows_real_usage(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    # misth_zpkrat has real embedded-SQL/DW-retrieve usage in OpenPay's real
    # source (w_misth_zpkrat_form.srw, uo_misth_zpkrat_sel.sru, etc.) --
    # scoped to the default namespace, that usage must show up for real.
    detail = get_table_detail(multi_schema_db_conn, "misth_zpkrat", namespace="openpay")
    assert detail is not None
    assert detail["dw_count"] > 0 or detail["ps_count"] > 0


def test_non_default_namespace_table_shows_honest_zero_usage(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    # Phase 2's current gate: a real table that exists in a non-default
    # schema, with no source anywhere explicitly qualifying it to that
    # schema, must show zero usage -- not borrow openpay's real usage just
    # because the bare table name matches. (Superseded by Plan 157 Phase
    # 4.5's real per-reference resolution once that lands -- this pins
    # today's documented, intentional interim behavior.)
    detail = get_table_detail(multi_schema_db_conn, "misth_zpkrat", namespace="openpay_archive")
    assert detail is not None
    assert detail["dw_count"] == 0
    assert detail["ps_count"] == 0


def test_list_tables_scoped_to_default_namespace_has_real_usage(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    tables = {t["table_name"]: t for t in list_tables(multi_schema_db_conn, namespace="openpay")}
    assert "misth_zpkrat" in tables
    assert tables["misth_zpkrat"]["dw_count"] > 0 or tables["misth_zpkrat"]["ps_count"] > 0


def test_list_tables_scoped_to_archive_namespace_has_zero_usage(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    tables = {t["table_name"]: t for t in list_tables(multi_schema_db_conn, namespace="openpay_archive")}
    assert "misth_zpkrat" in tables
    assert tables["misth_zpkrat"]["dw_count"] == 0
    assert tables["misth_zpkrat"]["ps_count"] == 0


def test_column_affinity_resolves_for_default_namespace_copy(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    # This is the original bug-report regression: before Plan 157 Phase 1,
    # buildSchema never unified a DDL-tagged ColumnObj with the real
    # unqualified-SQL legs, so this always came back empty for any
    # namespace-tagged table -- even though misth_zpkrat has plenty of real
    # embedded-SQL usage in a single-schema build (schema_db_conn).
    result = get_column_affinity(multi_schema_db_conn, "openpay", "misth_zpkrat")
    assert result is not None
    assert len(result["columns"]) > 0
    assert any(sum(row) > 0 for row in result["co_access_matrix"])


def test_column_affinity_empty_for_archive_namespace_copy(multi_schema_db_conn: duckdb.DuckDBPyConnection):
    # The archive copy is real (exists in the DDL catalog) but has zero
    # legs -- distinct from "table not found" (get_column_affinity returns
    # None only when the catalog has no row at all).
    result = get_column_affinity(multi_schema_db_conn, "openpay_archive", "misth_zpkrat")
    assert result is not None
    assert result["columns"] == []


def test_decomposition_candidates_available_for_default_namespace_copy(
    multi_schema_db_conn: duckdb.DuckDBPyConnection,
):
    result = get_decomposition_candidates(multi_schema_db_conn, "openpay", "misth_zpkrat")
    assert result is not None
