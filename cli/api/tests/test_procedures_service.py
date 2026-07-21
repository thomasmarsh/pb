"""Unit tests for pb.api.services.procedures."""

from __future__ import annotations

import duckdb
from pb.api.services.procedures import get_procedure_detail


def test_get_procedure_detail_includes_linking_context(db_conn: duckdb.DuckDBPyConnection):
    """fn_perm calls fn_sqlerror — the narrowed procedure view needs the same
    knownProcs/knownObjects/localSymbols data as the whole-file view so that
    call and identifier links render, not just plain text."""
    result = get_procedure_detail(db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert "knownObjects" in result
    assert "knownProcs" in result
    assert "localSymbols" in result
    known_proc_names = {p["name"] for p in result["knownProcs"]}
    assert "fn_sqlerror" in known_proc_names


def test_get_procedure_detail_local_symbols_scoped_to_proc(db_conn: duckdb.DuckDBPyConnection):
    """Every symbol either belongs to fn_perm itself or is an instance var
    (scope == "instance", empty proc_name) visible from every procedure body."""
    result = get_procedure_detail(db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert len(result["localSymbols"]) > 0
    assert all(
        s["proc_name"] == "fn_perm" or s["scope"] == "instance"
        for s in result["localSymbols"]
    )


def test_get_procedure_detail_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_procedure_detail(db_conn, "__nonexistent__", "__nonexistent__") is None
