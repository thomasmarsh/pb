"""`Sch` consumers (Plan 153 D2 + D6) — implied-FK graph and statement-management views.

Pure presentation over Plan 148's schema_objects/schema_morphisms/catalog_*/
sql_statement_columns tables. No traversal, no new DuckDB tables.
"""

from __future__ import annotations

from collections import defaultdict
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
