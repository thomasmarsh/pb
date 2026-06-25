"""Tests for SQL mock mode in routes/sql.py."""

from __future__ import annotations

import os

import pytest


@pytest.fixture(autouse=True)
def enable_mock_mode():
    """Enable mock mode for each test and restore after."""
    old = os.environ.get("PB_SQL_MOCK")
    os.environ["PB_SQL_MOCK"] = "1"
    yield
    if old is None:
        os.environ.pop("PB_SQL_MOCK", None)
    else:
        os.environ["PB_SQL_MOCK"] = old


def test_mock_execute_returns_rows_for_known_table() -> None:
    from pb.api.routes.sql import _mock_execute
    resp = _mock_execute("SELECT * FROM misth_zpkrat WHERE kodxrisi = ?", ["0001"])
    assert resp.error is None
    assert len(resp.rows) > 0
    assert "kodkrat" in resp.columns


def test_mock_execute_returns_rows_for_afxtranslate() -> None:
    from pb.api.routes.sql import _mock_execute
    resp = _mock_execute("SELECT id, uk FROM afxtranslate", None)
    assert resp.error is None
    assert len(resp.rows) == 2
    assert resp.rows[0]["id"] == 655


def test_mock_execute_returns_empty_for_unknown_table() -> None:
    from pb.api.routes.sql import _mock_execute
    resp = _mock_execute("SELECT * FROM nonexistent_table", None)
    assert resp.error is None
    assert resp.rows == []
    assert resp.rowcount == 0


def test_execute_sql_dispatches_to_mock_in_mock_mode() -> None:
    from pb.api.routes.sql import SqlRequest, execute_sql
    body = SqlRequest(sql="SELECT * FROM misth_zpkrat", params=None)
    resp = execute_sql(body)
    assert resp.error is None
    assert len(resp.rows) > 0
