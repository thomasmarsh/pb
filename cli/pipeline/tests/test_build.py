"""Unit tests for pb.pipeline.build's ancestor-search helpers.

Regression coverage for a real bug (2026-07-09): find_sql_worker's original
hardcoded parent-count (3) undershot cli/.venv by 2 levels, so the direct
lookup always silently missed and fell through to a PATH-based fallback
that only worked if the venv happened to be activated -- meaning
`pb index --ddl` could silently skip DDL ingestion entirely with only an
easy-to-miss warning, no hard failure.
"""

from __future__ import annotations

from pathlib import Path

from pb.pipeline.build import _find_ancestor_containing, find_sql_worker


def test_find_ancestor_containing_finds_marker_in_start_dir(tmp_path: Path):
    (tmp_path / "marker.txt").write_text("x")
    assert _find_ancestor_containing(tmp_path, Path("marker.txt")) == tmp_path


def test_find_ancestor_containing_walks_up_multiple_levels(tmp_path: Path):
    (tmp_path / "marker_dir").mkdir()
    (tmp_path / "marker_dir" / "marker.txt").write_text("x")
    deep = tmp_path / "a" / "b" / "c"
    deep.mkdir(parents=True)
    assert _find_ancestor_containing(deep, Path("marker_dir") / "marker.txt") == tmp_path


def test_find_ancestor_containing_returns_none_when_absent(tmp_path: Path):
    assert _find_ancestor_containing(tmp_path, Path("nonexistent_marker")) is None


def test_find_sql_worker_locates_real_installed_script():
    # The actual repo's cli/.venv should have pb-sql-worker installed --
    # this is the exact real-world case the parent-count bug broke.
    result = find_sql_worker()
    assert result is not None
    assert result.name == "pb-sql-worker"
    assert result.exists()
