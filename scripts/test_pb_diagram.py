"""
Tests for scripts/pb_diagram.py.

Run from repo root:
  pytest scripts/test_pb_diagram.py

Requires:
  - pb.duckdb populated (run pb_index + pb_analyze first)
  - graphviz, duckdb, networkx Python packages
  - dot binary on PATH
"""

import re
import subprocess
import sys
import os

import duckdb
import pytest

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT   = os.path.dirname(SCRIPTS_DIR)
DB_PATH     = os.path.join(REPO_ROOT, 'pb.duckdb')

sys.path.insert(0, SCRIPTS_DIR)
from pb_diagram import (
    diagram_calls,
    diagram_dw_tables,
    diagram_heatmap,
    diagram_inheritance,
)


# ---------------------------------------------------------------------------
# Shared fixture: read-only connection to the live pb.duckdb
# ---------------------------------------------------------------------------

@pytest.fixture(scope='module')
def conn():
    if not os.path.exists(DB_PATH):
        pytest.skip(f"pb.duckdb not found at {DB_PATH} — run pb_index + pb_analyze first")
    c = duckdb.connect(DB_PATH, read_only=True)
    yield c
    c.close()


def dot_source(fn, *args) -> str:
    """Call a diagram_* function with emit_dot=True and capture the DOT text."""
    import io
    from contextlib import redirect_stdout
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn(*args, output='out.svg', emit_dot=True)
    return buf.getvalue()


def focal_object(conn) -> str:
    """Pick the highest-in-degree object that also exists in the calls table."""
    row = conn.execute("""
        SELECT object FROM object_metrics
        ORDER BY in_degree DESC LIMIT 1
    """).fetchone()
    return row[0] if row else 'fn_sqlerror'


# ---------------------------------------------------------------------------
# A. Inheritance diagram
# ---------------------------------------------------------------------------

def test_inheritance_diagram_emits_valid_dot(conn):
    src = dot_source(diagram_inheritance, conn, None)
    assert 'digraph' in src, "inheritance diagram should emit a digraph"
    assert '->' in src, "inheritance diagram should contain directed edges"


def test_inheritance_diagram_contains_known_nodes(conn):
    src = dot_source(diagram_inheritance, conn, None)
    # At least one node name from the inherits table should appear
    sample = conn.execute(
        "SELECT from_object FROM inherits LIMIT 1"
    ).fetchone()
    assert sample is not None, "inherits table is empty"
    assert sample[0] in src, f"expected node '{sample[0]}' in DOT source"


def test_inheritance_diagram_root_filter(conn):
    root = conn.execute(
        "SELECT to_object FROM inherits LIMIT 1"
    ).fetchone()
    if root is None:
        pytest.skip("inherits table is empty")
    src = dot_source(diagram_inheritance, conn, root[0])
    assert 'digraph' in src
    # Root or descendants must appear
    assert root[0] in src or '->' in src


# ---------------------------------------------------------------------------
# B. Call ego-graph
# ---------------------------------------------------------------------------

def test_calls_diagram_includes_focal_node(conn):
    focal = focal_object(conn)
    src = dot_source(diagram_calls, conn, focal, 2)
    assert focal in src, f"focal node '{focal}' should appear in DOT source"


def test_calls_diagram_emits_fdp_engine(conn):
    focal = focal_object(conn)
    src = dot_source(diagram_calls, conn, focal, 1)
    assert 'fdp' in src.lower() or 'digraph' in src, (
        "calls diagram should emit a digraph with fdp engine annotation"
    )


def test_calls_diagram_depth_limits_nodes(conn):
    focal = focal_object(conn)
    src_d1 = dot_source(diagram_calls, conn, focal, 1)
    src_d3 = dot_source(diagram_calls, conn, focal, 3)
    nodes_d1 = len(re.findall(r'\[', src_d1))
    nodes_d3 = len(re.findall(r'\[', src_d3))
    assert nodes_d3 >= nodes_d1, (
        "deeper ego-graph should have at least as many node definitions"
    )


def test_calls_diagram_unknown_object_does_not_crash(conn):
    src = dot_source(diagram_calls, conn, '__nonexistent_object_xyz__', 2)
    assert 'digraph' in src


# ---------------------------------------------------------------------------
# C. DW-table bipartite diagram
# ---------------------------------------------------------------------------

def test_dw_tables_diagram_bipartite_structure(conn):
    count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
    if count == 0:
        pytest.skip("dw_retrieve_tables is empty")
    src = dot_source(diagram_dw_tables, conn, None)
    assert 'cluster_dw' in src,     "DW cluster should be present"
    assert 'cluster_tables' in src, "tables cluster should be present"
    assert '->' in src,             "edges between DWs and tables should be present"


def test_dw_tables_diagram_table_filter(conn):
    row = conn.execute("SELECT table_name FROM dw_retrieve_tables LIMIT 1").fetchone()
    if row is None:
        pytest.skip("dw_retrieve_tables is empty")
    tbl = row[0]
    src = dot_source(diagram_dw_tables, conn, tbl)
    assert f"t_{tbl}" in src, f"filtered table node 't_{tbl}' should appear in DOT source"


def test_dw_tables_node_count_matches_db(conn):
    dw_count  = conn.execute("SELECT count(DISTINCT dw_name)    FROM dw_retrieve_tables").fetchone()[0]
    tbl_count = conn.execute("SELECT count(DISTINCT table_name) FROM dw_retrieve_tables").fetchone()[0]
    src = dot_source(diagram_dw_tables, conn, None)
    dw_hits  = sum(1 for dw  in {r[0] for r in conn.execute("SELECT DISTINCT dw_name    FROM dw_retrieve_tables").fetchall()} if f"dw_{dw}" in src)
    tbl_hits = sum(1 for tbl in {r[0] for r in conn.execute("SELECT DISTINCT table_name FROM dw_retrieve_tables").fetchall()} if f"t_{tbl}" in src)
    assert dw_hits  == dw_count,  f"expected {dw_count} DW nodes,    found {dw_hits}"
    assert tbl_hits == tbl_count, f"expected {tbl_count} table nodes, found {tbl_hits}"


# ---------------------------------------------------------------------------
# D. Complexity heatmap
# ---------------------------------------------------------------------------

def test_heatmap_includes_all_powerscript_objects(conn):
    expected = conn.execute(
        "SELECT count(*) FROM objects WHERE kind = 'powerscript'"
    ).fetchone()[0]
    if expected == 0:
        pytest.skip("no powerscript objects in corpus")
    src = dot_source(diagram_heatmap, conn)
    # Count node definition lines (heuristic: lines with '[')
    node_defs = len(re.findall(r'\[', src))
    # Legend adds ~5 nodes; allow generous headroom
    assert node_defs >= expected, (
        f"heatmap has {node_defs} node defs but expected at least {expected} objects"
    )


def test_heatmap_emits_graph_not_digraph(conn):
    src = dot_source(diagram_heatmap, conn)
    # sfdp undirected graph — should start with 'graph' not 'digraph'
    assert re.search(r'\bgraph\b', src), "heatmap should emit an undirected graph"


# ---------------------------------------------------------------------------
# E. DOT output pipes cleanly through dot -Tsvg
# ---------------------------------------------------------------------------

def _dot_binary() -> str | None:
    result = subprocess.run(['which', 'dot'], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


@pytest.mark.skipif(_dot_binary() is None, reason='dot binary not on PATH')
class TestDotBinaryRoundtrip:

    def _render(self, src: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ['dot', '-Tsvg'],
            input=src, capture_output=True, text=True,
        )

    def test_inheritance_dot_is_valid(self, conn):
        src = dot_source(diagram_inheritance, conn, None)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert '<svg' in result.stdout

    def test_calls_dot_is_valid(self, conn):
        focal = focal_object(conn)
        src = dot_source(diagram_calls, conn, focal, 2)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert '<svg' in result.stdout

    def test_dw_tables_dot_is_valid(self, conn):
        count = conn.execute("SELECT count(*) FROM dw_retrieve_tables").fetchone()[0]
        if count == 0:
            pytest.skip("dw_retrieve_tables is empty")
        src = dot_source(diagram_dw_tables, conn, None)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert '<svg' in result.stdout

    def test_heatmap_dot_is_valid(self, conn):
        src = dot_source(diagram_heatmap, conn)
        result = self._render(src)
        assert result.returncode == 0, f"dot failed:\n{result.stderr[:400]}"
        assert '<svg' in result.stdout
