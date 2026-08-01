"""Unit tests for pb.api.services.diagnostics."""

from __future__ import annotations

import shutil

import duckdb
import pytest
from pb.api.services.diagnostics import get_error_source, list_errors


@pytest.fixture
def conn_with_errors(db_path, tmp_path_factory):
    tmp = tmp_path_factory.mktemp("db_errors")
    db_copy = str(tmp / "test_errors.duckdb")
    shutil.copy(db_path, db_copy)

    conn = duckdb.connect(db_copy)
    conn.execute(
        "INSERT INTO parse_errors VALUES (?,?,?)",
        ["a.srw", "lex error at line 3", 3],
    )
    conn.execute(
        "INSERT INTO parse_errors VALUES (?,?,?)",
        ["b.srw", "Invalid expression in SELECT", None],
    )
    yield conn
    conn.close()


def test_list_errors_returns_all(conn_with_errors):
    result = list_errors(conn_with_errors)
    assert result["total"] >= 2


def test_list_errors_search_by_message(conn_with_errors):
    result = list_errors(conn_with_errors, q="Invalid expression")
    assert result["total"] >= 1
    assert any(item["file"] == "b.srw" for item in result["items"])


def test_list_errors_pagination(conn_with_errors):
    result = list_errors(conn_with_errors, limit=1, offset=0)
    assert len(result["items"]) == 1
    result2 = list_errors(conn_with_errors, limit=1, offset=1)
    assert len(result2["items"]) == 1
    assert result["items"][0]["file"] != result2["items"][0]["file"]


def test_get_error_source_reads_source_files_table(conn_with_errors):
    conn_with_errors.execute(
        "INSERT INTO source_files VALUES (?,?)", ["__synthetic__.srw", "select 1\nfrom dual"]
    )
    result = get_error_source(conn_with_errors, "__synthetic__.srw")
    assert result["lines"] == ["select 1", "from dual"]


def test_get_error_source_unknown_file_returns_empty(conn_with_errors):
    result = get_error_source(conn_with_errors, "__no_such_file__.srw")
    assert result["lines"] == []
