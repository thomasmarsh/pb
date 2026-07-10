"""DOT/SVG diagram building and rendering (shell layer — I/O boundary)."""

from __future__ import annotations

import logging
import threading
from collections import OrderedDict
from typing import Any

import duckdb
import graphviz
import networkx as nx
from pb.lib.diagram_builder import (
    render_calls,
    render_dw_tables,
    render_fk_graph,
    render_heatmap,
    render_inheritance,
    render_lattice,
    render_proc_tables,
    render_sql_lineage,
    render_table_lineage,
)
from pb.pipeline.db import Conn
from pb.pipeline.jobs import JobRegistry, JobStatus
from pb.pipeline.lattice import compute_window_table_lattice

log = logging.getLogger(__name__)

_CACHE_MAX = 64
_svg_cache: OrderedDict[str, str] = OrderedDict()
_cache_lock = threading.Lock()  # guards _svg_cache -- job workers write from non-request threads
_job_registry = JobRegistry()


def _cache_key(kind: str, params: dict[str, Any]) -> str:
    parts = [f"{k}={v}" for k, v in sorted(params.items()) if k != "conn"]
    return kind + "|" + "|".join(parts)


_PLACEHOLDER_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="360" height="120">'
    '<rect width="100%" height="100%" fill="#2A2A2A"/>'
    '<text x="50%" y="50%" fill="#E8E8E8" font-size="13" text-anchor="middle" '
    'dominant-baseline="middle">Diagram unavailable (render failed)</text>'
    "</svg>"
)


def render_dot_to_svg(dot) -> str:
    """Render a graphviz object to SVG.

    A single attempt, no attribute-mutating retry ladder: the graph attrs a
    diagram builder requests (`pb.lib.diagram_builder`) must already be
    supported by any graphviz build -- e.g. never `overlap="prism"`, which
    needs a triangulation library many distro packages (Homebrew, several
    Linux distros) omit and reliably fails with "remove_overlap: Graphviz
    not built with triangulation library". Fix an unsupported default at
    the builder that requests it, not with a fallback here.

    What this function guarantees: it never raises for a rendering failure
    (a malformed graph, an unsupported engine feature, a crashing `dot`
    subprocess, ...) -- one bad diagram must not break the page it's
    embedded in. `graphviz.backend.execute.ExecutableNotFound` (the `dot`
    binary is missing entirely -- an infrastructure problem, not a
    rendering quirk) is the one exception still raised, so the route can
    report a clear 503 instead of silently hiding a missing dependency
    behind a placeholder image.

    Public (not `_`-prefixed): every graphviz.Digraph render in the codebase
    must go through this one guarantee. `pb.api.services.diagrams.get_cfg_diagram`
    builds its own `cfg_to_dot(...)` graph outside the `kind`-based builders
    dict below and calls this directly -- a previous version of that function
    called `dot.pipe()` itself with only an `ExecutableNotFound` guard, so the
    same triangulation-library failure that this function exists to contain
    took that endpoint down uncaught.
    """
    try:
        return dot.pipe(format="svg").decode("utf-8")
    except graphviz.backend.execute.ExecutableNotFound:
        raise
    except Exception:
        log.error("Diagram render failed; returning placeholder SVG", exc_info=True)
        return _PLACEHOLDER_SVG


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


_FK_EDGE_SQL = """
    SELECT DISTINCT
        fo.namespace AS from_namespace, fo.table_name AS from_table, fo.column_name AS from_column,
        t.namespace AS to_namespace, t.table_name AS to_table, t.column_name AS to_column
    FROM schema_morphisms m
    JOIN schema_objects fo ON fo.object_key = m.from_key
    JOIN schema_objects t ON t.object_key = m.to_key
    WHERE m.leg_kind = 'fk' AND m.leg_source = ?
"""


def build_fk_graph(conn: Conn) -> graphviz.Digraph:
    """Plan 153 D2: implied-FK graph, code (`dw_join`) vs DDL evidence.

    Mirrors `pb.api.services.schema.get_fk_graph`'s directed-pair-matching
    classification (duplicated rather than imported: `pipeline` never
    depends on `api`), dropping the constraint_name/dw_sources annotation
    lookups this diagram doesn't render.
    """
    ddl_rows = conn.execute(_FK_EDGE_SQL, ["ddl_fk"]).fetchall()
    dwj_rows = conn.execute(_FK_EDGE_SQL, ["dw_join"]).fetchall()

    def pair(row: tuple) -> tuple[tuple, tuple]:
        a = (row[0], row[1], row[2])
        b = (row[3], row[4], row[5])
        return (a, b)

    ddl_pairs = {pair(r) for r in ddl_rows}
    ddl_pairs_or_reverse = ddl_pairs | {(b, a) for a, b in ddl_pairs}
    dwj_pairs = {pair(r) for r in dwj_rows}
    dwj_pairs_or_reverse = dwj_pairs | {(b, a) for a, b in dwj_pairs}

    edges: list[tuple[str, str, str, str, str]] = []
    for r in dwj_rows:
        category = "corroborated" if pair(r) in ddl_pairs_or_reverse else "unenforced"
        edges.append((r[1], r[2], r[4], r[5], category))
    for r in ddl_rows:
        if pair(r) not in dwj_pairs_or_reverse:
            edges.append((r[1], r[2], r[4], r[5], "unused"))

    return render_fk_graph(edges)


def build_window_table_lattice(conn: Conn) -> graphviz.Digraph:
    """Plan 153 D7: window x table concept lattice, Hasse diagram.

    Shares its concepts/covers computation with `pb.api.services.schema.
    get_window_table_lattice` via `pb.pipeline.lattice` -- see that module's
    docstring for why the computation lives here rather than in `pb-api`.
    """
    lattice = compute_window_table_lattice(conn)
    return render_lattice(lattice["concepts"], lattice["covers"])


def render_svg(kind: str, conn: Conn, **params: Any) -> str:
    """Build and render a diagram to SVG with LRU caching.

    This is the single entry point for the explorer API. It handles
    cache lookup, dot object construction, rendering with Bezier fallback,
    and cache storage.
    """
    key = _cache_key(kind, params)
    with _cache_lock:
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
        "fk-graph": lambda: build_fk_graph(conn),
        "window-table-lattice": lambda: build_window_table_lattice(conn),
    }
    builder = builders.get(kind)
    if builder is None:
        raise ValueError(f"Unknown diagram: {kind}")

    dot = builder()
    svg = render_dot_to_svg(dot)

    with _cache_lock:
        _svg_cache[key] = svg
        if len(_svg_cache) > _CACHE_MAX:
            _svg_cache.popitem(last=False)

    return svg


def submit_diagram_job(kind: str, db_path: str, **params: Any) -> dict[str, Any]:
    """Plan 159: async entry point for GET /api/diagram/{kind}?async=1.

    Returns {"status": "done", "result": svg} immediately on an `_svg_cache`
    hit (no job created); otherwise submits a render to `_job_registry` and
    returns {"status": "pending", "jobId": ...}, attaching to an in-flight
    job for the same kind+params rather than duplicating the render.
    """
    key = _cache_key(kind, params)
    with _cache_lock:
        if key in _svg_cache:
            _svg_cache.move_to_end(key)
            return {"status": "done", "result": _svg_cache[key]}

    def render() -> str:
        # Own connection: the request-scoped `conn` from FastAPI's `get_db`
        # dependency is closed the instant the async endpoint returns --
        # long before (or while) this job thread is still running.
        conn = duckdb.connect(db_path, read_only=True)
        try:
            return render_svg(kind, conn, **params)
        finally:
            conn.close()

    job_id = _job_registry.submit(key, render)
    return {"status": "pending", "jobId": job_id}


def get_diagram_job(job_id: str) -> dict[str, Any] | None:
    """Plan 159: async entry point for GET /api/diagram-jobs/{jobId}.

    None if job_id is unknown (route maps this to 404).
    """
    job = _job_registry.get(job_id)
    if job is None:
        return None
    if job.status == JobStatus.PENDING:
        return {"status": "pending"}
    if job.status == JobStatus.DONE:
        return {"status": "done", "result": job.result}
    return {"status": "error", "error": job.error}
