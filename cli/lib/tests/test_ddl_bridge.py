"""Tests for the SQL bridge worker's "ddl" request kind (Plan 148 Phase 1a-3).

Mirrors test_sql_bridge.py's structure: spawn a real subprocess so the
framing and dispatch (kind="ddl" vs. the default "sql" kind) are verified
end-to-end.
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys

import pytest

_HEADER = struct.Struct(">I")


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


@pytest.fixture
def worker():
    proc = _worker()
    yield proc
    if proc.stdin:
        proc.stdin.close()
    proc.wait(timeout=5)


_DDL = """
CREATE TABLE afxfilter (
  kodfilter bigint(20) NOT NULL default '0',
  UNIQUE KEY afxfilter_x (kodfilter)
) ENGINE=InnoDB;

CREATE TABLE afxfilterd (
  kodfilterd bigint(20) NOT NULL default '0',
  kodfilter bigint(20) NOT NULL default '0',
  PRIMARY KEY  (kodfilterd),
  CONSTRAINT 0_15 FOREIGN KEY (kodfilter) REFERENCES afxfilter (kodfilter)
) ENGINE=InnoDB;
"""


def test_ddl_request_returns_catalog(worker):
    _send(worker, {"kind": "ddl", "ddl": _DDL, "dialect": "mysql"})
    resp = _recv(worker)
    assert resp["parse_ok"] is True
    tables = {t["table"] for t in resp["catalog"]["tables"]}
    assert tables == {"afxfilter", "afxfilterd"}
    fks = resp["catalog"]["foreign_keys"]
    assert len(fks) == 1
    assert fks[0]["from_table"] == "afxfilterd"
    assert fks[0]["to_table"] == "afxfilter"
    # Worker must still be alive and dispatch a plain "sql" request afterward
    _send(worker, {"sql": "SELECT 1 FROM dual", "dialect": "oracle"})
    resp2 = _recv(worker)
    assert resp2["parse_ok"] is True


def test_malformed_ddl_returns_parse_ok_false(worker):
    _send(worker, {"kind": "ddl", "ddl": "NOT VALID DDL !!!", "dialect": "mysql"})
    resp = _recv(worker)
    assert resp["parse_ok"] is False
    assert resp["catalog"] == {"tables": [], "primary_keys": [], "foreign_keys": []}
    assert worker.poll() is None
