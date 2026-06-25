"""DOT/SVG diagram building and rendering (shell layer — I/O boundary)."""

from __future__ import annotations

import logging
from collections import OrderedDict
from typing import Any

import graphviz
import networkx as nx
from pb.lib.diagram_builder import (
    render_calls,
    render_dw_tables,
    render_heatmap,
    render_inheritance,
    render_proc_tables,
    render_sql_lineage,
    render_table_lineage,
)

from pb_cli.shell.db import Conn

log = logging.getLogger(__name__)

_CACHE_MAX = 64
_svg_cache: OrderedDict[str, str] = OrderedDict()


def _cache_key(kind: str, params: dict[str, Any]) -> str:
    parts = [f"{k}={v}" for k, v in sorted(params.items()) if k != "conn"]
    return kind + "|" + "|".join(parts)


def _render_svg(dot) -> str:
    """Render a graphviz object to SVG. Falls back to Bezier splines if the
    primary engine fails (e.g. missing triangulate on RHEL)."""
    try:
        return dot.pipe(format="svg").decode("utf-8")
    except graphviz.backend.execute.ExecutableNotFound:
        raise
    except Exception:
        log.warning("Primary render failed, retrying with splines=true", exc_info=True)
        dot.attr(splines="true")
        return dot.pipe(format="svg").decode("utf-8")


def build_inheritance(
    conn: Conn,
    root: str | None = None,
) -> graphviz.Digraph:
    if root:
        edges = conn.execute(
            """
            WITH RECURSIVE
              inherits AS (
                SELECT object AS from_object, ancestor AS to_object
                FROM objects WHERE ancestor IS NOT NULL
              ),
              sub AS (
                SELECT from_object, to_object FROM inherits WHERE to_object = ?
                UNION ALL
                SELECT i.from_object, i.to_object
                FROM inherits i JOIN sub s ON i.to_object = s.from_object
              )
            SELECT DISTINCT from_object, to_object FROM sub
        """,
            [root],
        ).fetchall()
    else:
        edges = conn.execute(
            "SELECT object AS from_object, ancestor AS to_object FROM objects WHERE ancestor IS NOT NULL"
        ).fetchall()

    kind_map = dict(conn.execute("SELECT object AS name, kind FROM objects").fetchall())

    return render_inheritance(edges, kind_map, root)


def build_calls(
    conn: Conn,
    focal: str = "",
    depth: int = 2,
) -> graphviz.Digraph:
    raw_edges = conn.execute("SELECT object, to_name FROM call_sites").fetchall()
    G: nx.DiGraph = nx.DiGraph(raw_edges)

    if focal in G:
        ego = nx.ego_graph(G, focal, radius=depth, undirected=True)
        sub_nodes = set(ego.nodes())
        sub_edges = [(u, v) for u, v in G.edges() if u in sub_nodes and v in sub_nodes]
    else:
        sub_nodes = {focal}
        sub_edges = []

    cc_map: dict[str, int] = dict(
        conn.execute("SELECT proc_name AS name, max(cyclomatic) FROM procedures GROUP BY proc_name").fetchall()
    )

    return render_calls(sub_nodes, sub_edges, cc_map, focal)


def build_dw_tables(
    conn: Conn,
    filter_table: str | None = None,
    filter_dw: str | None = None,
) -> graphviz.Digraph:
    try:
        dw_rows = conn.execute(
            """
            SELECT dw_name, table_name FROM dw_retrieve_tables
            WHERE (? IS NULL OR table_name = ?)
              AND (? IS NULL OR dw_name = ?)
            ORDER BY dw_name, table_name
        """,
            [filter_table, filter_table, filter_dw, filter_dw],
        ).fetchall()
        count_map: dict[str, int] = dict(
            conn.execute("SELECT dw_name, count(*) FROM dw_retrieve_tables GROUP BY dw_name").fetchall()
        )
    except Exception:
        dw_rows = []
        count_map = {}

    return render_dw_tables(dw_rows, count_map)


def build_heatmap(
    conn: Conn,
) -> graphviz.Graph:
    rows = conn.execute("""
        SELECT o.object AS name, o.kind,
               COALESCE(m.max_cyclomatic, 0),
               COALESCE(m.in_degree,      0)
        FROM objects o
        LEFT JOIN object_metrics m ON o.object = m.object
        WHERE o.kind = 'powerscript'
        ORDER BY COALESCE(m.max_cyclomatic, 0) DESC
    """).fetchall()

    inherit_edges = conn.execute(
        "SELECT object AS from_object, ancestor AS to_object FROM objects WHERE ancestor IS NOT NULL"
    ).fetchall()

    return render_heatmap(rows, inherit_edges)


def build_sql_lineage(conn: Conn, focal: str = "") -> graphviz.Digraph:
    rows = conn.execute(
        "SELECT DISTINCT object, table_name, operation "
        "FROM all_sql_tables "
        "WHERE source = 'powerscript'" + (" AND object = ?" if focal else ""),
        [focal] if focal else [],
    ).fetchall()

    return render_sql_lineage(rows)


def build_table_lineage(conn: Conn, table_name: str = "") -> graphviz.Digraph:
    if not table_name:
        raise ValueError("table_name is required for table-lineage")

    rows = conn.execute(
        "SELECT DISTINCT object, source, operation FROM all_sql_tables WHERE table_name = ? ORDER BY source, object",
        [table_name],
    ).fetchall()

    return render_table_lineage(rows, table_name)


def build_proc_tables(
    conn: Conn,
    table_name: str = "",
    focal: str = "",
) -> graphviz.Digraph:
    where_clauses = []
    params: list = []
    if table_name:
        where_clauses.append("table_name = ?")
        params.append(table_name)
    if focal:
        where_clauses.append("object = ?")
        params.append(focal)

    where_sql = ("WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
    cursor = conn.execute(
        f"SELECT DISTINCT object, proc_name, table_name, operation, source "
        f"FROM all_sql_tables {where_sql} ORDER BY object, table_name",
        params,
    )
    cols = [d[0] for d in cursor.description]
    rows = [dict(zip(cols, row)) for row in cursor.fetchall()]

    return render_proc_tables(rows, table_name)


def render_svg(kind: str, conn: Conn, **params: Any) -> str:
    """Build and render a diagram to SVG with LRU caching.

    This is the single entry point for the explorer API. It handles
    cache lookup, dot object construction, rendering with Bezier fallback,
    and cache storage.
    """
    key = _cache_key(kind, params)
    if key in _svg_cache:
        _svg_cache.move_to_end(key)
        return _svg_cache[key]

    builders = {
        "inheritance": lambda: build_inheritance(conn, root=params.get("root")),
        "calls": lambda: build_calls(conn, focal=params.get("focal", ""), depth=params.get("depth", 2)),
        "dw-tables": lambda: build_dw_tables(
            conn,
            filter_table=params.get("filter_table"),
            filter_dw=params.get("filter_dw"),
        ),
        "heatmap": lambda: build_heatmap(conn),
        "sql-lineage": lambda: build_sql_lineage(conn, focal=params.get("focal", "")),
        "table-lineage": lambda: build_table_lineage(conn, table_name=params.get("table_name", "")),
        "proc-tables": lambda: build_proc_tables(
            conn, table_name=params.get("table_name", ""), focal=params.get("focal", ""),
        ),
    }
    builder = builders.get(kind)
    if builder is None:
        raise ValueError(f"Unknown diagram: {kind}")

    dot = builder()
    svg = _render_svg(dot)

    _svg_cache[key] = svg
    if len(_svg_cache) > _CACHE_MAX:
        _svg_cache.popitem(last=False)

    return svg
