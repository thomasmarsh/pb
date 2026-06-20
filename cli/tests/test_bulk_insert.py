"""Tests for bulk_insert — verifying round-trip fidelity across column types."""

from __future__ import annotations

import json

import duckdb
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from pb_cli.shell.bulk import bulk_insert


@pytest.fixture()
def mem():
    conn = duckdb.connect(":memory:")
    yield conn
    conn.close()


# ---------------------------------------------------------------------------
# Basic types
# ---------------------------------------------------------------------------


def test_text_roundtrip(mem):
    mem.execute("CREATE TABLE t (a TEXT, b TEXT)")
    bulk_insert(mem, "t", ["a", "b"], [("hello", "world")])
    assert mem.execute("SELECT a, b FROM t").fetchone() == ("hello", "world")


def test_int_roundtrip(mem):
    mem.execute("CREATE TABLE t (a INT, b INT)")
    bulk_insert(mem, "t", ["a", "b"], [(42, -7)])
    assert mem.execute("SELECT a, b FROM t").fetchone() == (42, -7)


def test_bool_roundtrip(mem):
    mem.execute("CREATE TABLE t (a BOOLEAN, b BOOLEAN)")
    bulk_insert(mem, "t", ["a", "b"], [(True, False)])
    assert mem.execute("SELECT a, b FROM t").fetchone() == (True, False)


def test_null_roundtrip(mem):
    mem.execute("CREATE TABLE t (a TEXT, b INT, c BOOLEAN)")
    bulk_insert(mem, "t", ["a", "b", "c"], [(None, None, None)])
    row = mem.execute("SELECT a, b, c FROM t").fetchone()
    assert row == (None, None, None)


def test_empty_rows_is_noop(mem):
    mem.execute("CREATE TABLE t (a TEXT)")
    bulk_insert(mem, "t", ["a"], [])
    assert mem.execute("SELECT COUNT(*) FROM t").fetchone()[0] == 0


def test_multiple_rows(mem):
    mem.execute("CREATE TABLE t (a TEXT, b INT)")
    rows = [("x", 1), ("y", 2), ("z", 3)]
    bulk_insert(mem, "t", ["a", "b"], rows)
    result = mem.execute("SELECT a, b FROM t ORDER BY b").fetchall()
    assert result == rows


# ---------------------------------------------------------------------------
# TEXT column holding a JSON string — the critical case for body_json / parsed_json
#
# body_json and parsed_json are stored as TEXT (not JSON column type) because
# DuckDB's COPY FROM NDJSON double-encodes Python strings written to JSON columns:
# the string gets stored as a JSON string value, so SELECT returns '"[{...}]"'
# (with outer quotes), requiring a second json.loads to get the actual structure.
# TEXT columns store the string byte-for-byte — round-trip is exact.
# ---------------------------------------------------------------------------


def test_text_json_blob_roundtrip(mem):
    """A TEXT column receiving a body_json string stores and returns it exactly."""
    mem.execute("CREATE TABLE t (j TEXT)")
    payload = '[{"tag": "BsAssign"}, {"tag": "BsReturn"}]'
    bulk_insert(mem, "t", ["j"], [(payload,)])
    val = mem.execute("SELECT j FROM t").fetchone()[0]
    assert isinstance(val, str)
    parsed = json.loads(val)
    assert isinstance(parsed, list)
    assert len(parsed) == 2
    assert parsed[0]["tag"] == "BsAssign"


def test_text_json_blob_null(mem):
    mem.execute("CREATE TABLE t (j TEXT)")
    bulk_insert(mem, "t", ["j"], [(None,)])
    assert mem.execute("SELECT j FROM t").fetchone()[0] is None


def test_text_json_blob_nested_quotes(mem):
    """body_json with embedded quotes and backslashes round-trips cleanly via TEXT."""
    mem.execute("CREATE TABLE t (j TEXT)")
    inner = '{"tag": "BsRaw", "contents": "foo \\"bar\\" baz"}'
    payload = f"[{inner}]"
    bulk_insert(mem, "t", ["j"], [(payload,)])
    val = mem.execute("SELECT j FROM t").fetchone()[0]
    parsed = json.loads(val)
    assert isinstance(parsed, list)
    assert parsed[0]["tag"] == "BsRaw"
    assert "bar" in parsed[0]["contents"]


def test_located_bodystmt_structure(mem):
    """A realistic body_json (TEXT) list of Located BodyStmt dicts survives the round-trip."""
    mem.execute("CREATE TABLE t (j TEXT)")
    body = [
        {"line": 10, "node": {"tag": "BsAssign", "contents": [{"segments": [{"name": "x", "subscript": None}]}, {"tag": "ExLit", "contents": {"tag": "LitInt", "contents": "1"}}]}},
        {"line": 11, "node": {"tag": "BsReturn", "contents": None}},
    ]
    payload = json.dumps(body)
    bulk_insert(mem, "t", ["j"], [(payload,)])
    val = mem.execute("SELECT j FROM t").fetchone()[0]
    parsed = json.loads(val)
    assert isinstance(parsed, list)
    assert len(parsed) == 2
    # Each element must be a dict — this is what cfg_builder expects
    assert all(isinstance(stmt, dict) for stmt in parsed), (
        f"Expected list of dicts, got: {[type(s).__name__ for s in parsed]}"
    )
    assert parsed[0]["line"] == 10
    assert parsed[0]["node"]["tag"] == "BsAssign"


# ---------------------------------------------------------------------------
# TEXT[] column — for sql_statements.tables / .columns
# ---------------------------------------------------------------------------


def test_text_array_roundtrip(mem):
    mem.execute("CREATE TABLE t (arr TEXT[])")
    bulk_insert(mem, "t", ["arr"], [(["foo", "bar", "baz"],)])
    val = mem.execute("SELECT arr FROM t").fetchone()[0]
    assert val == ["foo", "bar", "baz"]


def test_text_array_null(mem):
    mem.execute("CREATE TABLE t (arr TEXT[])")
    bulk_insert(mem, "t", ["arr"], [(None,)])
    assert mem.execute("SELECT arr FROM t").fetchone()[0] is None


def test_text_array_empty(mem):
    mem.execute("CREATE TABLE t (arr TEXT[])")
    bulk_insert(mem, "t", ["arr"], [([], )])
    val = mem.execute("SELECT arr FROM t").fetchone()[0]
    assert val == []


# ---------------------------------------------------------------------------
# Large values (pathological scale)
# ---------------------------------------------------------------------------


def test_large_text_value(mem):
    """A TEXT column with 100KB of content round-trips cleanly."""
    mem.execute("CREATE TABLE t (a TEXT)")
    big = "x" * 100_000
    bulk_insert(mem, "t", ["a"], [(big,)])
    val = mem.execute("SELECT a FROM t").fetchone()[0]
    assert val == big


def test_large_json_body(mem):
    """A TEXT column with a 500-statement body_json blob round-trips correctly."""
    mem.execute("CREATE TABLE t (j TEXT)")
    body = [{"line": i, "node": {"tag": "BsAssign"}} for i in range(500)]
    payload = json.dumps(body)
    bulk_insert(mem, "t", ["j"], [(payload,)])
    val = mem.execute("SELECT j FROM t").fetchone()[0]
    parsed = json.loads(val)
    assert len(parsed) == 500
    assert all(isinstance(s, dict) for s in parsed)


def test_many_rows(mem):
    """10K rows insert cleanly — stress test for NDJSON file path."""
    mem.execute("CREATE TABLE t (a TEXT, b INT)")
    rows = [(f"file_{i}", i) for i in range(10_000)]
    bulk_insert(mem, "t", ["a", "b"], rows)
    assert mem.execute("SELECT COUNT(*) FROM t").fetchone()[0] == 10_000


# ---------------------------------------------------------------------------
# Property-based tests (Hypothesis)
# ---------------------------------------------------------------------------

# Printable text that avoids Hypothesis-generated bytes DuckDB can't round-trip
_text = st.text(alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd", "P", "Zs")), max_size=200)
_opt_text = st.one_of(st.none(), _text)
_opt_int = st.one_of(st.none(), st.integers(min_value=-2**31, max_value=2**31 - 1))
_opt_bool = st.one_of(st.none(), st.booleans())


@given(a=_opt_text, b=_opt_int, c=_opt_bool)
@settings(max_examples=200)
def test_pbt_mixed_types_roundtrip(a, b, c):
    """TEXT / INT / BOOLEAN / NULL values survive bulk_insert round-trip."""
    conn = duckdb.connect(":memory:")
    try:
        conn.execute("CREATE TABLE t (a TEXT, b INT, c BOOLEAN)")
        bulk_insert(conn, "t", ["a", "b", "c"], [(a, b, c)])
        row = conn.execute("SELECT a, b, c FROM t").fetchone()
        assert row == (a, b, c)
    finally:
        conn.close()


@given(payload=_text)
@settings(max_examples=100)
def test_pbt_text_json_blob_roundtrip(payload):
    """Arbitrary text stored in a TEXT column returns byte-for-byte identical."""
    conn = duckdb.connect(":memory:")
    try:
        conn.execute("CREATE TABLE t (j TEXT)")
        bulk_insert(conn, "t", ["j"], [(payload,)])
        row = conn.execute("SELECT j FROM t").fetchone()
        assert row is not None
        val = row[0]
        assert val == payload
    finally:
        conn.close()


@given(rows=st.lists(st.tuples(_text, _opt_int), min_size=0, max_size=1000))
@settings(max_examples=50)
def test_pbt_row_count_preserved(rows):
    """Row count after bulk_insert equals the number of rows supplied."""
    conn = duckdb.connect(":memory:")
    try:
        conn.execute("CREATE TABLE t (a TEXT, b INT)")
        bulk_insert(conn, "t", ["a", "b"], rows)
        row = conn.execute("SELECT COUNT(*) FROM t").fetchone()
        assert row is not None
        count = row[0]
        assert count == len(rows)
    finally:
        conn.close()
