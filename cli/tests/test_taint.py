"""Tests for taint analysis bulk-insert from Haskell-produced JSON."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pb_cli.shell.taint import (
    _bulk_insert_taint_annotations,
    _bulk_insert_taint_paths,
    _bulk_insert_taint_sinks,
    _bulk_insert_taint_sources,
)


class _FakeConn:
    """Minimal stand-in for DuckDB connection — accepts execute calls without error."""
    def execute(self, sql: str, params: Any = None) -> Any:  # noqa: ARG002
        return self
    def fetchall(self) -> list:
        return []


class TestBulkInsertTaintSources:
    def test_loads_from_json(self, tmp_path: Path) -> None:
        data = [
            {"file": "w.srf", "object": "oa", "proc_name": "pA",
             "var_name": "ls_result", "source_type": "db_read", "line": 5},
        ]
        (tmp_path / "taint_sources.json").write_text(json.dumps(data))
        _bulk_insert_taint_sources(_FakeConn(), tmp_path)  # type: ignore[arg-type]

    def test_missing_file_noop(self, tmp_path: Path) -> None:
        _bulk_insert_taint_sources(_FakeConn(), tmp_path)  # type: ignore[arg-type]


class TestBulkInsertTaintSinks:
    def test_loads_from_json(self, tmp_path: Path) -> None:
        data = [
            {"file": "w.srf", "object": "oa", "proc_name": "pA",
             "var_name": "ls_val", "sink_type": "db_write", "severity": "high", "line": 15},
        ]
        (tmp_path / "taint_sinks.json").write_text(json.dumps(data))
        _bulk_insert_taint_sinks(_FakeConn(), tmp_path)  # type: ignore[arg-type]


class TestBulkInsertTaintPaths:
    def test_loads_from_json(self, tmp_path: Path) -> None:
        data = [
            {
                "source": {"file": "w.srf", "object": "oa", "proc_name": "pA",
                           "var_name": "ls_val", "source_type": "db_read", "line": 5},
                "sink": {"file": "w.srf", "object": "oa", "proc_name": "pA",
                         "var_name": "ls_val", "sink_type": "db_write", "severity": "high", "line": 10},
                "steps": [
                    {"object": "oa", "proc_name": "pA", "var_name": "ls_val",
                     "line": 5, "step_kind": "source", "description": "taint source: db_read"},
                    {"object": "oa", "proc_name": "pA", "var_name": "ls_val",
                     "line": 10, "step_kind": "sink", "description": "taint sink: db_write"},
                ],
                "severity": "high",
                "category": "sql_injection",
            },
        ]
        (tmp_path / "taint_paths.json").write_text(json.dumps(data))
        _bulk_insert_taint_paths(_FakeConn(), tmp_path)  # type: ignore[arg-type]


class TestBulkInsertTaintAnnotations:
    def test_loads_from_json(self, tmp_path: Path) -> None:
        data = [
            {"file": "w.srf", "object": "oa", "proc_name": "pA", "block_id": "b0",
             "is_taint_entry": True, "is_taint_sink": False, "tainted_vars": ["ls_val"]},
        ]
        (tmp_path / "taint_annotations.json").write_text(json.dumps(data))
        _bulk_insert_taint_annotations(_FakeConn(), tmp_path)  # type: ignore[arg-type]
