"""`Sch` consumers (Plan 153 D1 + D2 + D4 + D6) — co-update rituals,
implied-FK graph, column-usage classification, and statement-management
views.

Pure presentation over Plan 148's schema_objects/schema_morphisms/catalog_*/
sql_statement_columns tables. No traversal, no new DuckDB tables.
"""

from __future__ import annotations

from collections import defaultdict
from itertools import combinations
from typing import Any

import duckdb
from pb.api.routes.dependencies import rows

ColumnKey = tuple[str | None, str, str]


def _column_ref(row: dict[str, Any], prefix: str) -> dict[str, Any]:
    return {
        "namespace": row[f"{prefix}_namespace"],
        "table": row[f"{prefix}_table"],
        "column": row[f"{prefix}_column"],
    }


def _canon(a: ColumnKey, b: ColumnKey) -> tuple[ColumnKey, ColumnKey]:
    return (a, b) if a <= b else (b, a)


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
    WHERE m.leg_kind = 'writes'
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
    """
    write_rows = rows(conn.execute(_CO_WRITE_SQL))

    stmts_by_col: dict[ColumnKey, set[str]] = defaultdict(set)
    stmt_ref: dict[str, dict[str, Any]] = {}
    for r in write_rows:
        col: ColumnKey = (r["namespace"], r["table_name"], r["column_name"])
        stmts_by_col[col].add(r["stmt_key"])
        stmt_ref[r["stmt_key"]] = _stmt_ref(r)

    cols = sorted(stmts_by_col)
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
    WHERE m.leg_kind = 'fk' AND m.fk_source = ?
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
    ddl_edges = rows(conn.execute(_FK_EDGE_SQL, ["ddl"]))
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


def get_procedure_footprint(
    conn: duckdb.DuckDBPyConnection, object_name: str, proc_name: str
) -> dict[str, Any] | None:
    exists = conn.execute(
        "SELECT 1 FROM procedures WHERE object = ? AND proc_name = ? LIMIT 1",
        [object_name, proc_name],
    ).fetchone()
    if not exists:
        return None

    col_rows = rows(
        conn.execute(
            "SELECT line, file, namespace, table_name, column_name, is_write "
            "FROM sql_statement_columns WHERE object = ? AND proc_name = ? ORDER BY line",
            [object_name, proc_name],
        )
    )
    filter_rows = rows(
        conn.execute(
            "SELECT line, namespace, table_name, column_name, op, values_json "
            "FROM sql_statement_filters WHERE object = ? AND proc_name = ? ORDER BY line",
            [object_name, proc_name],
        )
    )

    by_line: dict[int, dict[str, Any]] = {}
    unresolved: list[dict[str, Any]] = []
    for r in col_rows:
        line = r["line"]
        if r["table_name"] is None:
            unresolved.append({"line": line, "raw_name": r["column_name"]})
            continue
        entry = by_line.setdefault(line, {"line": line, "file": r["file"], "columns": [], "filters": []})
        entry["columns"].append(
            {
                "namespace": r["namespace"],
                "table": r["table_name"],
                "column": r["column_name"],
                "is_write": r["is_write"],
            }
        )

    for r in filter_rows:
        line = r["line"]
        if r["table_name"] is None or line not in by_line:
            continue
        by_line[line]["filters"].append(
            {
                "namespace": r["namespace"],
                "table": r["table_name"],
                "column": r["column_name"],
                "op": r["op"],
                "values_json": r["values_json"],
            }
        )

    return {
        "object": object_name,
        "proc_name": proc_name,
        "statements": [by_line[line] for line in sorted(by_line)],
        "unresolved": unresolved,
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
