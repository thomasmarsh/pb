"""Table-related business logic extracted from route handlers."""

from __future__ import annotations

from collections import defaultdict
from typing import Any

import duckdb
from pb.api.routes.dependencies import _WRITE_OPS, rows


def list_tables(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    return rows(
        conn.execute("""
        SELECT
            table_name,
            count(*) FILTER (WHERE source = 'datawindow')  AS dw_count,
            count(*) FILTER (WHERE source = 'powerscript') AS ps_count,
            count(DISTINCT file)                           AS file_count
        FROM all_sql_tables
        GROUP BY table_name
        ORDER BY (dw_count + ps_count) DESC, table_name
    """)
    )


def column_lineage(conn: duckdb.DuckDBPyConnection, table_name: str) -> list[dict]:
    try:
        dw_cols = rows(
            conn.execute(
                "SELECT column_name, dw_name FROM dw_retrieve_columns WHERE table_name = ? ORDER BY column_name, dw_name",
                [table_name],
            )
        )
    except Exception:
        dw_cols = []
    try:
        ps_cols = rows(
            conn.execute(
                "SELECT unnest(string_split(columns, ',')) AS col, object, proc_name, operation "
                "FROM sql_statements "
                "WHERE list_contains(string_split(tables, ','), ?) "
                "  AND columns IS NOT NULL AND columns != ''",
                [table_name],
            )
        )
    except Exception:
        ps_cols = []

    col_map: dict[str, dict] = defaultdict(
        lambda: {
            "dw_readers": [],
            "ps_readers": [],
            "ps_writers": [],
        }
    )

    for r in dw_cols:
        col = r["column_name"]
        if r["dw_name"] not in col_map[col]["dw_readers"]:
            col_map[col]["dw_readers"].append(r["dw_name"])

    for r in ps_cols:
        col = r["col"]
        ref = {"object": r["object"], "proc_name": r["proc_name"], "operation": r["operation"]}
        bucket = "ps_writers" if r["operation"] in _WRITE_OPS else "ps_readers"
        col_map[col][bucket].append(ref)

    return [
        {
            "column": col,
            "dw_readers": data["dw_readers"],
            "ps_readers": data["ps_readers"],
            "ps_writers": data["ps_writers"],
            "read_count": len(data["dw_readers"]) + len(data["ps_readers"]),
            "write_count": len(data["ps_writers"]),
        }
        for col, data in sorted(col_map.items())
        if data["dw_readers"] or data["ps_readers"] or data["ps_writers"]
    ]


def impact_lineage(conn: duckdb.DuckDBPyConnection, table_name: str) -> dict:
    direct_rows = rows(
        conn.execute(
            "SELECT DISTINCT object, source, operation FROM all_sql_tables WHERE table_name = ? ORDER BY object",
            [table_name],
        )
    )
    direct_objects = {r["object"] for r in direct_rows}

    if not direct_objects:
        return {"direct": [], "inherited": []}

    placeholders = ", ".join("?" * len(direct_objects))
    inherited_rows = rows(
        conn.execute(
            f"""
        WITH RECURSIVE
          inherits AS (
            SELECT object AS from_object, ancestor AS to_object
            FROM objects WHERE ancestor IS NOT NULL
          ),
          desc_cte AS (
            SELECT from_object AS descendant, to_object AS ancestor, 1 AS depth
            FROM inherits
            WHERE to_object IN ({placeholders})
            UNION ALL
            SELECT i.from_object, dc.ancestor, dc.depth + 1
            FROM inherits i
            JOIN desc_cte dc ON i.to_object = dc.descendant
            WHERE dc.depth < 15
          )
        SELECT descendant, ancestor, min(depth) AS depth
        FROM desc_cte
        GROUP BY descendant, ancestor
        ORDER BY depth, ancestor, descendant
    """,
            list(direct_objects),
        )
    )

    return {
        "direct": direct_rows,
        "inherited": inherited_rows,
    }


def get_table_detail(conn: duckdb.DuckDBPyConnection, table_name: str) -> dict[str, Any] | None:
    all_refs = rows(
        conn.execute(
            "SELECT source, object, proc_name, line, operation, file "
            "FROM all_sql_tables WHERE table_name = ? ORDER BY source, object",
            [table_name],
        )
    )
    if not all_refs:
        return None

    try:
        dws = rows(
            conn.execute(
                "SELECT DISTINCT dw_name, file FROM dw_retrieve_tables WHERE table_name = ? ORDER BY dw_name",
                [table_name],
            )
        )
    except Exception:
        dws = []
    try:
        columns = rows(
            conn.execute(
                "SELECT dw_name, column_fqn, column_name "
                "FROM dw_retrieve_columns WHERE table_name = ? ORDER BY dw_name, column_name",
                [table_name],
            )
        )
    except Exception:
        columns = []
    try:
        where = rows(
            conn.execute(
                "SELECT dw_name, idx, exp1, op, exp2, logic "
                "FROM dw_retrieve_where WHERE exp1 LIKE ? OR exp2 LIKE ? ORDER BY dw_name, idx",
                [f"%{table_name}%", f"%{table_name}%"],
            )
        )
    except Exception:
        where = []
    procedures = rows(
        conn.execute(
            "SELECT DISTINCT object, proc_name, operation "
            "FROM all_sql_tables "
            "WHERE table_name = ? AND source = 'powerscript' ORDER BY object, proc_name",
            [table_name],
        )
    )
    return {
        "table_name": table_name,
        "dw_count": len(dws),
        "ps_count": len(procedures),
        "datawindows": dws,
        "columns": columns,
        "columns_detail": column_lineage(conn, table_name),
        "where": where,
        "procedures": procedures,
        "impact": impact_lineage(conn, table_name),
    }


def get_table_stats(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    stats: dict[str, Any] = {}
    for table in (
        "objects",
        "procedures",
        "dw_controls",
        "dw_retrieve_tables",
        "dw_retrieve_columns",
        "inherits",
        "calls",
        "object_metrics",
    ):
        try:
            row = conn.execute(f"SELECT count(*) FROM {table}").fetchone()
            stats[table] = row[0] if row else 0
        except Exception:
            stats[table] = 0

    kind_counts = rows(conn.execute("""
        SELECT kind, count(*) AS count FROM (
            SELECT kind FROM objects
            UNION ALL
            SELECT 'datawindow' AS kind FROM dw_objects
        ) t
        GROUP BY kind ORDER BY count DESC
    """))
    stats["by_kind"] = kind_counts

    top_complex = rows(
        conn.execute(
            "SELECT object, proc_name AS name, proc_type, cyclomatic "
            "FROM procedures WHERE cyclomatic IS NOT NULL "
            "ORDER BY cyclomatic DESC LIMIT 10"
        )
    )
    stats["top_complex"] = top_complex

    top_pagerank = rows(
        conn.execute(
            "SELECT object, round(pagerank, 6) AS pagerank, in_degree, out_degree "
            "FROM object_metrics ORDER BY pagerank DESC LIMIT 10"
        )
    )
    stats["top_pagerank"] = top_pagerank

    try:
        row = conn.execute("SELECT count(DISTINCT table_name) FROM all_sql_tables").fetchone()
        stats["tables"] = row[0] if row else 0
    except Exception:
        stats["tables"] = 0

    try:
        row = conn.execute("""
            SELECT count(*) FROM (
                SELECT DISTINCT file FROM objects
                UNION
                SELECT DISTINCT file FROM parse_errors
            ) t
        """).fetchone()
        stats["files_indexed"] = row[0] if row else 0
    except Exception:
        stats["files_indexed"] = 0

    try:
        row = conn.execute("SELECT count(DISTINCT file) FROM parse_errors").fetchone()
        stats["parse_error_count"] = row[0] if row else 0
    except Exception:
        stats["parse_error_count"] = 0

    try:
        row = conn.execute("SELECT count(*) FROM taint_paths").fetchone()
        stats["taint_path_count"] = row[0] if row else 0
    except Exception:
        stats["taint_path_count"] = 0

    try:
        rt = conn.execute("SELECT count(*) FROM resolved_types").fetchone()
        rc = conn.execute("SELECT count(*) FROM resolved_calls").fetchone()
        stats["resolved_type_count"] = rt[0] if rt else 0
        stats["resolved_call_count"] = rc[0] if rc else 0
    except Exception:
        stats["resolved_type_count"] = 0
        stats["resolved_call_count"] = 0

    try:
        row = conn.execute("""
            SELECT count(*) FROM objects o
            WHERE o.kind = 'datawindow'
              AND NOT EXISTS (
                  SELECT 1 FROM call_sites c WHERE lower(c.to_name) = lower(o.object)
              )
              AND NOT EXISTS (
                  SELECT 1 FROM dw_retrieve_tables d WHERE lower(d.dw_name) = lower(o.object)
              )
              AND NOT EXISTS (
                  SELECT 1 FROM all_sql_tables a WHERE lower(a.table_name) = lower(o.object)
              )
        """).fetchone()
        stats["dead_dw"] = row[0] if row else 0
    except Exception:
        stats["dead_dw"] = 0

    return stats
