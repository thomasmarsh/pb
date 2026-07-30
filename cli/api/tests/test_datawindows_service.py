"""Unit tests for pb.api.services.datawindows (Plan 198 Phase E: dw_arguments)."""

from __future__ import annotations

import shutil

import duckdb
import pytest
from pb.api.services.datawindows import get_dw_detail


def _any_dw_object_without_arguments(conn: duckdb.DuckDBPyConnection) -> str:
    """A DW object with zero declared retrieve arguments -- deterministic
    (some openpay DataWindows do have real dw_arguments rows; an unordered
    `LIMIT 1` over all DW objects can land on either kind)."""
    row = conn.execute(
        "SELECT DISTINCT dc.object FROM dw_controls dc "
        "WHERE NOT EXISTS (SELECT 1 FROM dw_arguments da WHERE da.object = dc.object) "
        "ORDER BY dc.object LIMIT 1"
    ).fetchone()
    assert row is not None, "expected at least one argument-free DataWindow in the test corpus"
    return row[0]


def test_get_dw_detail_arguments_field_present_for_real_dw_without_declared_args(
    db_conn: duckdb.DuckDBPyConnection,
):
    """Exercises the real dw_arguments query returning an empty list without
    raising for a DW that declares no retrieve arguments -- the bug Finding 6
    (doc/plan/198) describes was that the query was silently swallowed by a
    try/except, not that it raised."""
    name = _any_dw_object_without_arguments(db_conn)
    result = get_dw_detail(db_conn, name)
    assert result["arguments"] == []


@pytest.fixture(scope="module")
def dw_args_conn(db_path, tmp_path_factory):
    """A copy of the real DB with synthetic dw_arguments rows, out of ordinal
    order, to prove the query orders by ordinal rather than insertion/name order."""
    tmp = tmp_path_factory.mktemp("db_dw_args")
    db_copy = str(tmp / "test_dw_args.duckdb")
    shutil.copy(db_path, db_copy)

    conn = duckdb.connect(db_copy)
    conn.execute(
        "INSERT INTO dw_arguments (file, object, arg_name, arg_type, ordinal) VALUES (?,?,?,?,?)",
        ["", "dw_synth_args", "as_of_date", "date", 1],
    )
    conn.execute(
        "INSERT INTO dw_arguments (file, object, arg_name, arg_type, ordinal) VALUES (?,?,?,?,?)",
        ["", "dw_synth_args", "customer_id", "number", 0],
    )
    conn.close()

    ro = duckdb.connect(db_copy, read_only=True)
    yield ro
    ro.close()


def test_get_dw_detail_arguments_ordered_by_ordinal_not_insertion_or_name(
    dw_args_conn: duckdb.DuckDBPyConnection,
):
    result = get_dw_detail(dw_args_conn, "dw_synth_args")
    assert result["arguments"] == [
        {"arg_name": "customer_id", "arg_type": "number"},
        {"arg_name": "as_of_date", "arg_type": "date"},
    ]
