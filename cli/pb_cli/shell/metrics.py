"""Graph metric computation (PageRank, betweenness, DIT, cyclomatic)."""

from __future__ import annotations

from typing import TYPE_CHECKING

import networkx as nx

from pb_cli.shell.db import Conn

if TYPE_CHECKING:
    from pb_cli.reporter import AnalyzeProgress


def fetch_inheritance_edges(conn: Conn) -> list[tuple[str, str]]:
    """Fetch parent→child edges from the inherits table."""
    return conn.execute("SELECT from_object, to_object FROM inherits").fetchall()


def compute_dit_from_edges(edges: list[tuple[str, str]]) -> dict[str, int]:
    """Depth of inheritance tree: max hops from a base class (no parent). Pure function."""
    igraph = nx.DiGraph((parent, child) for child, parent in edges)
    roots = {n for n in igraph.nodes() if igraph.in_degree(n) == 0}
    dit: dict[str, int] = {n: 0 for n in igraph.nodes()}
    for root in roots:
        for node, depth in nx.single_source_shortest_path_length(igraph, root).items():
            dit[node] = max(dit.get(node, 0), depth)
    return dit


def compute_dit(conn: Conn) -> dict[str, int]:
    """Depth of inheritance tree: fetch + compute convenience wrapper."""
    return compute_dit_from_edges(fetch_inheritance_edges(conn))


def fetch_metrics_data(
    conn: Conn,
) -> tuple[list[tuple[str, str]], list[tuple[str, int, float]], list[tuple[str, str]]]:
    """Fetch call edges, per-object cyclomatic data, and inheritance edges.

    Returns (call_edges, cyc_rows, inherit_edges).
    """
    edges = conn.execute("""
        SELECT object AS src, to_name AS dst FROM calls
        WHERE to_name != '' AND object != to_name
    """).fetchall()
    cyc = conn.execute("""
        SELECT object, max(cyclomatic), avg(cyclomatic)
        FROM procedures
        WHERE cyclomatic IS NOT NULL AND cyclomatic > 0
        GROUP BY object
    """).fetchall()
    inherit = fetch_inheritance_edges(conn)
    return edges, cyc, inherit


def compute_metrics_from_data(
    edges: list[tuple[str, str]],
    cyc_rows: list[tuple[str, int, float]],
    inherit_edges: list[tuple[str, str]],
) -> list[tuple]:
    """Compute graph metrics from fetched data. Returns list of row tuples for object_metrics."""
    G = nx.DiGraph()
    G.add_edges_from(edges)

    if not G.nodes():
        return []

    k = min(500, len(G.nodes()))
    betweenness = nx.betweenness_centrality(G, k=k)
    pr = nx.pagerank(G, alpha=0.85)
    cyc_map = {obj: (int(max_c), float(avg_c)) for obj, max_c, avg_c in cyc_rows}
    dit_map = compute_dit_from_edges(inherit_edges)

    return [
        (
            node,
            G.in_degree(node),
            G.out_degree(node),
            betweenness.get(node, 0.0),
            pr.get(node, 0.0),
            *cyc_map.get(node, (None, None)),
            dit_map.get(node),
            None,  # CBO deferred
        )
        for node in G.nodes()
    ]


def write_metrics(conn: Conn, rows: list[tuple]) -> None:
    """Write computed metric rows into the object_metrics table."""
    if rows:
        conn.executemany("INSERT INTO object_metrics VALUES (?,?,?,?,?,?,?,?,?)", rows)


def compute_metrics(conn: Conn, progress: AnalyzeProgress) -> None:
    """Full pipeline: fetch → compute → write, with progress side channel."""
    conn.execute("DROP TABLE IF EXISTS object_metrics")
    conn.execute("""
        CREATE TABLE object_metrics (
            object         TEXT NOT NULL,
            in_degree      INT,
            out_degree     INT,
            betweenness    DOUBLE,
            pagerank       DOUBLE,
            max_cyclomatic INT,
            avg_cyclomatic DOUBLE,
            dit            INT,
            cbo            INT
        )
    """)

    edges, cyc_rows, inherit_edges = fetch_metrics_data(conn)
    progress.advance_metrics("betweenness centrality")

    rows = compute_metrics_from_data(edges, cyc_rows, inherit_edges)
    progress.advance_metrics("PageRank + DIT")

    write_metrics(conn, rows)
    progress.advance_metrics("inserting rows")
    progress.advance_metrics("done")
