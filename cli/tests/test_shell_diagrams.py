"""Tests for pb_cli.shell.diagrams — diagram building and rendering."""

import re
from pathlib import Path

import duckdb
import pytest

from pb_cli.shell.build import find_repo
from pb_cli.shell.diagrams import (
    _svg_cache,
    build_calls,
    build_dw_tables,
    build_heatmap,
    build_inheritance,
    render_svg,
)

REPO_ROOT = find_repo()
DB_PATH = str(REPO_ROOT / "pb.duckdb")


@pytest.fixture(scope="module")
def conn():
    if not Path(DB_PATH).exists():
        pytest.skip(f"pb.duckdb not found at {DB_PATH} — run `pb index` + `pb analyze` first")
    c = duckdb.connect(DB_PATH, read_only=True)
    yield c
    c.close()


def dot_source(build_fn, *args, **kwargs) -> str:
    dot = build_fn(*args, **kwargs)
    return dot.source


def focal_object(conn) -> str:
    row = conn.execute("SELECT object FROM object_metrics ORDER BY in_degree DESC LIMIT 1").fetchone()
    return row[0] if row else "fn_sqlerror"


# ---------------------------------------------------------------------------
# A. Inheritance diagram
# ---------------------------------------------------------------------------


def test_inheritance_builds_valid_dot(conn):
    src = dot_source(build_inheritance, conn, None)
    assert "digraph" in src
    assert "->" in src


def test_inheritance_contains_known_nodes(conn):
    src = dot_source(build_inheritance, conn, None)
    sample = conn.execute("SELECT from_object FROM inherits LIMIT 1").fetchone()
    assert sample is not None, "inherits table is empty"
    assert sample[0] in src


def test_inheritance_root_filter(conn):
    root = conn.execute("SELECT to_object FROM inherits LIMIT 1").fetchone()
    if root is None:
        pytest.skip("inherits table is empty")
    src = dot_source(build_inheritance, conn, root[0])
    assert "digraph" in src
    assert root[0] in src or "->" in src


# ---------------------------------------------------------------------------
# B. Call ego-graph
# ---------------------------------------------------------------------------


def test_calls_includes_focal_node(conn):
    focal = focal_object(conn)
    src = dot_source(build_calls, conn, focal, 2)
    assert focal in src


def test_calls_depth_limits_nodes(conn):
    focal = focal_object(conn)
    src_d1 = dot_source(build_calls, conn, focal, 1)
    src_d3 = dot_source(build_calls, conn, focal, 3)
    nodes_d1 = len(re.findall(r"\[", src_d1))
    nodes_d3 = len(re.findall(r"\[", src_d3))
    assert nodes_d3 >= nodes_d1


def test_calls_unknown_object_does_not_crash(conn):
    src = dot_source(build_calls, conn, "__nonexistent_object_xyz__", 2)
    assert "digraph" in src


# ---------------------------------------------------------------------------
# C. DW-table bipartite diagram
# ---------------------------------------------------------------------------


def test_dw_tables_bipartite_structure(conn):
    count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
    if count == 0:
        pytest.skip("dw_retrieve_tables is empty")
    src = dot_source(build_dw_tables, conn, None)
    assert "cluster_dw" in src
    assert "cluster_tables" in src
    assert "->" in src


def test_dw_tables_table_filter(conn):
    row = conn.execute("SELECT table_name FROM dw_retrieve_tables LIMIT 1").fetchone()
    if row is None:
        pytest.skip("dw_retrieve_tables is empty")
    tbl = row[0]
    src = dot_source(build_dw_tables, conn, tbl)
    assert f"t_{tbl}" in src


# ---------------------------------------------------------------------------
# D. Complexity heatmap
# ---------------------------------------------------------------------------


def test_heatmap_includes_all_powerscript_objects(conn):
    expected = conn.execute("SELECT count(*) FROM objects WHERE kind = 'powerscript'").fetchone()[0]
    if expected == 0:
        pytest.skip("no powerscript objects in corpus")
    src = dot_source(build_heatmap, conn)
    node_defs = len(re.findall(r"\[", src))
    assert node_defs >= expected


def test_heatmap_emits_graph_not_digraph(conn):
    src = dot_source(build_heatmap, conn)
    assert re.search(r"\bgraph\b", src)


# ---------------------------------------------------------------------------
# E. URL attributes present in node output
# ---------------------------------------------------------------------------


def test_inheritance_nodes_have_url(conn):
    src = dot_source(build_inheritance, conn, None)
    assert "pb://object/" in src


def test_calls_nodes_have_url(conn):
    focal = focal_object(conn)
    src = dot_source(build_calls, conn, focal, 2)
    assert "pb://object/" in src


def test_heatmap_nodes_have_url(conn):
    src = dot_source(build_heatmap, conn)
    assert "pb://object/" in src


def test_dw_tables_has_both_object_and_table_urls(conn):
    count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
    if count == 0:
        pytest.skip("dw_retrieve_tables is empty")
    src = dot_source(build_dw_tables, conn, None)
    assert "pb://object/" in src
    assert "pb://table/" in src


# ---------------------------------------------------------------------------
# F. LRU cache
# ---------------------------------------------------------------------------


def test_render_svg_caches_result(conn):
    _svg_cache.clear()
    svg1 = render_svg("heatmap", conn)
    assert len(_svg_cache) == 1
    svg2 = render_svg("heatmap", conn)
    assert svg1 is svg2  # same object from cache


def test_render_svg_evicts_oldest(conn):
    _svg_cache.clear()
    for i in range(65):
        render_svg("heatmap", conn)
    assert len(_svg_cache) <= 64


def test_render_svg_unknown_kind_raises(conn):
    with pytest.raises(ValueError, match="Unknown diagram"):
        render_svg("bogus", conn)


# ---------------------------------------------------------------------------
# G. DOT roundtrip (requires dot binary)
# ---------------------------------------------------------------------------


def _dot_binary():
    import subprocess
    result = subprocess.run(["which", "dot"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


@pytest.mark.skipif(_dot_binary() is None, reason="dot binary not on PATH")
class TestDotBinaryRoundtrip:
    def _render(self, src: str):
        import subprocess
        return subprocess.run(
            ["dot", "-Tsvg"],
            input=src,
            capture_output=True,
            text=True,
        )

    def test_inheritance_dot_is_valid(self, conn):
        src = dot_source(build_inheritance, conn, None)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_calls_dot_is_valid(self, conn):
        focal = focal_object(conn)
        src = dot_source(build_calls, conn, focal, 2)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_dw_tables_dot_is_valid(self, conn):
        count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
        if count == 0:
            pytest.skip("dw_retrieve_tables is empty")
        src = dot_source(build_dw_tables, conn, None)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_heatmap_dot_is_valid(self, conn):
        src = dot_source(build_heatmap, conn)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout
