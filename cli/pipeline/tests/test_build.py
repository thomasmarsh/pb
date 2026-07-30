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

import os
from pathlib import Path

import pytest
from pb.pipeline.build import _bundle_stale, _find_ancestor_containing


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


def _make_explorer_dir(tmp_path: Path) -> Path:
    """Mirror the real ui/ layout: app/src and packages/*/src, not ui/src."""
    explorer_dir = tmp_path / "ui"
    (explorer_dir / "app" / "src").mkdir(parents=True)
    (explorer_dir / "packages" / "platform" / "src").mkdir(parents=True)
    (explorer_dir / "package.json").write_text("{}")
    (explorer_dir / "vite.config.ts").write_text("")
    (explorer_dir / "app" / "src" / "App.tsx").write_text("x")
    (explorer_dir / "packages" / "platform" / "src" / "index.ts").write_text("x")
    return explorer_dir


def _make_dist_js(explorer_dir: Path) -> Path:
    dist_js = explorer_dir.parent / "dist" / "App.js"
    dist_js.parent.mkdir(parents=True)
    dist_js.write_text("built")
    return dist_js


@pytest.mark.parametrize(
    "touch_relpath, expected_stale",
    [
        ("app/src/App.tsx", True),
        ("packages/platform/src/index.ts", True),
        (None, False),
    ],
)
def test_bundle_stale_checks_real_source_dirs(tmp_path: Path, touch_relpath: str | None, expected_stale: bool):
    """Regression test: the old glob patterns ('src/**/*.ts' relative to ui/)
    matched nothing, since real source lives under app/src and packages/*/src,
    not ui/src -- so a real edit anywhere in the explorer never triggered a
    rebuild. Both real source roots must independently register as stale."""
    explorer_dir = _make_explorer_dir(tmp_path)
    dist_js = _make_dist_js(explorer_dir)
    if touch_relpath is not None:
        target = explorer_dir / touch_relpath
        newer = dist_js.stat().st_mtime + 1
        os.utime(target, (newer, newer))
    assert _bundle_stale(explorer_dir, dist_js) is expected_stale


def test_bundle_stale_true_when_dist_missing(tmp_path: Path):
    explorer_dir = _make_explorer_dir(tmp_path)
    dist_js = explorer_dir.parent / "dist" / "App.js"
    assert _bundle_stale(explorer_dir, dist_js) is True
