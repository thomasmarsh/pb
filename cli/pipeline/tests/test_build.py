"""Unit tests for pb.pipeline.build's ancestor-search helper.

SQL-bridge-worker discovery (formerly find_sql_worker in this module) was
removed 2026-07-09: it tried to locate an *installed* pb-sql-worker
console-script shim, which went through two failed designs (a hardcoded
ancestor parent-count, then a `.venv`-named-directory ancestor walk, then
sysconfig.get_path("scripts")) and kept failing on deployments that didn't
match the assumed layout. The real fix was to stop discovering an installed
artifact at all: pb.pipeline.pipeline.run() now passes sys.executable
(always defined, no discovery needed) and pbc launches the bridge worker as
`sys.executable -m pb.pipeline.bridge.sql_worker` -- the checked-in module's
location is fixed within its own distribution, so no search is needed.
"""

from __future__ import annotations

from pathlib import Path

from pb.pipeline.build import _find_ancestor_containing


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
