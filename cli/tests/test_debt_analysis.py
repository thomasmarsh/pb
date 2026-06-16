"""Unit tests for the pure analysis functions in shell/commands/debt.py."""

import json
from pathlib import Path

from pb_cli.shell.commands.debt import (
    BsRawStats,
    DwStats,
    _analyze_bsraw,
    _analyze_dw,
    _pct,
)


def _write_json(out_dir: Path, obj: dict, name: str = "test.json"):
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / name).write_text(json.dumps(obj))


def test_analyze_bsraw_empty(tmp_path):
    s = _analyze_bsraw(tmp_path)
    assert s.bsraw_total == 0
    assert s.exraw_total == 0


def test_analyze_bsraw_counts(tmp_path):
    _write_json(
        tmp_path,
        {
            "functions": [
                {
                    "body": [
                        {"tag": "BsRaw", "contents": "SELECT * FROM t"},
                        {"tag": "BsRaw", "contents": "if x > 0 then"},
                    ]
                }
            ]
        },
    )
    s = _analyze_bsraw(tmp_path)
    assert s.bsraw_total == 2
    assert s.counts["sql"] == 1
    assert s.counts["ctrl"] == 1


def test_analyze_bsraw_other_category(tmp_path):
    _write_json(
        tmp_path,
        {
            "functions": [
                {
                    "body": [
                        {"tag": "BsRaw", "contents": "MessageBox('hello')"},
                    ]
                }
            ]
        },
    )
    s = _analyze_bsraw(tmp_path)
    assert s.counts["other"] == 1
    assert "messagebox('hello')" in s.other


def test_analyze_bsraw_exraw(tmp_path):
    _write_json(
        tmp_path,
        {
            "functions": [
                {
                    "body": [
                        {"tag": "BsCall", "contents": {"tag": "ExRaw", "contents": ["foo", "bar"]}},
                    ]
                }
            ]
        },
    )
    s = _analyze_bsraw(tmp_path)
    assert s.exraw_total == 1


def test_analyze_dw_empty(tmp_path):
    s = _analyze_dw(tmp_path)
    assert s.files == 0
    assert s.total == 0


def test_analyze_dw_counts(tmp_path):
    _write_json(
        tmp_path,
        {
            "kind": "datawindow",
            "controls": [
                {"name": "col_1", "type": "column", "band": "detail", "x": 10, "y": 20, "width": 100, "height": 24},
                {"name": "text_1", "type": "text", "band": "header", "x": 0, "y": 0, "width": 200, "height": 24},
            ],
        },
    )
    s = _analyze_dw(tmp_path)
    assert s.files == 1
    assert s.total == 2
    assert s.types["column"] == 1
    assert s.types["text"] == 1


def test_analyze_dw_skips_non_dw(tmp_path):
    _write_json(
        tmp_path,
        {
            "kind": "powerscript",
            "functions": [],
        },
        name="ps.json",
    )
    s = _analyze_dw(tmp_path)
    assert s.files == 0


def test_pct():
    assert _pct(50, 100) == " 50.0%"
    assert _pct(0, 0) == "   n/a"
    assert _pct(1, 3) == " 33.3%"


def test_bsraw_stats_defaults():
    s = BsRawStats()
    assert s.bsraw_total == 0
    assert s.exraw_total == 0


def test_dw_stats_defaults():
    s = DwStats()
    assert s.files == 0
    assert s.total == 0
