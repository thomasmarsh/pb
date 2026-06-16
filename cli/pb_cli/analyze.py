"""Compute call graph metrics and populate object_metrics in pb.duckdb."""
from __future__ import annotations

from typing import TYPE_CHECKING

import networkx as nx

from pb_cli.common import Conn, db_connection

if TYPE_CHECKING:
    from pb_cli.reporter import AnalyzeProgress, Reporter


def run(db: str = 'pb.duckdb', reporter: Reporter | None = None) -> None:
    if reporter is None:
        from pb_cli.reporter import LiveReporter
        reporter = LiveReporter()

    with db_connection(db) as conn:
        with reporter.analyze_progress() as progress:
            compute_metrics(conn, progress)


def compute_dit(conn: Conn) -> dict[str, int]:
    """Depth of inheritance tree: max hops from a base class (no parent)."""
    edges = conn.execute("SELECT from_object, to_object FROM inherits").fetchall()
    igraph = nx.DiGraph((parent, child) for child, parent in edges)
    roots = {n for n in igraph.nodes() if igraph.in_degree(n) == 0}
    dit: dict[str, int] = {n: 0 for n in igraph.nodes()}
    for root in roots:
        for node, depth in nx.single_source_shortest_path_length(igraph, root).items():
            dit[node] = max(dit.get(node, 0), depth)
    return dit


def compute_metrics(conn: Conn, progress: AnalyzeProgress) -> None:
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

    edges = conn.execute("""
        SELECT object AS src, to_name AS dst FROM calls
        WHERE to_name != '' AND object != to_name
    """).fetchall()
    G = nx.DiGraph()
    G.add_edges_from(edges)
    progress.advance_metrics('betweenness centrality')

    if not G.nodes():
        for _ in range(3):
            progress.advance_metrics('done')
        return

    k = min(500, len(G.nodes()))
    betweenness = nx.betweenness_centrality(G, k=k)
    progress.advance_metrics('PageRank + DIT')

    pr = nx.pagerank(G, alpha=0.85)
    cyc = conn.execute("""
        SELECT object, max(cyclomatic), avg(cyclomatic)
        FROM procedures
        WHERE cyclomatic IS NOT NULL AND cyclomatic > 0
        GROUP BY object
    """).fetchall()
    cyc_map = {obj: (int(max_c), float(avg_c)) for obj, max_c, avg_c in cyc}
    dit_map = compute_dit(conn)
    progress.advance_metrics('inserting rows')

    rows = [
        (
            node,
            G.in_degree(node), G.out_degree(node),
            betweenness.get(node, 0.0), pr.get(node, 0.0),
            *cyc_map.get(node, (None, None)),
            dit_map.get(node),
            None,  # CBO deferred
        )
        for node in G.nodes()
    ]
    if rows:
        conn.executemany("INSERT INTO object_metrics VALUES (?,?,?,?,?,?,?,?,?)", rows)
    progress.advance_metrics('done')
