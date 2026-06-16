"""Unit tests for pb_cli.explorer.services.objects."""

from __future__ import annotations

import duckdb

from pb_cli.explorer.services.objects import (
    get_explore_tree,
    get_object_detail,
    get_object_source,
    pbl_name,
)


def test_pbl_name_extracts_library():
    assert pbl_name("repo/mylib.pbl/w_obj.srw") == "mylib.pbl"


def test_pbl_name_fallback_to_parent():
    assert pbl_name("repo/objects/w_obj.srw") == "objects"


def test_pbl_name_unknown():
    assert pbl_name("single") == "(unknown)"


def test_get_object_detail_returns_dict(db_conn: duckdb.DuckDBPyConnection):
    result = get_object_detail(db_conn, "fn_sqlerror")
    assert result is not None
    assert result["name"] == "fn_sqlerror"
    assert "procedures" in result
    assert "metrics" in result
    assert "ancestors" in result
    assert "descendants" in result
    assert "callers" in result
    assert "callees" in result
    assert isinstance(result["procedures"], list)


def test_get_object_detail_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_detail(db_conn, "__nonexistent__") is None


def test_get_object_source_returns_dict(db_conn: duckdb.DuckDBPyConnection):
    result = get_object_source(db_conn, "fn_sqlerror")
    assert result is not None
    assert "file" in result
    assert "lines" in result
    assert "procedures" in result
    assert "knownObjects" in result
    assert "knownProcs" in result
    assert isinstance(result["lines"], list)


def test_get_object_source_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_source(db_conn, "__nonexistent__") is None


def test_get_explore_tree(db_conn: duckdb.DuckDBPyConnection):
    result = get_explore_tree(db_conn)
    assert "libraries" in result
    assert isinstance(result["libraries"], list)
    assert len(result["libraries"]) > 0
    lib = result["libraries"][0]
    assert "name" in lib
    assert "objects" in lib
    if lib["objects"]:
        obj = lib["objects"][0]
        assert "procedures" in obj
        assert isinstance(obj["procedures"], list)
