"""Tests for the SQL bridge worker (pb_cli/bridge/sql_worker.py).

The worker communicates via length-prefixed JSON over stdin/stdout. Each test
spawns a real subprocess so the framing and lifecycle are verified end-to-end.
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys

import pytest
from pb.lib.sql import parse_pb_sql

_HEADER = struct.Struct(">I")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _send(proc: subprocess.Popen, obj: dict) -> None:
    body = json.dumps(obj).encode("utf-8")
    proc.stdin.write(_HEADER.pack(len(body)))  # type: ignore[arg-type]
    proc.stdin.write(body)  # type: ignore[arg-type]
    proc.stdin.flush()  # type: ignore[union-attr]


def _recv(proc: subprocess.Popen) -> dict:
    header = proc.stdout.read(4)  # type: ignore[union-attr]
    assert len(header) == 4, "worker closed stdout unexpectedly"
    (length,) = _HEADER.unpack(header)
    body = proc.stdout.read(length)  # type: ignore[union-attr]
    return json.loads(body)


def _worker() -> subprocess.Popen:
    return subprocess.Popen(
        [sys.executable, "-m", "pb.pipeline.bridge.sql_worker"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def worker():
    proc = _worker()
    yield proc
    # Ensure clean shutdown even if the test fails
    if proc.stdin:
        proc.stdin.close()
    proc.wait(timeout=5)


# ---------------------------------------------------------------------------
# Test: 10 valid requests; responses match parse_pb_sql directly
# ---------------------------------------------------------------------------

_SQL_SAMPLES = [
    "SELECT cust_name INTO :ls_name FROM customer WHERE cust_id = :li_id",
    "SELECT o.order_id, c.cust_name INTO :li_order, :ls_name FROM orders o JOIN customer c ON o.cust_id = c.cust_id",
    "SELECT count(*) FROM invoice WHERE invoice_date >= :ld_from",
    "UPDATE customer SET cust_name = :ls_name WHERE cust_id = :li_id",
    "DELETE FROM log_entries WHERE entry_date < :ld_cutoff",
    "INSERT INTO audit_log (action, user_id) VALUES (:ls_action, :li_user)",
    "SELECT * FROM product WHERE category = :ls_cat AND active = 1",
    "SELECT p.*, s.qty FROM product p JOIN stock s ON p.id = s.product_id",
    "UPDATE order_line SET qty = :li_qty WHERE line_id = :li_line",
    "SELECT max(order_id) INTO :li_max FROM orders",
]


def test_ten_valid_requests(worker):
    for sql in _SQL_SAMPLES:
        _send(worker, {"sql": sql, "dialect": "oracle"})
        resp = _recv(worker)

        _parsed, tables, columns, meta = parse_pb_sql(sql, "oracle")
        expected_parse_ok = _parsed is not None

        assert resp["parse_ok"] == expected_parse_ok, f"parse_ok mismatch for: {sql!r}"
        assert resp["operation"] == meta["operation"]
        assert sorted(resp["tables"]) == sorted(tables)
        assert sorted(resp["columns"]) == sorted(columns)


# ---------------------------------------------------------------------------
# Test: malformed SQL returns parse_ok=false without crashing the worker
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sql", [
    "SELECT FROM WHERE",
    "NOT VALID SQL AT ALL !!!",
    "",
    "   ",
])
def test_malformed_sql_returns_parse_ok_false(worker, sql):
    _send(worker, {"sql": sql, "dialect": "oracle"})
    resp = _recv(worker)
    assert resp["parse_ok"] is False
    assert isinstance(resp["tables"], list)
    assert isinstance(resp["columns"], list)
    # Worker must still be alive for the next request
    assert worker.poll() is None


# ---------------------------------------------------------------------------
# Test: close stdin; worker exits cleanly with code 0
# ---------------------------------------------------------------------------


def test_worker_exits_cleanly_on_stdin_close():
    proc = _worker()
    proc.stdin.close()  # type: ignore[union-attr]
    code = proc.wait(timeout=5)
    assert code == 0, f"worker exited with non-zero code {code}"
