"""
pb analyze — compute graph metrics and populate object_metrics in pb.duckdb.

Usage (CLI):
    pb analyze [DB]

Library:
    from pbtools.analyze import run
"""
import json

import duckdb
import networkx as nx


BRANCH_TAGS = {'if', 'for', 'do', 'choose'}


def run(db: str = 'pb.duckdb', console=None) -> None:
    if console is None:
        from rich.console import Console
        console = Console(stderr=True)
    conn = duckdb.connect(db)
    _step(console, 1, 3, "Extracting call graph",           extract_calls,      conn)
    _step(console, 2, 3, "Computing cyclomatic complexity", compute_cyclomatic, conn)
    _step(console, 3, 3, "Computing graph metrics",         compute_metrics,    conn)
    conn.close()


def _step(console, i: int, total: int, name: str, fn, *args) -> None:
    with console.status(f"[dim][{i}/{total}] {name}...[/dim]"):
        fn(*args)
    console.print(f"[dim][{i}/{total}] {name}[/dim] [green]✓[/green]")


def extract_calls(conn: duckdb.DuckDBPyConnection) -> None:
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
        body = json.loads(body_json)
        for callee, call_type in walk_calls(body):
            if callee:
                rows.append((file, obj, name, callee, call_type))
    if rows:
        conn.executemany("INSERT INTO calls VALUES (?, ?, ?, ?, ?)", rows)


def walk_calls(node) -> list[tuple[str, str]]:
    results = []
    if isinstance(node, dict):
        tag = node.get('tag')
        if tag == 'call_expr':
            segs = node.get('callee', {}).get('segments', [])
            if segs:
                results.append((segs[-1].get('name', ''), 'call_expr'))
        elif tag == 'method_call':
            results.append((node.get('method', ''), 'method_call'))
        elif tag == 'dispatch':
            results.append((node.get('name', ''), 'dispatch'))
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


def compute_cyclomatic(conn: duckdb.DuckDBPyConnection) -> None:
    try:
        conn.execute("ALTER TABLE procedures ADD COLUMN cyclomatic INT DEFAULT 0")
    except Exception:
        conn.execute("UPDATE procedures SET cyclomatic = 0")

    procs = conn.execute(
        "SELECT rowid, body_json FROM procedures WHERE body_json IS NOT NULL"
    ).fetchall()
    for rowid, body_json in procs:
        body = json.loads(body_json)
        cc = count_branches(body) + 1
        conn.execute("UPDATE procedures SET cyclomatic = ? WHERE rowid = ?", [cc, rowid])


def compute_dit(conn: duckdb.DuckDBPyConnection) -> dict[str, int]:
    """Depth of inheritance tree: max hops from a base class (no parent)."""
    edges = conn.execute("SELECT from_object, to_object FROM inherits").fetchall()
    I = nx.DiGraph((parent, child) for child, parent in edges)
    roots = {n for n in I.nodes() if I.in_degree(n) == 0}
    dit: dict[str, int] = {n: 0 for n in I.nodes()}
    for root in roots:
        for node, depth in nx.single_source_shortest_path_length(I, root).items():
            dit[node] = max(dit.get(node, 0), depth)
    return dit


def compute_metrics(conn: duckdb.DuckDBPyConnection) -> None:
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

    if not G.nodes():
        return

    betweenness = nx.betweenness_centrality(G)
    pr = nx.pagerank(G, alpha=0.85)

    cyc = conn.execute("""
        SELECT object, max(cyclomatic), avg(cyclomatic)
        FROM procedures
        WHERE cyclomatic IS NOT NULL AND cyclomatic > 0
        GROUP BY object
    """).fetchall()
    cyc_map = {obj: (int(max_c), float(avg_c)) for obj, max_c, avg_c in cyc}

    dit_map = compute_dit(conn)

    rows = []
    for node in G.nodes():
        max_c, avg_c = cyc_map.get(node, (None, None))
        rows.append((
            node,
            G.in_degree(node),
            G.out_degree(node),
            betweenness.get(node, 0.0),
            pr.get(node, 0.0),
            max_c,
            avg_c,
            dit_map.get(node),
            None,  # CBO deferred
        ))

    if rows:
        conn.executemany("INSERT INTO object_metrics VALUES (?,?,?,?,?,?,?,?,?)", rows)
