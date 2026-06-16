"""DB-boundary module: the only module that imports `duckdb`.

Schema management, connection handling, ingest, state persistence, graph
metric computation, and diagram I/O all live here — every other module
imports from `storage.py` for DB access rather than opening a connection
directly.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
from collections.abc import Generator, Iterable
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Callable

import duckdb
import graphviz
import networkx as nx

from pb_cli.core.diagram_builder import (
    _GRADIENT,
    apply_defaults,
    complexity_color,
    kind_color,
)
from pb_cli.core.ingestion import ingest_file
from pb_cli.core.models import TABLES, new_row_batch

if TYPE_CHECKING:
    from pb_cli.reporter import AnalyzeProgress

Conn = duckdb.DuckDBPyConnection


@contextmanager
def db_connection(path: str | Path, read_only: bool = False) -> Generator[Conn, None, None]:
    conn = duckdb.connect(str(path), read_only=read_only)
    try:
        yield conn
    finally:
        conn.close()


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS objects (
    file        TEXT NOT NULL,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    ancestor    TEXT,
    source_text TEXT
);

CREATE TABLE IF NOT EXISTS procedures (
    file             TEXT NOT NULL,
    object           TEXT NOT NULL,
    proc_type        TEXT NOT NULL,
    name             TEXT NOT NULL,
    modifiers        TEXT,
    params           TEXT,
    return_type      TEXT,
    start_line       INT,
    end_line         INT,
    body_json        JSON,
    source_rendered  TEXT,
    cyclomatic       INT
);

CREATE TABLE IF NOT EXISTS calls (
    file       TEXT,
    object     TEXT,
    from_proc  TEXT,
    to_name    TEXT,
    call_type  TEXT
);

CREATE TABLE IF NOT EXISTS dw_controls (
    file         TEXT NOT NULL,
    dw_name      TEXT NOT NULL,
    control_name TEXT,
    control_type TEXT,
    band         TEXT,
    x            INT,
    y            INT,
    width        INT,
    height       INT,
    expression   TEXT,
    tab_seq      INT,
    source_line  INT
);

CREATE TABLE IF NOT EXISTS dw_retrieve_tables (
    file       TEXT NOT NULL,
    dw_name    TEXT NOT NULL,
    table_name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dw_retrieve_columns (
    file        TEXT NOT NULL,
    dw_name     TEXT NOT NULL,
    column_fqn  TEXT NOT NULL,
    table_name  TEXT,
    column_name TEXT
);

CREATE TABLE IF NOT EXISTS dw_retrieve_where (
    file    TEXT NOT NULL,
    dw_name TEXT NOT NULL,
    idx     INT  NOT NULL,
    exp1    TEXT,
    op      TEXT,
    exp2    TEXT,
    logic   TEXT
);

CREATE TABLE IF NOT EXISTS dw_arguments (
    file     TEXT NOT NULL,
    dw_name  TEXT NOT NULL,
    arg_name TEXT NOT NULL,
    arg_type TEXT
);

CREATE TABLE IF NOT EXISTS inherits (
    from_object TEXT NOT NULL,
    to_object   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sql_statements (
    file        TEXT NOT NULL,
    object      TEXT NOT NULL,
    proc_name   TEXT NOT NULL,
    stmt_idx    INT  NOT NULL,
    operation   TEXT,
    raw_sql     TEXT,
    parsed_json JSON,
    tables      TEXT[],
    columns     TEXT[],
    has_into    BOOLEAN,
    has_cursor  BOOLEAN,
    parse_ok    BOOLEAN
);
"""

_ALL_SQL_TABLES_VIEW = """
CREATE OR REPLACE VIEW all_sql_tables AS
    SELECT
        t.file,
        t.dw_name   AS object,
        'datawindow' AS source,
        'retrieve'   AS operation,
        t.table_name,
        NULL         AS proc_name,
        NULL::INT    AS stmt_idx
    FROM dw_retrieve_tables t

    UNION ALL

    SELECT
        s.file,
        s.object,
        'powerscript' AS source,
        s.operation,
        unnest(s.tables) AS table_name,
        s.proc_name,
        s.stmt_idx
    FROM sql_statements s
    WHERE s.tables IS NOT NULL AND len(s.tables) > 0
"""

INSERT = {
    'objects':             'INSERT INTO objects VALUES (?,?,?,?,?)',
    'procedures':          'INSERT INTO procedures VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
    'calls':               'INSERT INTO calls VALUES (?,?,?,?,?)',
    'dw_controls':         'INSERT INTO dw_controls VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
    'dw_retrieve_tables':  'INSERT INTO dw_retrieve_tables VALUES (?,?,?)',
    'dw_retrieve_columns': 'INSERT INTO dw_retrieve_columns VALUES (?,?,?,?,?)',
    'dw_retrieve_where':   'INSERT INTO dw_retrieve_where VALUES (?,?,?,?,?,?,?)',
    'dw_arguments':        'INSERT INTO dw_arguments VALUES (?,?,?,?)',
    'inherits':            'INSERT INTO inherits VALUES (?,?)',
    'sql_statements':      'INSERT INTO sql_statements VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
}


def create_schema(conn: Conn) -> None:
    for stmt in SCHEMA_SQL.split(';'):
        stmt = stmt.strip()
        if stmt:
            conn.execute(stmt)
    conn.execute(_ALL_SQL_TABLES_VIEW)


def drop_tables(conn: Conn) -> None:
    """Drop all data tables and file_state (full reset)."""
    conn.execute("DROP VIEW IF EXISTS all_sql_tables")
    for t in TABLES + ['file_state']:
        conn.execute(f"DROP TABLE IF EXISTS {t}")


# ── Ingest ───────────────────────────────────────────────────────────────────

def run_from_jsonl_lines(
    lines: Iterable[str], db: str = 'pb.duckdb', dialect: str = 'oracle'
) -> None:
    rows = new_row_batch()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        ingest_file(obj, rows, dialect)

    with db_connection(db) as conn:
        create_schema(conn)
        for table in TABLES:
            data = rows[table]
            if data:
                conn.executemany(INSERT[table], data)

    total = sum(len(rows[t]) for t in TABLES)
    print(f"Indexed {total} rows into {db}", file=sys.stderr)


_CHUNK = 5000


def ingest_batch(
    objects: Iterable[dict], conn: Conn, dialect: str = 'oracle',
    on_progress: Callable[[int], None] | None = None,
) -> int:
    """Ingest an iterable of parsed file dicts into an open connection. Returns row count."""
    rows = new_row_batch()
    for obj in objects:
        ingest_file(obj, rows, dialect)
    total = 0
    conn.execute("BEGIN")
    try:
        for table in TABLES:
            data = rows[table]
            for i in range(0, len(data), _CHUNK):
                chunk = data[i:i + _CHUNK]
                conn.executemany(INSERT[table], chunk)
                total += len(chunk)
                if on_progress:
                    on_progress(len(chunk))
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return total


# ── Incremental state ───────────────────────────────────────────────────────

FILE_STATE_SQL = """
CREATE TABLE IF NOT EXISTS file_state (
    file      TEXT PRIMARY KEY,
    sha256    TEXT NOT NULL,
    parsed_at TEXT NOT NULL
);
"""


def create_state_table(conn: Conn) -> None:
    conn.execute(FILE_STATE_SQL)


def load_file_state(conn: Conn) -> dict[str, str]:
    """Return {file: sha256} from file_state. Returns empty dict if table is missing."""
    try:
        rows = conn.execute("SELECT file, sha256 FROM file_state").fetchall()
        return {r[0]: r[1] for r in rows}
    except Exception:
        return {}


def delete_file_rows(conn: Conn, file_path: str) -> None:
    """Remove all DB rows for a source file (data tables + inherits + file_state)."""
    # Fetch object names before deleting from objects table
    objs = conn.execute(
        "SELECT name FROM objects WHERE file = ?", [file_path]
    ).fetchall()
    obj_names = [r[0] for r in objs]

    for table in TABLES:
        if table == 'inherits':
            continue
        conn.execute(f"DELETE FROM {table} WHERE file = ?", [file_path])

    if obj_names:
        placeholders = ','.join('?' * len(obj_names))
        conn.execute(
            f"DELETE FROM inherits WHERE from_object IN ({placeholders})", obj_names
        )

    conn.execute("DELETE FROM file_state WHERE file = ?", [file_path])


def save_file_state(conn: Conn, file_states: dict[str, str]) -> None:
    """Insert or replace file state entries."""
    now = datetime.now(timezone.utc).isoformat()
    for file_path, sha in file_states.items():
        conn.execute("DELETE FROM file_state WHERE file = ?", [file_path])
    rows = [(f, h, now) for f, h in file_states.items()]
    if rows:
        conn.executemany("INSERT INTO file_state VALUES (?, ?, ?)", rows)


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


def build_subset_tmpdir(src_dir: Path, files: list[str]) -> Path:
    """
    Copy a subset of source files into a fresh tmpdir preserving relative paths.
    Uses hard links where possible, falls back to shutil.copy2 for cross-volume.
    Caller must clean up the returned directory (shutil.rmtree).
    """
    tmpdir = Path(tempfile.mkdtemp())
    for abs_path in files:
        src = Path(abs_path)
        try:
            rel = src.relative_to(src_dir)
        except ValueError:
            rel = Path(src.name)
        dst = tmpdir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)
    return tmpdir


# ── SQL-file query parsing ──────────────────────────────────────────────────

def parse_sql_file(path: Path) -> tuple[str, list[tuple[str, str, str | None]], str]:
    """Return (description, params, sql).

    Leading comment block is consumed; remainder is executed verbatim.
    Param lines: ``-- :name TYPE [default]``
    """
    lines = path.read_text().splitlines()
    description = ""
    params: list[tuple[str, str, str | None]] = []
    sql_start = len(lines)
    for i, raw in enumerate(lines):
        line = raw.strip()
        if not line.startswith("--"):
            sql_start = i
            break
        m = re.match(r"^--\s+:(\w+)\s+(\w+)(?:\s+(\S+))?$", line)
        if m:
            pname, ptype, pdefault = m.groups()
            params.append((pname, ptype.upper(), pdefault))
        elif not description:
            description = line.lstrip("-").strip()
    return description, params, "\n".join(lines[sql_start:]).strip()


# ── Diagram I/O ──────────────────────────────────────────────────────────────

def open_db(db_path: str) -> Conn:
    if not os.path.exists(db_path):
        sys.exit(f"error: database not found: {db_path}")
    return duckdb.connect(db_path, read_only=True)


@contextmanager
def connect(db_path: str) -> Generator[Conn, None, None]:
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


def build_inheritance(
    conn: Conn,
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
    conn: Conn,
    root: str | None,
    output: str = 'inheritance.svg',
    emit_dot: bool = False,
) -> None:
    dot = build_inheritance(conn, root)
    _render(dot, output, emit_dot)


def build_calls(
    conn: Conn,
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
    conn: Conn,
    filter_table: str | None = None,
    output: str = 'dw_tables.svg',
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
    conn: Conn,
    output: str = 'heatmap.svg',
    emit_dot: bool = False,
) -> None:
    dot = build_heatmap(conn)
    _render(dot, output, emit_dot)
