"""Compute call graph metrics and populate object_metrics in pb.duckdb."""
from __future__ import annotations

import json
from typing import TYPE_CHECKING

import duckdb
import networkx as nx

if TYPE_CHECKING:
    from pb_cli.reporter import AnalyzeProgress, Reporter

BRANCH_TAGS = {'BsIf', 'BsFor', 'BsDo', 'BsChoose'}


def run(db: str = 'pb.duckdb', reporter: Reporter | None = None) -> None:
    if reporter is None:
        from pb_cli.reporter import LiveReporter
        reporter = LiveReporter()

    conn = duckdb.connect(db)
    row = conn.execute(
        "SELECT COUNT(*) FROM procedures WHERE body_json IS NOT NULL"
    ).fetchone()
    n_procs: int = row[0] if row else 0

    with reporter.analyze_progress(n_procs) as progress:
        extract_calls(conn, progress)
        compute_cyclomatic(conn, progress)
        compute_metrics(conn, progress)

    conn.close()


def extract_calls(conn, progress: AnalyzeProgress) -> None:
    conn.execute("DROP TABLE IF EXISTS calls")
    conn.execute("""
        CREATE TABLE calls (
            file       TEXT,
            object     TEXT,
            from_proc  TEXT,
            to_name    TEXT,
            call_type  TEXT
        )
    """)
    procs = conn.execute(
        "SELECT file, object, name, body_json FROM procedures WHERE body_json IS NOT NULL"
    ).fetchall()
    rows = []
    for file, obj, name, body_json in procs:
        for callee, call_type in walk_calls(json.loads(body_json)):
            if callee:
                rows.append((file, obj, name, callee, call_type))
        progress.advance_extract()
    if rows:
        conn.executemany("INSERT INTO calls VALUES (?, ?, ?, ?, ?)", rows)


def walk_calls(node) -> list[tuple[str, str]]:
    results = []
    if isinstance(node, dict):
        tag = node.get('tag')
        if tag == 'ExCall':
            segs = node.get('callee', {}).get('segments', [])
            if segs:
                results.append((segs[-1].get('name', ''), 'ExCall'))
        elif tag == 'ExMethodCall':
            results.append((node.get('method', ''), 'ExMethodCall'))
        elif tag == 'ExDispatch':
            name = node.get('contents', {}).get('name', '') or node.get('name', '')
            results.append((name, 'ExDispatch'))
        for v in node.values():
            results.extend(walk_calls(v))
    elif isinstance(node, list):
        for item in node:
            results.extend(walk_calls(item))
    return results


def count_branches(node) -> int:
    count = 0
    if isinstance(node, dict):
        if node.get('tag') in BRANCH_TAGS:
            count += 1
        for v in node.values():
            count += count_branches(v)
    elif isinstance(node, list):
        for item in node:
            count += count_branches(item)
    return count


def compute_cyclomatic(conn, progress: AnalyzeProgress) -> None:
    try:
        conn.execute("ALTER TABLE procedures ADD COLUMN cyclomatic INT DEFAULT 0")
    except Exception:
        conn.execute("UPDATE procedures SET cyclomatic = 0")

    procs = conn.execute(
        "SELECT rowid, body_json FROM procedures WHERE body_json IS NOT NULL"
    ).fetchall()
    rows = []
    for rowid, body_json in procs:
        cc = count_branches(json.loads(body_json)) + 1
        rows.append([cc, rowid])
        progress.advance_cyclomatic()
    if rows:
        conn.executemany("UPDATE procedures SET cyclomatic = ? WHERE rowid = ?", rows)


def compute_dit(conn) -> dict[str, int]:
    """Depth of inheritance tree: max hops from a base class (no parent)."""
    edges = conn.execute("SELECT from_object, to_object FROM inherits").fetchall()
    igraph = nx.DiGraph((parent, child) for child, parent in edges)
    roots = {n for n in igraph.nodes() if igraph.in_degree(n) == 0}
    dit: dict[str, int] = {n: 0 for n in igraph.nodes()}
    for root in roots:
        for node, depth in nx.single_source_shortest_path_length(igraph, root).items():
            dit[node] = max(dit.get(node, 0), depth)
    return dit


def compute_metrics(conn, progress: AnalyzeProgress) -> None:
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

    betweenness = nx.betweenness_centrality(G)
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
