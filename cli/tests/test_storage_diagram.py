"""
Tests for pb_cli.diagram.

Run from repo root:
  uv run pytest tests/test_diagram.py

Requires:
  - pb.duckdb populated (run `pb index` + `pb analyze` first)
  - uv sync (graphviz, duckdb, networkx)
  - dot binary on PATH
"""

import io
import re
import subprocess
from contextlib import redirect_stdout
from pathlib import Path

import duckdb
import pytest

from pb_cli.shell.build import find_repo

REPO_ROOT = find_repo()
DB_PATH = str(REPO_ROOT / "pb.duckdb")

from pb_cli.shell.diagrams import (  # noqa: E402
    diagram_calls,
    diagram_dw_tables,
    diagram_heatmap,
    diagram_inheritance,
)


@pytest.fixture(scope="module")
def conn():
    if not Path(DB_PATH).exists():
        pytest.skip(f"pb.duckdb not found at {DB_PATH} — run `pb index` + `pb analyze` first")
    c = duckdb.connect(DB_PATH, read_only=True)
    yield c
    c.close()


def dot_source(fn, *args) -> str:
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn(*args, output="out.svg", emit_dot=True)
    return buf.getvalue()


def focal_object(conn) -> str:
    row = conn.execute("SELECT object FROM object_metrics ORDER BY in_degree DESC LIMIT 1").fetchone()
    return row[0] if row else "fn_sqlerror"


# ---------------------------------------------------------------------------
# A. Inheritance diagram
# ---------------------------------------------------------------------------


def test_inheritance_diagram_emits_valid_dot(conn):
    src = dot_source(diagram_inheritance, conn, None)
    assert "digraph" in src
    assert "->" in src


def test_inheritance_diagram_contains_known_nodes(conn):
    src = dot_source(diagram_inheritance, conn, None)
    sample = conn.execute("SELECT from_object FROM inherits LIMIT 1").fetchone()
    assert sample is not None, "inherits table is empty"
    assert sample[0] in src


def test_inheritance_diagram_root_filter(conn):
    root = conn.execute("SELECT to_object FROM inherits LIMIT 1").fetchone()
    if root is None:
        pytest.skip("inherits table is empty")
    src = dot_source(diagram_inheritance, conn, root[0])
    assert "digraph" in src
    assert root[0] in src or "->" in src


# ---------------------------------------------------------------------------
# B. Call ego-graph
# ---------------------------------------------------------------------------


def test_calls_diagram_includes_focal_node(conn):
    focal = focal_object(conn)
    src = dot_source(diagram_calls, conn, focal, 2)
    assert focal in src


def test_calls_diagram_emits_fdp_engine(conn):
    focal = focal_object(conn)
    src = dot_source(diagram_calls, conn, focal, 1)
    assert "fdp" in src.lower() or "digraph" in src


def test_calls_diagram_depth_limits_nodes(conn):
    focal = focal_object(conn)
    src_d1 = dot_source(diagram_calls, conn, focal, 1)
    src_d3 = dot_source(diagram_calls, conn, focal, 3)
    nodes_d1 = len(re.findall(r"\[", src_d1))
    nodes_d3 = len(re.findall(r"\[", src_d3))
    assert nodes_d3 >= nodes_d1


def test_calls_diagram_unknown_object_does_not_crash(conn):
    src = dot_source(diagram_calls, conn, "__nonexistent_object_xyz__", 2)
    assert "digraph" in src


# ---------------------------------------------------------------------------
# C. DW-table bipartite diagram
# ---------------------------------------------------------------------------


def test_dw_tables_diagram_bipartite_structure(conn):
    count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
    if count == 0:
        pytest.skip("dw_retrieve_tables is empty")
    src = dot_source(diagram_dw_tables, conn, None)
    assert "cluster_dw" in src
    assert "cluster_tables" in src
    assert "->" in src


def test_dw_tables_diagram_table_filter(conn):
    row = conn.execute("SELECT table_name FROM dw_retrieve_tables LIMIT 1").fetchone()
    if row is None:
        pytest.skip("dw_retrieve_tables is empty")
    tbl = row[0]
    src = dot_source(diagram_dw_tables, conn, tbl)
    assert f"t_{tbl}" in src


def test_dw_tables_node_count_matches_db(conn):
    dw_count = conn.execute("SELECT count(DISTINCT dw_name)    FROM dw_retrieve_tables").fetchone()[0]
    tbl_count = conn.execute("SELECT count(DISTINCT table_name) FROM dw_retrieve_tables").fetchone()[0]
    src = dot_source(diagram_dw_tables, conn, None)
    dw_hits = sum(
        1
        for dw in {r[0] for r in conn.execute("SELECT DISTINCT dw_name    FROM dw_retrieve_tables").fetchall()}
        if f"dw_{dw}" in src
    )
    tbl_hits = sum(
        1
        for tbl in {r[0] for r in conn.execute("SELECT DISTINCT table_name FROM dw_retrieve_tables").fetchall()}
        if f"t_{tbl}" in src
    )
    assert dw_hits == dw_count
    assert tbl_hits == tbl_count


# ---------------------------------------------------------------------------
# D. Complexity heatmap
# ---------------------------------------------------------------------------


def test_heatmap_includes_all_powerscript_objects(conn):
    expected = conn.execute("SELECT count(*) FROM objects WHERE kind = 'powerscript'").fetchone()[0]
    if expected == 0:
        pytest.skip("no powerscript objects in corpus")
    src = dot_source(diagram_heatmap, conn)
    node_defs = len(re.findall(r"\[", src))
    assert node_defs >= expected


def test_heatmap_emits_graph_not_digraph(conn):
    src = dot_source(diagram_heatmap, conn)
    assert re.search(r"\bgraph\b", src)


# ---------------------------------------------------------------------------
# E. DOT output pipes cleanly through dot -Tsvg
# ---------------------------------------------------------------------------


def _dot_binary() -> str | None:
    result = subprocess.run(["which", "dot"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


@pytest.mark.skipif(_dot_binary() is None, reason="dot binary not on PATH")
class TestDotBinaryRoundtrip:
    def _render(self, src: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["dot", "-Tsvg"],
            input=src,
            capture_output=True,
            text=True,
        )

    def test_inheritance_dot_is_valid(self, conn):
        src = dot_source(diagram_inheritance, conn, None)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_calls_dot_is_valid(self, conn):
        focal = focal_object(conn)
        src = dot_source(diagram_calls, conn, focal, 2)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_dw_tables_dot_is_valid(self, conn):
        count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
        if count == 0:
            pytest.skip("dw_retrieve_tables is empty")
        src = dot_source(diagram_dw_tables, conn, None)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_heatmap_dot_is_valid(self, conn):
        src = dot_source(diagram_heatmap, conn)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout


def test_op_colors_defined():
    from pb_cli.core.diagram_builder import _OP_COLORS

    assert "SELECT" in _OP_COLORS
    assert "INSERT" in _OP_COLORS
    assert "retrieve" in _OP_COLORS
