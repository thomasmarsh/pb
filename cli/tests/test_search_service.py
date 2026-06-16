"""Unit tests for pb_cli.explorer.services.search."""

from __future__ import annotations

import duckdb

from pb_cli.explorer.services.search import global_search


def test_global_search_returns_all_categories(db_conn: duckdb.DuckDBPyConnection):
    result = global_search(db_conn, "fn_sqlerror")
    assert "objects" in result
    assert "procedures" in result
    assert "datawindows" in result
    assert "tables" in result
    assert isinstance(result["objects"], list)
    assert isinstance(result["procedures"], list)


def test_global_search_case_insensitive(db_conn: duckdb.DuckDBPyConnection):
    r1 = global_search(db_conn, "fn_sqlerror")
    r2 = global_search(db_conn, "FN_SQLERROR")
    assert len(r1["objects"]) == len(r2["objects"])


def test_global_search_empty_result(db_conn: duckdb.DuckDBPyConnection):
    result = global_search(db_conn, "__zzz_nonexistent_zzz__")
    assert result["objects"] == []
    assert result["procedures"] == []
    assert result["datawindows"] == []
    assert result["tables"] == []
