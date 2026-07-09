"""Tests for pb.pipeline.diagrams — diagram building and rendering."""

import re
from pathlib import Path

import duckdb
import graphviz
import pytest
from pb.pipeline.build import find_repo
from pb.pipeline.diagrams import (
    _PLACEHOLDER_SVG,
    _svg_cache,
    build_calls,
    build_dw_tables,
    build_fk_graph,
    build_heatmap,
    build_inheritance,
    build_window_table_lattice,
    render_dot_to_svg,
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
    sample = conn.execute("SELECT object AS from_object FROM objects WHERE ancestor IS NOT NULL LIMIT 1").fetchone()
    assert sample is not None, "no objects with ancestors"
    assert sample[0] in src


def test_inheritance_root_filter(conn):
    root = conn.execute("SELECT ancestor AS to_object FROM objects WHERE ancestor IS NOT NULL LIMIT 1").fetchone()
    if root is None:
        pytest.skip("no objects with ancestors")
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


def _require_dw_retrieve_tables(conn) -> None:
    """Skip the test if dw_retrieve_tables does not exist or is empty."""
    try:
        count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
    except Exception:
        pytest.skip("dw_retrieve_tables table does not exist")
    if count == 0:
        pytest.skip("dw_retrieve_tables is empty")


def test_dw_tables_bipartite_structure(conn):
    _require_dw_retrieve_tables(conn)
    src = dot_source(build_dw_tables, conn, None)
    assert "cluster_dw" in src
    assert "cluster_tables" in src
    assert "->" in src


def test_dw_tables_table_filter(conn):
    _require_dw_retrieve_tables(conn)
    row = conn.execute("SELECT table_name FROM dw_retrieve_tables LIMIT 1").fetchone()
    if row is None:
        pytest.skip("dw_retrieve_tables is empty")
    tbl = row[0]
    src = dot_source(build_dw_tables, conn, tbl)
    assert f"t_{tbl}" in src


def test_dw_tables_dw_filter(conn):
    _require_dw_retrieve_tables(conn)
    row = conn.execute("SELECT dw_name FROM dw_retrieve_tables LIMIT 1").fetchone()
    if row is None:
        pytest.skip("dw_retrieve_tables is empty")
    dw_name = row[0]
    src = dot_source(build_dw_tables, conn, None, dw_name)
    assert "digraph" in src
    assert dw_name in src


def test_dw_tables_dw_filter_nonexistent(conn):
    _require_dw_retrieve_tables(conn)
    src = dot_source(build_dw_tables, conn, None, "__nonexistent_dw__")
    assert "digraph" in src
    assert "->" not in src


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
    _require_dw_retrieve_tables(conn)
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
# G. FK graph (Plan 153 D2) — needs --ddl + sqlglot bridge, uses the
# session-scoped schema_db_conn fixture from root conftest.py, not the
# plain `conn` fixture above (which lacks --ddl and leaves Sch empty).
# ---------------------------------------------------------------------------


def test_fk_graph_counts_match_pinned_schema_service_numbers(schema_db_conn):
    src = dot_source(build_fk_graph, schema_db_conn)
    assert "digraph" in src
    # pinned in api/tests/test_schema_service.py::test_get_fk_graph_counts
    assert src.count("dashed") == 5  # unenforced edges


def test_fk_graph_unenforced_edge_present_and_dashed(schema_db_conn):
    src = dot_source(build_fk_graph, schema_db_conn)
    assert "usrgroupperm" in src
    assert "usractions" in src
    assert "dashed" in src


# ---------------------------------------------------------------------------
# H. DOT roundtrip (requires dot binary)
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
        _require_dw_retrieve_tables(conn)
        src = dot_source(build_dw_tables, conn, None)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_heatmap_dot_is_valid(self, conn):
        src = dot_source(build_heatmap, conn)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout

    def test_window_table_lattice_dot_is_valid(self, schema_db_conn):
        src = dot_source(build_window_table_lattice, schema_db_conn)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert "<svg" in result.stdout


# ---------------------------------------------------------------------------
# I. Window x table concept lattice (Plan 153 D7) — also uses schema_db_conn.
# ---------------------------------------------------------------------------


def test_window_table_lattice_counts_match_pinned_schema_service_numbers(schema_db_conn):
    src = dot_source(build_window_table_lattice, schema_db_conn)
    assert "digraph" in src
    # pinned in api/tests/test_schema_service.py::test_get_window_table_lattice_counts
    assert src.count('label="') == 49  # one node label per concept


def test_window_table_lattice_has_edges(schema_db_conn):
    src = dot_source(build_window_table_lattice, schema_db_conn)
    assert "->" in src


# ---------------------------------------------------------------------------
# J. render_dot_to_svg resilience — a rendering failure must never propagate as an
# exception, since a single bad diagram (e.g. a graphviz build missing the
# triangulation library) must not break the page it's embedded in. Uses a
# fake dot object so this doesn't depend on a real `dot` binary or corpus DB.
# ---------------------------------------------------------------------------


class FakeDot:
    def __init__(self, exc: Exception | None):
        """exc=None means .pipe() succeeds; otherwise every call raises exc."""
        self.exc = exc
        self.calls = 0

    def pipe(self, format: str) -> bytes:  # noqa: A002
        self.calls += 1
        if self.exc is not None:
            raise self.exc
        return b"<svg>ok</svg>"


def test_render_svg_returns_pipe_output_on_success():
    dot = FakeDot(exc=None)
    assert render_dot_to_svg(dot) == "<svg>ok</svg>"
    assert dot.calls == 1


def test_render_svg_returns_placeholder_on_called_process_error():
    dot = FakeDot(exc=graphviz.backend.execute.CalledProcessError(1, ["dot"]))
    assert render_dot_to_svg(dot) == _PLACEHOLDER_SVG
    assert dot.calls == 1


def test_render_svg_returns_placeholder_on_any_other_exception():
    dot = FakeDot(exc=RuntimeError("dot crashed"))
    assert render_dot_to_svg(dot) == _PLACEHOLDER_SVG


def test_render_svg_reraises_executable_not_found():
    dot = FakeDot(exc=graphviz.backend.execute.ExecutableNotFound(["dot"]))
    with pytest.raises(graphviz.backend.execute.ExecutableNotFound):
        render_dot_to_svg(dot)
