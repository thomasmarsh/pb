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

import json
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

        ritual_support = sum(
            r["co_write_support"]
            for r in rituals
            if _in_block(r["column_a"], namespace, table_name, members)
            and _in_block(r["column_b"], namespace, table_name, members)
        )
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
    return {"table": table_name, "namespace": namespace, "candidates": candidates}


_WINDOW_DIRECT_SQL_TABLES_SQL = """
    SELECT DISTINCT o.object AS window, a.table_name
    FROM all_sql_tables a JOIN objects o ON o.object = a.object
    WHERE a.source = 'powerscript' AND o.layout_json IS NOT NULL
"""


def _window_table_pairs(conn: duckdb.DuckDBPyConnection) -> set[tuple[str, str]]:
    """D7: 'window touches table', direct + DW-control-mediated.

    Direct: a window's own embedded SQL (`all_sql_tables`, restricted to PS
    objects with `layout_json IS NOT NULL` -- the existing window classifier,
    see `extractWindowLayout`). Indirect: a window's DataWindow control (its
    `layout_json.controls[].dataobject`, already captured at parse time) that
    retrieves from a table (`dw_retrieve_tables`). Parsed in Python, not SQL
    -- `json_each` over `objects.layout_json` chokes on the heterogeneous
    control shapes across windows (DuckDB tries to unify a struct type across
    all rows and fails on mismatched fields).
    """
    pairs = {(r["window"], r["table_name"]) for r in rows(conn.execute(_WINDOW_DIRECT_SQL_TABLES_SQL))}

    dw_to_tables: dict[str, set[str]] = defaultdict(set)
    for r in rows(conn.execute("SELECT lower(dw_name) AS dw_name, table_name FROM dw_retrieve_tables")):
        dw_to_tables[r["dw_name"]].add(r["table_name"])

    for r in rows(conn.execute("SELECT object, layout_json FROM objects WHERE layout_json IS NOT NULL")):
        layout = json.loads(r["layout_json"])
        for control in layout.get("controls", []):
            dataobject = control.get("dataobject")
            if dataobject:
                for table in dw_to_tables.get(dataobject.lower(), ()):
                    pairs.add((r["object"], table))

    return pairs


def _fca_concepts(
    incidence: dict[str, frozenset[str]], attributes: list[str]
) -> list[tuple[frozenset[str], frozenset[str]]]:
    """Ganter's Next Closure algorithm: every formal concept (extent, intent)
    of the context (incidence, attributes), in lectic order of intent.

    Pure Python, bitmask-encoded (attributes are few enough -- real tables in
    this corpus top out at ~34 -- that this is a same-order-of-magnitude
    rewrite of the D3 "no scipy" precedent, not a new dependency). Verified
    against real openpay data three independent ways before landing: every
    returned intent is idempotent under the closure operator, extents are
    pairwise distinct, and unioning every concept's extent x intent
    reconstructs the exact original incidence relation (see
    `test_get_window_table_lattice_concepts_reconstruct_all_pairs`).
    """
    objects = sorted(incidence)
    attr_index = {a: i for i, a in enumerate(attributes)}
    obj_masks = [sum(1 << attr_index[a] for a in incidence[g]) for g in objects]
    full_mask = (1 << len(attributes)) - 1

    def derive_objects(attr_mask: int) -> int:
        return sum(1 << gi for gi, m in enumerate(obj_masks) if (m & attr_mask) == attr_mask)

    def derive_attrs(obj_mask: int) -> int:
        if obj_mask == 0:
            return full_mask
        result = full_mask
        for gi, m in enumerate(obj_masks):
            if obj_mask & (1 << gi):
                result &= m
        return result

    def closure(attr_mask: int) -> int:
        return derive_attrs(derive_objects(attr_mask))

    def next_closure(b: int) -> int | None:
        for i in range(len(attributes) - 1, -1, -1):
            bit = 1 << i
            if b & bit:
                continue
            prefix_mask = bit - 1
            candidate = closure((b & prefix_mask) | bit)
            if (candidate & prefix_mask) == (b & prefix_mask):
                return candidate
        return None

    def mask_to_names(mask: int, names: list[str]) -> frozenset[str]:
        return frozenset(names[i] for i in range(len(names)) if mask & (1 << i))

    intents = [closure(0)]
    while (nxt := next_closure(intents[-1])) is not None:
        intents.append(nxt)

    return [(mask_to_names(derive_objects(b), objects), mask_to_names(b, attributes)) for b in intents]


def _fca_covers(concepts: list[tuple[frozenset[str], frozenset[str]]]) -> list[dict[str, int]]:
    """Hasse diagram: `upper` covers `lower` iff lower's extent is a proper
    subset of upper's extent and no third concept's extent sits strictly
    between them. O(n^3) on the concept count, negligible at real corpus
    scale (49 concepts on openpay).
    """
    extents = [ext for ext, _ in concepts]
    n = len(concepts)
    covers: list[dict[str, int]] = []
    for lower in range(n):
        for upper in range(n):
            if lower == upper or not (extents[lower] < extents[upper]):
                continue
            if any(
                extents[lower] < extents[mid] < extents[upper]
                for mid in range(n)
                if mid != lower and mid != upper
            ):
                continue
            covers.append({"upper": upper, "lower": lower})
    return covers


def get_window_table_lattice(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    """D7: concept lattice over the 'window W touches table T' incidence
    (147 idea 8) -- an architecture-recovery grouping of windows by shared
    table footprint, i.e. a migration-module map candidate. Report data
    only; no diagram rendering (deferred, same as every other D deliverable's
    UI surface).
    """
    pairs = _window_table_pairs(conn)
    windows = sorted({w for w, _ in pairs})
    tables = sorted({t for _, t in pairs})
    incidence = {w: frozenset(t for ww, t in pairs if ww == w) for w in windows}

    concepts = _fca_concepts(incidence, tables)
    covers = _fca_covers(concepts)

    return {
        "windows": windows,
        "tables": tables,
        "pairs": len(pairs),
        "concepts": [{"extent": sorted(ext), "intent": sorted(intent)} for ext, intent in concepts],
        "covers": covers,
    }
