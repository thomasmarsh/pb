"""`Sch` consumers (Plan 153 D1 + D2 + D3 + D4 + D5 + D6 + D7) — co-update
rituals, implied-FK graph, column-affinity clustering, decomposition-
candidate ranking, column-usage classification, statement-management views,
and the window x table concept lattice.

Pure presentation over Plan 148's schema_objects/schema_morphisms/catalog_*/
sql_statement_columns tables, plus (D5 only) Plan 153 D5's
decomposition_coslice table — the one traversal-derived table in this file,
materialized by the Haskell pass `PB.Pipeline.Passes.runPass10` via
`PB.Analysis.SchemaCategory.columnCoslice`. D5 never recomputes reachability
in Python or SQL; it only reads the pre-computed rows. D7 reads
`objects`/`all_sql_tables`/`dw_retrieve_tables` directly — it predates `Sch`
and doesn't need it (table-granularity, not column-granularity).
"""

from __future__ import annotations

from collections import defaultdict
from itertools import combinations
from typing import Any

import duckdb
from pb.api.routes.dependencies import rows
from pb.pipeline.lattice import compute_window_table_lattice

ColumnKey = tuple[str | None, str, str]


def _norm(s: str | None) -> str | None:
    """Table/column/namespace identifiers are always lowercased on ingestion
    (both the DDL catalog and SQL-derived TableRef -- see PB.Pipeline.SqlParse's
    TableRef doc comment). Route params arrive in whatever case the caller used,
    so every lookup against catalog_columns/schema_objects/sql_statement_columns
    must normalize here first or it silently matches zero rows."""
    return s.lower() if s is not None else None


def _column_key_sort(c: ColumnKey) -> tuple[str, str, str]:
    """`ColumnKey`'s namespace is `None` for an unqualified column (common for
    DW-retrieve columns) and a string for a schema-qualified one (common for
    catalog/SQL-derived columns) -- the same corpus mixes both, and plain
    `sorted()` on tuples raises TypeError comparing None < str."""
    return (c[0] or "", c[1], c[2])


def _column_ref(row: dict[str, Any], prefix: str) -> dict[str, Any]:
    return {
        "namespace": row[f"{prefix}_namespace"],
        "table": row[f"{prefix}_table"],
        "column": row[f"{prefix}_column"],
    }


def _canon(a: ColumnKey, b: ColumnKey) -> tuple[ColumnKey, ColumnKey]:
    return (a, b) if _column_key_sort(a) <= _column_key_sort(b) else (b, a)


def _edge_key(row: dict[str, Any]) -> tuple[ColumnKey, ColumnKey]:
    a: ColumnKey = (row["from_namespace"], row["from_table"], row["from_column"])
    b: ColumnKey = (row["to_namespace"], row["to_table"], row["to_column"])
    return _canon(a, b)


def _column_ref_from_key(col: ColumnKey) -> dict[str, Any]:
    return {"namespace": col[0], "table": col[1], "column": col[2]}


def _stmt_ref(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "file": row["stmt_file"],
        "object": row["stmt_object"],
        "proc_name": row["stmt_proc"],
        "line": row["stmt_line"],
    }


_CO_WRITE_SQL = """
    SELECT m.from_key AS stmt_key,
           o.stmt_file, o.stmt_object, o.stmt_proc, o.stmt_line,
           c.namespace, c.table_name, c.column_name
    FROM schema_morphisms m
    JOIN schema_objects o ON o.object_key = m.from_key
    JOIN schema_objects c ON c.object_key = m.to_key
    WHERE m.leg_kind = 'writes' AND m.leg_source != 'dw_retrieve'
"""


def get_co_update_rituals(conn: duckdb.DuckDBPyConnection, min_support: int = 2) -> dict[str, Any]:
    """D1: co-update rituals & violations.

    A ritual is a column pair written together by at least `min_support`
    distinct statements. A violation is a statement that writes exactly one
    column of an established ritual pair, breaking the convention. Computed
    in Python over the `writes` leg set (74 rows corpus-wide) rather than a
    nested SQL self-join — the set-difference logic is clearer this way and
    the data volume doesn't warrant pushing it back into SQL (see this
    deliverable's own "promote to a pass only if scoring outgrows SQL" note).

    `leg_source != 'dw_retrieve'` (Plan 163 Phase 6, wiring DW update-table
    writes into schema_morphisms -- see doc/plan/163-unified-statement-
    footprint.md's "Open questions" for the full design rationale, not just
    this docstring): a PS `UPDATE`/`SetItem` write is a *runtime* fact --
    this code path chose to change these columns together, right now. A
    DataWindow's `update=yes` column set is a *design-time* fact instead --
    the form treats these columns as one editable unit -- and PowerBuilder's
    generated Update() SQL rewrites its whole SET clause from the current
    buffer on every save regardless of which field the user actually
    touched, so it can never tell you "these changed together in this save"
    the way a PS write does. That's real evidence, just evidence of a
    different thing (UI/schema grouping, not a business-logic convention) --
    not noise to be discarded, but not the same signal `co_write_support`
    was built to measure either. Blending the two costs real information:
    it did not just add DW-derived rituals, it inflated this corpus's count
    from 45 to 1685 and its (previously zero, genuinely verified) violation
    count to 1092, because ordinary single-column PS `UPDATE`s started
    "violating" rituals that only existed because some unrelated DW form
    happened to bind that column alongside others. Excluding DW writes here
    keeps this specific signal meaningful; the DW-grouping signal itself
    isn't lost, just not surfaced through this query -- DW writes are still
    fully visible via get_footprint, get_column_usage, and blast_radius
    (which read schema_morphisms directly), and a future session could
    surface "DW co-edit groups" as its own first-class concept rather than
    folding it into this one.
    """
    write_rows = rows(conn.execute(_CO_WRITE_SQL))

    stmts_by_col: dict[ColumnKey, set[str]] = defaultdict(set)
    stmt_ref: dict[str, dict[str, Any]] = {}
    for r in write_rows:
        col: ColumnKey = (r["namespace"], r["table_name"], r["column_name"])
        stmts_by_col[col].add(r["stmt_key"])
        stmt_ref[r["stmt_key"]] = _stmt_ref(r)

    cols = sorted(stmts_by_col, key=_column_key_sort)
    rituals: list[dict[str, Any]] = []
    for i, c1 in enumerate(cols):
        for c2 in cols[i + 1 :]:
            both = stmts_by_col[c1] & stmts_by_col[c2]
            if len(both) < min_support:
                continue
            violations = [
                {**stmt_ref[s], "written_column": _column_ref_from_key(c1)}
                for s in sorted(stmts_by_col[c1] - stmts_by_col[c2])
            ] + [
                {**stmt_ref[s], "written_column": _column_ref_from_key(c2)}
                for s in sorted(stmts_by_col[c2] - stmts_by_col[c1])
            ]
            rituals.append(
                {
                    "column_a": _column_ref_from_key(c1),
                    "column_b": _column_ref_from_key(c2),
                    "co_write_support": len(both),
                    "violations": violations,
                }
            )

    rituals.sort(key=lambda r: -r["co_write_support"])
    return {"rituals": rituals}


_FK_EDGE_SQL = """
    SELECT DISTINCT
        fo.namespace AS from_namespace, fo.table_name AS from_table, fo.column_name AS from_column,
        t.namespace AS to_namespace, t.table_name AS to_table, t.column_name AS to_column
    FROM schema_morphisms m
    JOIN schema_objects fo ON fo.object_key = m.from_key
    JOIN schema_objects t ON t.object_key = m.to_key
    WHERE m.leg_kind = 'fk' AND m.leg_source = ?
"""


def _pair(row: dict[str, Any]) -> tuple[ColumnKey, ColumnKey]:
    a: ColumnKey = (row["from_namespace"], row["from_table"], row["from_column"])
    b: ColumnKey = (row["to_namespace"], row["to_table"], row["to_column"])
    return (a, b)


def get_fk_graph(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    # NOTE: edges are matched as raw, directed (from_key, to_key) pairs, testing
    # existence in *either* direction — not deduped to a canonical undirected
    # pair first. Two different DW files can join the same physical column pair
    # with LEFT/RIGHT swapped, producing two distinct directed rows in
    # schema_morphisms for one real relationship; collapsing those before
    # counting undercounts "corroborated" relative to the D2 spike's own query
    # (which this test suite's exact counts are pinned to).
    ddl_edges = rows(conn.execute(_FK_EDGE_SQL, ["ddl_fk"]))
    dwj_edges = rows(conn.execute(_FK_EDGE_SQL, ["dw_join"]))

    ddl_pairs = {_pair(r) for r in ddl_edges}
    ddl_pairs_or_reverse = ddl_pairs | {(b, a) for a, b in ddl_pairs}
    dwj_pairs = {_pair(r) for r in dwj_edges}
    dwj_pairs_or_reverse = dwj_pairs | {(b, a) for a, b in dwj_pairs}

    constraint_by_key: dict[tuple[ColumnKey, ColumnKey], str | None] = {}
    for r in rows(
        conn.execute(
            "SELECT constraint_name, from_namespace, from_table, from_column, "
            "to_namespace, to_table, to_column FROM catalog_fks"
        )
    ):
        a: ColumnKey = (r["from_namespace"], r["from_table"], r["from_column"])
        b: ColumnKey = (r["to_namespace"], r["to_table"], r["to_column"])
        key = _canon(a, b)
        constraint_by_key.setdefault(key, r["constraint_name"])

    dw_sources_by_key: dict[tuple[ColumnKey, ColumnKey], list[dict[str, str]]] = defaultdict(list)
    for r in rows(conn.execute("SELECT file, dw_name, left_ref, right_ref FROM dw_joins")):
        lt, lc = r["left_ref"].rsplit(".", 1)
        rt, rc = r["right_ref"].rsplit(".", 1)
        key = _canon((None, lt, lc), (None, rt, rc))
        dw_sources_by_key[key].append({"file": r["file"], "dw_name": r["dw_name"]})

    def _build_entry(row: dict[str, Any]) -> dict[str, Any]:
        key = _edge_key(row)
        return {
            "from_column": _column_ref(row, "from"),
            "to_column": _column_ref(row, "to"),
            "constraint_name": constraint_by_key.get(key),
            "dw_sources": dw_sources_by_key.get(key, []),
        }

    corroborated = [_build_entry(r) for r in dwj_edges if _pair(r) in ddl_pairs_or_reverse]
    unenforced = [_build_entry(r) for r in dwj_edges if _pair(r) not in ddl_pairs_or_reverse]
    unused = [_build_entry(r) for r in ddl_edges if _pair(r) not in dwj_pairs_or_reverse]

    return {"corroborated": corroborated, "unenforced": unenforced, "unused": unused}


_COLUMN_USAGE_SQL = """
    WITH cat AS (
        SELECT DISTINCT namespace, table_name, column_name FROM catalog_columns
    ), write_touch AS (
        SELECT DISTINCT o.namespace, o.table_name, o.column_name
        FROM schema_morphisms m JOIN schema_objects o ON o.object_key = m.to_key
        WHERE m.leg_kind = 'writes'
    ), read_touch AS (
        SELECT namespace, table_name, column_name FROM (
            SELECT o.namespace, o.table_name, o.column_name
            FROM schema_morphisms m JOIN schema_objects o ON o.object_key = m.from_key
            WHERE m.leg_kind = 'reads'
            UNION
            SELECT o.namespace, o.table_name, o.column_name
            FROM schema_morphisms m JOIN schema_objects o ON o.object_key = m.to_key
            WHERE m.leg_kind = 'retrieve'
        )
    )
    SELECT c.namespace, c.table_name, c.column_name,
           (w.table_name IS NOT NULL) AS has_write,
           (r.table_name IS NOT NULL) AS has_read
    FROM cat c
    LEFT JOIN write_touch w
      ON w.namespace IS NOT DISTINCT FROM c.namespace
     AND w.table_name = c.table_name AND w.column_name = c.column_name
    LEFT JOIN read_touch r
      ON r.namespace IS NOT DISTINCT FROM c.namespace
     AND r.table_name = c.table_name AND r.column_name = c.column_name
"""


def get_column_usage(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    # Three-way classification (D4): every catalog column, bucketed by
    # whether any schema_morphisms leg ever reads or writes it. Catalog-only
    # columns join to NULL on both sides ("dead").
    result: dict[str, list[dict[str, Any]]] = {
        "dead": [],
        "write_only": [],
        "read_only": [],
        "read_write": [],
    }
    for r in rows(conn.execute(_COLUMN_USAGE_SQL)):
        ref = {"namespace": r["namespace"], "table": r["table_name"], "column": r["column_name"]}
        has_write, has_read = r["has_write"], r["has_read"]
        if has_write and has_read:
            result["read_write"].append(ref)
        elif has_write:
            result["write_only"].append(ref)
        elif has_read:
            result["read_only"].append(ref)
        else:
            result["dead"].append(ref)
    return result


_FOOTPRINT_LEGS_SQL = """
    SELECT s.object_key AS stmt_key,
           m.leg_kind, m.leg_source,
           o.namespace, o.table_name, o.column_name
    FROM schema_objects s
    JOIN schema_morphisms m ON m.from_key = s.object_key OR m.to_key = s.object_key
    JOIN schema_objects o ON o.object_key = (CASE WHEN m.from_key = s.object_key THEN m.to_key ELSE m.from_key END)
    WHERE s.object_key IN ({placeholders})
    ORDER BY s.object_key, m.leg_kind, o.table_name, o.column_name
"""


def get_footprint(
    conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str | None = None
) -> dict[str, Any] | None:
    """Plan 163 Phase 5: unified footprint over schema_objects/schema_morphisms,
    front-end-agnostic to whether `object_name` denotes a DW retrieve
    (`proc_name` absent) or a PS object (`proc_name` given) -- a DW's own name
    lives in schema_objects.stmt_object for its `dw_retrieve`-kind row (see
    PB.Pipeline.DuckDb.appendSchemaObjects's DwRetrieveId branch), the same
    column a PS statement's owning object name uses, so one query shape
    covers both. Sole footprint source since Phase 6 (2026-07-10) -- the
    older, PS-only get_procedure_footprint (sql_statement_columns, no
    leg_source, no DW support) was retired once FootprintPanel moved onto
    this endpoint in the UI.
    """
    if proc_name is None:
        kind = "dw_retrieve"
        stmt_rows = rows(
            conn.execute(
                "SELECT object_key, stmt_file, stmt_line FROM schema_objects "
                "WHERE kind = 'dw_retrieve' AND stmt_object = ?",
                [object_name],
            )
        )
    else:
        kind = "sql"
        stmt_rows = rows(
            conn.execute(
                "SELECT object_key, stmt_file, stmt_line FROM schema_objects "
                "WHERE kind = 'stmt' AND stmt_object = ? AND stmt_proc = ?",
                [object_name, proc_name],
            )
        )
    if not stmt_rows:
        # No schema_objects row means "no footprint legs found," which is
        # ambiguous between "this object/proc doesn't exist" (real 404) and
        # "it exists but touches no SQL/retrieve at all" -- e.g. a
        # criteria-entry DataWindow with no retrieve SQL (dw_objects.
        # retrieve_sql IS NULL), or a procedure with no embedded SQL. The
        # old PS-only get_procedure_footprint distinguished these via a
        # `procedures` existence check independent of SQL-statement count;
        # this unified endpoint needs the same distinction for both fronts,
        # via dw_objects for a DW and procedures for a PS proc, else a
        # perfectly normal no-SQL object 404s as if it didn't exist.
        exists = (
            conn.execute("SELECT 1 FROM dw_objects WHERE object = ? LIMIT 1", [object_name]).fetchone()
            if proc_name is None
            else conn.execute(
                "SELECT 1 FROM procedures WHERE object = ? AND proc_name = ? LIMIT 1",
                [object_name, proc_name],
            ).fetchone()
        )
        if not exists:
            return None
        return {"object": object_name, "proc_name": proc_name, "kind": kind, "statements": [], "blast_radius": []}

    stmt_keys = [r["object_key"] for r in stmt_rows]
    placeholders = ",".join("?" for _ in stmt_keys)
    leg_rows = rows(conn.execute(_FOOTPRINT_LEGS_SQL.format(placeholders=placeholders), stmt_keys))

    by_stmt: dict[str, dict[str, Any]] = {
        r["object_key"]: {"stmt_key": r["object_key"], "file": r["stmt_file"], "line": r["stmt_line"], "legs": []}
        for r in stmt_rows
    }
    for r in leg_rows:
        by_stmt[r["stmt_key"]]["legs"].append(
            {
                "column": {"namespace": r["namespace"], "table": r["table_name"], "column": r["column_name"]},
                "leg_kind": r["leg_kind"],
                "leg_source": r["leg_source"],
            }
        )

    statements = sorted(by_stmt.values(), key=lambda s: (s["line"] is None, s["line"] or 0, s["stmt_key"]))

    touched_columns = {
        (leg["column"]["namespace"], leg["column"]["table"], leg["column"]["column"])
        for stmt in statements
        for leg in stmt["legs"]
    }
    seed_keys = [_column_key(ns, tbl, col) for ns, tbl, col in touched_columns]
    paths_by_target = _coslice_paths(conn, seed_keys)
    blast_radius = [
        {
            "target": _parse_object_key(target),
            "direction": legs[0]["direction"],
            "legs": [
                {
                    "from_object": _parse_object_key(leg["leg_from"]),
                    "to_object": _parse_object_key(leg["leg_to"]),
                    "leg_kind": leg["leg_kind"],
                }
                for leg in legs
            ],
        }
        for target, legs in sorted(paths_by_target.items())
    ]

    return {
        "object": object_name,
        "proc_name": proc_name,
        "kind": kind,
        "statements": statements,
        "blast_radius": blast_radius,
    }


_COLUMN_AFFINITY_LEGS_SQL = """
    WITH legs AS (
        SELECT o1.column_name AS col, m.to_key AS stmt_key
        FROM schema_morphisms m JOIN schema_objects o1 ON o1.object_key = m.from_key
        WHERE m.leg_kind = 'reads' AND o1.table_name = ? AND o1.namespace IS NOT DISTINCT FROM ?
        UNION ALL
        SELECT o2.column_name AS col, m.from_key AS stmt_key
        FROM schema_morphisms m JOIN schema_objects o2 ON o2.object_key = m.to_key
        WHERE m.leg_kind IN ('writes', 'retrieve') AND o2.table_name = ? AND o2.namespace IS NOT DISTINCT FROM ?
    )
    SELECT col, stmt_key FROM legs
"""


def _jaccard(a: set[str], b: set[str]) -> float:
    union = len(a | b)
    return len(a & b) / union if union else 0.0


def _cluster_columns(stmts_by_col: dict[str, set[str]]) -> tuple[list[str], list[dict[str, Any]]]:
    """Average-linkage agglomerative clustering over per-column Jaccard co-access.

    Pure Python, no scipy/numpy — real tables in this corpus top out at ~42
    touched columns, so an O(n^3) merge loop is negligible (D3 spike,
    doc/plan/153-schema-normalization-consumers.md, Open Question 2). Each
    cluster's member list is built by concatenating the two merged clusters'
    member lists at every step, so the final (single) cluster's member order
    is a valid dendrogram leaf order, not just an alphabetical one.
    """
    active = sorted(stmts_by_col)
    members: dict[str, list[str]] = {c: [c] for c in active}
    dendrogram: list[dict[str, Any]] = []
    next_id = 0

    def avg_linkage(c1: str, c2: str) -> float:
        leaf_pairs = [(a, b) for a in members[c1] for b in members[c2]]
        return sum(_jaccard(stmts_by_col[a], stmts_by_col[b]) for a, b in leaf_pairs) / len(leaf_pairs)

    while len(active) > 1:
        best_sim, best_a, best_b = max((avg_linkage(a, b), a, b) for a, b in combinations(active, 2))
        new_id = f"__cluster{next_id}__"
        next_id += 1
        merged_members = members[best_a] + members[best_b]
        members[new_id] = merged_members
        active.remove(best_a)
        active.remove(best_b)
        active.append(new_id)
        dendrogram.append({"similarity": best_sim, "members": sorted(merged_members)})

    (root,) = active
    return members[root], dendrogram


def get_column_affinity(
    conn: duckdb.DuckDBPyConnection, namespace: str | None, table_name: str
) -> dict[str, Any] | None:
    """D3: latent-entity discovery via biclustering the column x statement
    incidence matrix for one table. Matrix extraction is a parameterized
    version of D3's own spike SQL; clustering is plain Jaccard + average-
    linkage (Open Question 2 resolved — Navathe bond energy is unwarranted
    at this corpus's scale).
    """
    namespace, table_name = _norm(namespace), table_name.lower()
    exists = conn.execute(
        "SELECT 1 FROM catalog_columns WHERE table_name = ? AND namespace IS NOT DISTINCT FROM ? LIMIT 1",
        [table_name, namespace],
    ).fetchone()
    if not exists:
        return None

    leg_rows = rows(conn.execute(_COLUMN_AFFINITY_LEGS_SQL, [table_name, namespace, table_name, namespace]))
    stmts_by_col: dict[str, set[str]] = defaultdict(set)
    for r in leg_rows:
        stmts_by_col[r["col"]].add(r["stmt_key"])

    if not stmts_by_col:
        return {"table": table_name, "namespace": namespace, "columns": [], "co_access_matrix": [], "dendrogram": []}

    columns, dendrogram = _cluster_columns(stmts_by_col)
    co_access_matrix = [[len(stmts_by_col[a] & stmts_by_col[b]) for b in columns] for a in columns]
    return {
        "table": table_name,
        "namespace": namespace,
        "columns": columns,
        "co_access_matrix": co_access_matrix,
        "dendrogram": dendrogram,
    }


def get_column_managers(
    conn: duckdb.DuckDBPyConnection, namespace: str | None, table: str, column: str
) -> list[dict[str, Any]]:
    namespace, table, column = _norm(namespace), table.lower(), column.lower()
    sql_rows = rows(
        conn.execute(
            "SELECT file, object, proc_name, line, is_write FROM sql_statement_columns "
            "WHERE table_name = ? AND column_name = ? AND namespace IS NOT DISTINCT FROM ? "
            "ORDER BY object, proc_name, line",
            [table, column, namespace],
        )
    )
    dw_rows = rows(
        conn.execute(
            "SELECT file, dw_name FROM dw_retrieve_columns "
            "WHERE table_name = ? AND column_name = ? AND namespace IS NOT DISTINCT FROM ? "
            "ORDER BY dw_name",
            [table, column, namespace],
        )
    )

    managers = [
        {
            "kind": "sql",
            "file": r["file"],
            "object": r["object"],
            "proc_name": r["proc_name"],
            "line": r["line"],
            "is_write": r["is_write"],
        }
        for r in sql_rows
    ]
    managers += [{"kind": "dw_retrieve", "file": r["file"], "dw_name": r["dw_name"]} for r in dw_rows]
    return managers


def _column_key(namespace: str | None, table: str, column: str) -> str:
    prefix = f"{namespace}." if namespace else ""
    return f"col:{prefix}{table}.{column}"


def _parse_object_key(key: str) -> dict[str, Any]:
    """Structured `SchemaObjectRef` dict for a `schObjectKey` string,
    recovering every field `PB.Analysis.SchemaCategory.schObjectKey` bakes
    into the key -- file/object/proc_name/line for a `stmt:sql:` key,
    file/dw_name for a `stmt:dw:` key, namespace/table/column for a `col:`
    key -- so callers (the UI) can navigate to the real entity instead of
    only displaying a formatted label.
    """
    if key.startswith("stmt:dw:"):
        file, dw_name = key[len("stmt:dw:"):].rsplit(":", 1)
        return {"kind": "dw_retrieve", "file": file, "dw_name": dw_name}
    if key.startswith("stmt:sql:"):
        file, obj, proc, line = key[len("stmt:sql:"):].rsplit(":", 3)
        return {"kind": "sql", "file": file, "object": obj, "proc_name": proc, "line": int(line)}
    if key.startswith("col:"):
        body = key[len("col:"):]
        rest, column = body.rsplit(".", 1)
        namespace, table = rest.rsplit(".", 1) if "." in rest else (None, rest)
        return {"kind": "column", "namespace": namespace, "table": table, "column": column}
    return {"kind": "unknown", "file": key}


def _coslice_paths(conn: duckdb.DuckDBPyConnection, seed_keys: list[str]) -> dict[str, list[dict[str, Any]]]:
    """Every distinct target statement reachable from any seed column,
    keeping the shortest leg chain when more than one seed column in the
    block reaches the same statement. Reads decomposition_coslice as-is —
    no traversal happens here.
    """
    if not seed_keys:
        return {}
    placeholders = ",".join("?" for _ in seed_keys)
    leg_rows = rows(
        conn.execute(
            f"SELECT seed_key, target_key, direction, leg_ordinal, leg_from, leg_to, leg_kind "
            f"FROM decomposition_coslice WHERE seed_key IN ({placeholders}) "
            f"ORDER BY target_key, seed_key, leg_ordinal",
            seed_keys,
        )
    )
    by_path: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for r in leg_rows:
        by_path[(r["seed_key"], r["target_key"])].append(r)

    best: dict[str, list[dict[str, Any]]] = {}
    for (_seed, target), legs in by_path.items():
        if target not in best or len(legs) < len(best[target]):
            best[target] = legs
    return best


def _in_block(col_ref: dict[str, Any], namespace: str | None, table: str, members: set[str]) -> bool:
    return col_ref["table"] == table and col_ref["namespace"] == namespace and col_ref["column"] in members


def _candidate_ritual_evidence(
    rituals: list[dict[str, Any]], namespace: str | None, table_name: str, members: set[str]
) -> tuple[int, list[dict[str, Any]]]:
    """`ritual_support` sums co-write support across every qualifying pair in
    the block (the score signal); `ritual_pairs` narrows the same pairs down
    to only those with at least one violation -- a pair with zero violations
    just says its columns are, without exception, always written together,
    which the affinity heatmap already shows visually. Surfacing every
    pair regardless of violations reproduces the same repetitive, low-signal
    listing this deliverable was built to avoid (see doc/plan/153's own D1
    retrospective: 0 violations across 45 qualifying pairs in this corpus)."""
    block = [
        r
        for r in rituals
        if _in_block(r["column_a"], namespace, table_name, members)
        and _in_block(r["column_b"], namespace, table_name, members)
    ]
    ritual_support = sum(r["co_write_support"] for r in block)
    ritual_pairs = [r for r in block if r["violations"]]
    return ritual_support, ritual_pairs


def get_decomposition_candidates(
    conn: duckdb.DuckDBPyConnection,
    namespace: str | None,
    table_name: str,
    min_similarity: float = 0.7,
) -> dict[str, Any] | None:
    """D5: rank D3's dendrogram merges (candidate column-block splits) by
    `score = (ritual_support + unenforced_fk_count) / coslice_size` — the
    v0 formula from doc/plan/153-schema-normalization-consumers.md, a
    placeholder by design, to be groomed once real output exists across
    more than one table. `coslice_size` (the rewrite cost) is read
    directly from `decomposition_coslice`; ritual/FK evidence reuses D1's
    and D2's own services rather than re-querying schema_morphisms.
    """
    namespace, table_name = _norm(namespace), table_name.lower()
    affinity = get_column_affinity(conn, namespace, table_name)
    if affinity is None:
        return None

    rituals = get_co_update_rituals(conn, min_support=1)["rituals"]
    fk_graph = get_fk_graph(conn)

    candidates: list[dict[str, Any]] = []
    for merge in affinity["dendrogram"]:
        if merge["similarity"] < min_similarity or len(merge["members"]) < 2:
            continue
        members = set(merge["members"])

        ritual_support, ritual_pairs = _candidate_ritual_evidence(rituals, namespace, table_name, members)
        unenforced_fk_count = sum(
            1
            for e in fk_graph["unenforced"]
            if _in_block(e["from_column"], namespace, table_name, members)
            or _in_block(e["to_column"], namespace, table_name, members)
        )

        seed_keys = [_column_key(namespace, table_name, c) for c in sorted(members)]
        paths_by_target = _coslice_paths(conn, seed_keys)
        coslice_size = len(paths_by_target)
        score = (ritual_support + unenforced_fk_count) / coslice_size if coslice_size else None

        candidates.append(
            {
                "columns": sorted(members),
                "similarity": merge["similarity"],
                "ritual_support": ritual_support,
                "ritual_pairs": ritual_pairs,
                "unenforced_fk_count": unenforced_fk_count,
                "coslice_size": coslice_size,
                "score": score,
                "paths": [
                    {
                        "target": _parse_object_key(target),
                        "direction": legs[0]["direction"],
                        "legs": [
                            {
                                "from_object": _parse_object_key(leg["leg_from"]),
                                "to_object": _parse_object_key(leg["leg_to"]),
                                "leg_kind": leg["leg_kind"],
                            }
                            for leg in legs
                        ],
                    }
                    for target, legs in sorted(paths_by_target.items())
                ],
            }
        )

    candidates.sort(key=lambda c: (c["score"] is None, -(c["score"] or 0)))
    return {
        "table": table_name,
        "namespace": namespace,
        "affinity": {
            "columns": affinity["columns"],
            "co_access_matrix": affinity["co_access_matrix"],
            "dendrogram": affinity["dendrogram"],
        },
        "candidates": candidates,
    }


def get_window_table_lattice(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    """D7: concept lattice over the 'window W touches table T' incidence
    (147 idea 8) -- an architecture-recovery grouping of windows by shared
    table footprint, i.e. a migration-module map candidate. Report data
    only; diagram rendering lives in `pb.pipeline.diagrams.build_window_table_
    lattice` (the "window-table-lattice" diagram kind), which shares this same
    computation via `pb.pipeline.lattice` -- see that module's docstring for
    why the computation itself lives in `pb-pipeline`, not here.
    """
    return compute_window_table_lattice(conn)
