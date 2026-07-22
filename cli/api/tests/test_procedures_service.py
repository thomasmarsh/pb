"""Unit tests for pb.api.services.procedures."""

from __future__ import annotations

import duckdb
from pb.api.services.procedures import get_procedure_detail


def test_get_procedure_detail_includes_linking_context(db_conn: duckdb.DuckDBPyConnection):
    """fn_perm calls fn_sqlerror — the narrowed procedure view needs the same
    knownObjects/resolvedCalls/resolvedVarRefs data as the whole-file view so
    that call and identifier links render, not just plain text."""
    result = get_procedure_detail(db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert "knownObjects" in result
    assert "resolvedCalls" in result
    assert "resolvedVarRefs" in result
    called_names = {c["to_name"] for c in result["resolvedCalls"]}
    assert "fn_sqlerror" in called_names


def test_get_procedure_detail_var_refs_scoped_to_proc(db_conn: duckdb.DuckDBPyConnection):
    """Every var ref belongs to fn_perm itself -- resolved_var_refs is
    per-occurrence, so even instance-var reads carry their real proc_name,
    unlike the old declaration-shaped resolved_types scoping."""
    result = get_procedure_detail(db_conn, "fn_perm", "fn_perm")
    assert result is not None
    assert len(result["resolvedVarRefs"]) > 0
    assert all(r["proc_name"] == "fn_perm" for r in result["resolvedVarRefs"])


def test_get_procedure_detail_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_procedure_detail(db_conn, "__nonexistent__", "__nonexistent__") is None
