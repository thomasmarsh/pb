"""DOT/SVG diagram building and rendering."""

from __future__ import annotations

import sys

import graphviz
import networkx as nx

from pb_cli.core.diagram_builder import (
    render_calls,
    render_dw_tables,
    render_heatmap,
    render_inheritance,
    render_proc_tables,
    render_sql_lineage,
    render_table_lineage,
)
from pb_cli.shell.db import Conn


def _render(dot: graphviz.Graph | graphviz.Digraph, output: str, emit_dot: bool) -> None:
    if emit_dot:
        print(dot.source)
        return
    dot.render(outfile=output, format="svg", cleanup=True)
    print(f"Written: {output}", file=sys.stderr)


def build_inheritance(
    conn: Conn,
    root: str | None = None,
) -> graphviz.Digraph:
    if root:
        edges = conn.execute(
            """
            WITH RECURSIVE sub AS (
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
        edges = conn.execute("SELECT from_object, to_object FROM inherits").fetchall()

    kind_map = dict(conn.execute("SELECT name, kind FROM objects").fetchall())

    return render_inheritance(edges, kind_map, root)


def diagram_inheritance(
    conn: Conn,
    root: str | None,
    output: str = "inheritance.svg",
    emit_dot: bool = False,
) -> None:
    dot = build_inheritance(conn, root)
    _render(dot, output, emit_dot)


def build_calls(
    conn: Conn,
    focal: str = "",
    depth: int = 2,
) -> graphviz.Digraph:
    raw_edges = conn.execute("SELECT object, to_name FROM calls").fetchall()
    G: nx.DiGraph = nx.DiGraph(raw_edges)

    if focal in G:
        ego = nx.ego_graph(G, focal, radius=depth, undirected=True)
        sub_nodes = set(ego.nodes())
        sub_edges = [(u, v) for u, v in G.edges() if u in sub_nodes and v in sub_nodes]
    else:
        sub_nodes = {focal}
        sub_edges = []

    cc_map: dict[str, int] = dict(conn.execute("SELECT name, max(cyclomatic) FROM procedures GROUP BY name").fetchall())

    return render_calls(sub_nodes, sub_edges, cc_map, focal)


def diagram_calls(
    conn: Conn,
    focal: str,
    depth: int = 2,
    output: str | None = None,
    emit_dot: bool = False,
) -> None:
    if output is None:
        output = f"calls_{focal}.svg"
    dot = build_calls(conn, focal, depth)
    _render(dot, output, emit_dot)


def build_dw_tables(
    conn: Conn,
    filter_table: str | None = None,
) -> graphviz.Digraph:
    rows = conn.execute(
        """
        SELECT dw_name, table_name FROM dw_retrieve_tables
        WHERE (? IS NULL) OR table_name = ?
        ORDER BY dw_name, table_name
    """,
        [filter_table, filter_table],
    ).fetchall()

    count_map: dict[str, int] = dict(
        conn.execute("SELECT dw_name, count(*) FROM dw_retrieve_tables GROUP BY dw_name").fetchall()
    )

    return render_dw_tables(rows, count_map)


def diagram_dw_tables(
    conn: Conn,
    filter_table: str | None = None,
    output: str = "dw_tables.svg",
    emit_dot: bool = False,
) -> None:
    dot = build_dw_tables(conn, filter_table)
    _render(dot, output, emit_dot)


def build_heatmap(
    conn: Conn,
) -> graphviz.Graph:
    rows = conn.execute("""
        SELECT o.name, o.kind,
               COALESCE(m.max_cyclomatic, 0),
               COALESCE(m.in_degree,      0)
        FROM objects o
        LEFT JOIN object_metrics m ON o.name = m.object
        WHERE o.kind = 'powerscript'
        ORDER BY COALESCE(m.max_cyclomatic, 0) DESC
    """).fetchall()

    inherit_edges = conn.execute("SELECT from_object, to_object FROM inherits").fetchall()

    return render_heatmap(rows, inherit_edges)


def diagram_heatmap(
    conn: Conn,
    output: str = "heatmap.svg",
    emit_dot: bool = False,
) -> None:
    dot = build_heatmap(conn)
    _render(dot, output, emit_dot)


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
