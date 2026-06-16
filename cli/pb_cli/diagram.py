"""SVG diagram generators for pb.duckdb."""
import os
import sys
from contextlib import contextmanager

import duckdb
import graphviz
import networkx as nx

KIND_COLORS = {
    'powerscript': '#5B8DD9',
    'datawindow':  '#56A85D',
    'project':     '#B0B0B0',
}
KIND_DEFAULT = '#D0D0D0'

_GRADIENT = [
    '#FFFFB2', '#FECC5C', '#FD8D3C',
    '#F03B20', '#BD0026', '#7A0177',
    '#49006A', '#2D004B', '#0D0221',
]

GRAPH_ATTRS = {
    'bgcolor':   '#1C1C1E',
    'fontname':  'Helvetica Neue,Helvetica,Arial,sans-serif',
    'fontcolor': '#E8E8E8',
    'pad':       '0.4',
}
NODE_DEFAULTS = {
    'fontname':  'Helvetica Neue,Helvetica,Arial,sans-serif',
    'fontsize':  '9',
    'fontcolor': '#1C1C1E',
    'penwidth':  '0',
}
EDGE_DEFAULTS = {
    'color':     '#606060',
    'arrowsize': '0.6',
    'penwidth':  '0.8',
}


def complexity_color(cc: int) -> str:
    idx = min(cc // 3, len(_GRADIENT) - 1)
    return _GRADIENT[idx]


def kind_color(kind: str) -> str:
    return KIND_COLORS.get(kind, KIND_DEFAULT)


def open_db(db_path: str) -> duckdb.DuckDBPyConnection:
    if not os.path.exists(db_path):
        sys.exit(f"error: database not found: {db_path}")
    return duckdb.connect(db_path, read_only=True)


@contextmanager
def connect(db_path: str):
    conn = open_db(db_path)
    try:
        yield conn
    finally:
        conn.close()


def _render(dot: graphviz.Graph | graphviz.Digraph, output: str, emit_dot: bool) -> None:
    if emit_dot:
        print(dot.source)
        return
    dot.render(outfile=output, format='svg', cleanup=True)
    print(f"Written: {output}", file=sys.stderr)


def apply_defaults(dot, node_extra=None, edge_extra=None) -> None:
    dot.attr(**GRAPH_ATTRS)
    ne = {**NODE_DEFAULTS, **(node_extra or {})}
    ee = {**EDGE_DEFAULTS, **(edge_extra or {})}
    dot.attr('node', **ne)
    dot.attr('edge', **ee)


def build_inheritance(
    conn: duckdb.DuckDBPyConnection,
    root: str | None = None,
) -> graphviz.Digraph:
    if root:
        edges = conn.execute("""
            WITH RECURSIVE sub AS (
                SELECT from_object, to_object FROM inherits WHERE to_object = ?
                UNION ALL
                SELECT i.from_object, i.to_object
                FROM inherits i JOIN sub s ON i.to_object = s.from_object
            )
            SELECT DISTINCT from_object, to_object FROM sub
        """, [root]).fetchall()
    else:
        edges = conn.execute(
            "SELECT from_object, to_object FROM inherits"
        ).fetchall()

    kind_map = dict(conn.execute("SELECT name, kind FROM objects").fetchall())

    dot = graphviz.Digraph(engine='dot', name='inheritance')
    apply_defaults(dot)
    dot.attr(rankdir='TB', splines='ortho', nodesep='0.3', ranksep='0.6')
    dot.attr('edge', color='#8888AA', arrowsize='0.5', penwidth='0.7')

    seen: set[str] = set()
    for src, dst in edges:
        for name in (src, dst):
            if name not in seen:
                kind = kind_map.get(name, '')
                fill = kind_color(kind)
                shape = 'box' if kind == 'datawindow' else 'ellipse'
                dot.node(
                    name,
                    shape=shape, style='filled,rounded',
                    fillcolor=fill,
                    tooltip=f"{name} [{kind}]",
                )
                seen.add(name)
        dot.edge(src, dst)

    if root and root not in seen:
        kind = kind_map.get(root, '')
        dot.node(root, shape='doubleoctagon', style='filled',
                 fillcolor='#FFD700', fontcolor='#1C1C1E',
                 tooltip=f"{root} [root]")

    return dot


def diagram_inheritance(
    conn: duckdb.DuckDBPyConnection,
    root: str | None,
    output: str = 'inheritance.svg',
    emit_dot: bool = False,
) -> None:
    dot = build_inheritance(conn, root)
    _render(dot, output, emit_dot)


def build_calls(
    conn: duckdb.DuckDBPyConnection,
    focal: str = '',
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

    cc_map: dict[str, int] = dict(conn.execute(
        "SELECT name, max(cyclomatic) FROM procedures GROUP BY name"
    ).fetchall())

    dot = graphviz.Digraph(engine='fdp', name='calls')
    apply_defaults(dot)
    dot.attr(overlap='false', splines='curved', K='0.8')

    for name in sub_nodes:
        cc = cc_map.get(name) or 0
        is_focal = (name == focal)
        fill = '#FFD700' if is_focal else complexity_color(cc)
        shape = 'doublecircle' if is_focal else 'ellipse'
        width = '1.4' if is_focal else str(max(0.5, min(0.5 + cc / 8, 1.8)))
        label = f"{name}\\ncc={cc}" if cc > 3 else name
        dot.node(
            name,
            label=label, shape=shape,
            style='filled', fillcolor=fill, fontcolor='#1C1C1E',
            width=width, height=width, fixedsize='false',
            tooltip=f"{name} [cc={cc}]",
        )

    for u, v in sub_edges:
        if u == focal or v == focal:
            dot.edge(u, v, color='#FFD700AA', penwidth='1.2')
        else:
            dot.edge(u, v)

    return dot


def diagram_calls(
    conn: duckdb.DuckDBPyConnection,
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
    conn: duckdb.DuckDBPyConnection,
    filter_table: str | None = None,
) -> graphviz.Digraph:
    rows = conn.execute("""
        SELECT dw_name, table_name FROM dw_retrieve_tables
        WHERE (? IS NULL) OR table_name = ?
        ORDER BY dw_name, table_name
    """, [filter_table, filter_table]).fetchall()

    dw_names  = sorted({r[0] for r in rows})
    tbl_names = sorted({r[1] for r in rows})

    count_map: dict[str, int] = dict(conn.execute(
        "SELECT dw_name, count(*) FROM dw_retrieve_tables GROUP BY dw_name"
    ).fetchall())

    dot = graphviz.Digraph(engine='dot', name='dw_tables')
    apply_defaults(dot, node_extra={'shape': 'box'})
    dot.attr(rankdir='LR', splines='ortho', nodesep='0.2', ranksep='1.2')

    with dot.subgraph(name='cluster_dw') as c:  # pyright: ignore[reportOptionalContextManager]
        c.attr(
            label='DataWindows', style='rounded',
            color='#5B8DD9', fontcolor='#E8E8E8', bgcolor='#2A2A3A',
        )
        for dw in dw_names:
            nc = count_map.get(dw, 1)
            fill = complexity_color(nc - 1)
            c.node(
                f"dw_{dw}", label=dw,
                shape='box', style='filled,rounded',
                fillcolor=fill, fontsize='8',
                tooltip=f"{dw} ({nc} tables)",
            )

    with dot.subgraph(name='cluster_tables') as c:  # pyright: ignore[reportOptionalContextManager]
        c.attr(
            label='DB Tables', style='rounded',
            color='#56A85D', fontcolor='#E8E8E8', bgcolor='#1F2F1F',
        )
        for tbl in tbl_names:
            c.node(
                f"t_{tbl}", label=tbl,
                shape='cylinder', style='filled',
                fillcolor='#2E5E32', fontcolor='#C8F0CA', fontsize='8',
                tooltip=tbl,
            )

    for dw, tbl in rows:
        dot.edge(f"dw_{dw}", f"t_{tbl}",
                 color='#56A85D88', arrowsize='0.5', penwidth='0.7')

    return dot


def diagram_dw_tables(
    conn: duckdb.DuckDBPyConnection,
    filter_table: str | None = None,
    output: str = 'dw_tables.svg',
    emit_dot: bool = False,
) -> None:
    dot = build_dw_tables(conn, filter_table)
    _render(dot, output, emit_dot)


def build_heatmap(
    conn: duckdb.DuckDBPyConnection,
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

    inherit_edges = conn.execute(
        "SELECT from_object, to_object FROM inherits"
    ).fetchall()

    dot = graphviz.Graph(engine='sfdp', name='heatmap')
    apply_defaults(dot)
    dot.attr(
        overlap='prism', splines='curved',
        outputorder='edgesfirst', K='1.2',
    )
    dot.attr('edge', style='invis')

    for name, kind, cc, fan_in in rows:
        fill = complexity_color(cc)
        size_f = round(max(0.3, min(fan_in / 15 + 0.35, 2.4)), 2)
        size = str(size_f)
        show_label = size_f >= 0.7 and (cc >= 5 or fan_in >= 10)
        label = name if show_label else ''
        fsize = '8' if show_label else '0'
        dot.node(
            name,
            label=label, shape='circle',
            style='filled', fillcolor=fill, fontcolor='#FFFFFFCC',
            width=size, height=size, fixedsize='true',
            fontsize=fsize,
            tooltip=f"{name}  cc={cc}  fan-in={fan_in}",
        )

    for src, dst in inherit_edges:
        dot.edge(src, dst)

    with dot.subgraph(name='cluster_legend') as lg:  # pyright: ignore[reportOptionalContextManager]
        lg.attr(
            label='Cyclomatic complexity',
            style='rounded', color='#555555',
            bgcolor='#2A2A2A', fontcolor='#E8E8E8',
            fontsize='9',
        )
        prev = 'legend_anchor'
        lg.node(prev, style='invis', width='0', height='0', label='')
        for i, (label, fill) in enumerate([
            ('0–2', _GRADIENT[0]),
            ('3–5', _GRADIENT[1]),
            ('6–8', _GRADIENT[2]),
            ('9+',  _GRADIENT[4]),
        ]):
            nid = f"legend_{i}"
            lg.node(
                nid, label=label,
                shape='circle', style='filled', fillcolor=fill,
                fontcolor='#1C1C1E', fontsize='7', width='0.5', height='0.5',
            )
            lg.edge(prev, nid, style='invis')
            prev = nid

    return dot


def diagram_heatmap(
    conn: duckdb.DuckDBPyConnection,
    output: str = 'heatmap.svg',
    emit_dot: bool = False,
) -> None:
    dot = build_heatmap(conn)
    _render(dot, output, emit_dot)
