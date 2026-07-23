"""Table-related business logic extracted from route handlers."""

from __future__ import annotations

from collections import defaultdict
from typing import Any

import duckdb
from pb.api.routes.dependencies import rows
from pb.api.services.schema import get_co_update_rituals, get_column_usage, get_fk_graph


def get_default_namespace(conn: duckdb.DuckDBPyConnection) -> str | None:
    """Return the corpus's configured default schema, or None if unset."""
    row = conn.execute("SELECT value FROM metadata WHERE key = 'default_namespace'").fetchone()
    return row[0] if row else None


def list_schemas(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    """Distinct namespaces known to the DDL catalog, with their table count.

    `catalog_columns` is the only namespace-aware source in the DB --
    `all_sql_tables` (embedded-SQL usage) never carries a schema qualifier,
    so it cannot itself distinguish same-named tables across schemas. A
    single-schema/no-DDL corpus (the common case) has an empty
    `catalog_columns` and returns `[]` here -- callers should treat that as
    "no schema picker needed", not an error.
    """
    return rows(
        conn.execute("""
        SELECT namespace, count(DISTINCT table_name) AS table_count
        FROM catalog_columns
        WHERE namespace IS NOT NULL
        GROUP BY namespace
        ORDER BY namespace
    """)
    )


def list_tables(conn: duckdb.DuckDBPyConnection, namespace: str | None = None) -> list[dict[str, Any]]:
    if namespace is None:
        # Cross-namespace roll-up ("All schemas" in the UI) -- but every row
        # still carries its own real namespace. Grouping by table_name alone
        # would (a) silently merge same-named tables from different schemas
        # into one row and (b) drop the namespace a caller needs to navigate
        # into that table's detail page -- the exact bug that made a listed
        # table 404 on click (namespace was never in the row to begin with).
        return rows(
            conn.execute("""
            SELECT
                table_name,
                namespace,
                count(*) FILTER (WHERE source = 'datawindow')  AS dw_count,
                count(*) FILTER (WHERE source = 'powerscript') AS ps_count,
                count(DISTINCT file)                           AS file_count
            FROM all_sql_tables
            GROUP BY table_name, namespace
            ORDER BY (dw_count + ps_count) DESC, table_name
        """)
        )
    # Scoped to one schema: table identity comes from the DDL catalog, usage
    # counts join on all_sql_tables' own resolved namespace (Plan 157 Phase
    # 4.5 -- sql_statement_tables/dw_retrieve_tables now carry a real
    # per-reference namespace, so every schema gets its own honest usage,
    # not just the corpus's configured default).
    return rows(
        conn.execute(
            """
            SELECT
                c.table_name,
                ? AS namespace,
                count(*) FILTER (WHERE a.source = 'datawindow')  AS dw_count,
                count(*) FILTER (WHERE a.source = 'powerscript') AS ps_count,
                count(DISTINCT a.file)                            AS file_count
            FROM (SELECT DISTINCT table_name FROM catalog_columns WHERE namespace = ?) c
            LEFT JOIN all_sql_tables a ON a.table_name = c.table_name AND a.namespace = ?
            GROUP BY c.table_name
            ORDER BY (dw_count + ps_count) DESC, c.table_name
        """,
            [namespace, namespace, namespace],
        )
    )


def column_lineage(
    conn: duckdb.DuckDBPyConnection, table_name: str, namespace: str | None = None
) -> list[dict]:
    ns_filter = "namespace IS NOT DISTINCT FROM ?"
    try:
        dw_cols = rows(
            conn.execute(
                f"SELECT column_name, object FROM dw_retrieve_columns "
                f"WHERE table_name = ? AND {ns_filter} ORDER BY column_name, object",
                [table_name, namespace],
            )
        )
    except Exception:
        dw_cols = []
    try:
        # Joins through sql_statement_columns (Plan 157 Phase 4.5: carries a
        # real per-column resolved namespace and is_write flag, unlike the
        # legacy CSV-split sql_statements.columns/tables this used to read)
        # back to sql_statements only for the statement's operation text,
        # which the UI still renders per PS reference.
        ps_cols = rows(
            conn.execute(
                f"""
                SELECT sc.column_name AS col, sc.object, sc.proc_name, sc.is_write, s.operation
                FROM sql_statement_columns sc
                JOIN sql_statements s
                  ON s.file = sc.file AND s.object = sc.object
                 AND s.proc_name = sc.proc_name AND s.line = sc.line
                WHERE sc.table_name = ? AND sc.{ns_filter}
                ORDER BY sc.column_name
            """,
                [table_name, namespace],
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
        if r["object"] not in col_map[col]["dw_readers"]:
            col_map[col]["dw_readers"].append(r["object"])

    for r in ps_cols:
        col = r["col"]
        ref = {"object": r["object"], "proc_name": r["proc_name"], "operation": r["operation"]}
        bucket = "ps_writers" if r["is_write"] else "ps_readers"
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


def impact_lineage(
    conn: duckdb.DuckDBPyConnection, table_name: str, namespace: str | None = None
) -> dict:
    ns_filter = "namespace IS NOT DISTINCT FROM ?"
    direct_rows = rows(
        conn.execute(
            f"SELECT DISTINCT object, source, operation FROM all_sql_tables "
            f"WHERE table_name = ? AND {ns_filter} ORDER BY object",
            [table_name, namespace],
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


def get_table_detail(
    conn: duckdb.DuckDBPyConnection, table_name: str, namespace: str | None = None
) -> dict[str, Any] | None:
    if namespace is not None:
        # Existence is checked against the DDL catalog, not all_sql_tables:
        # the latter has no namespace of its own, so it can't confirm a
        # table exists specifically *within* the requested schema.
        in_schema = conn.execute(
            "SELECT 1 FROM catalog_columns WHERE namespace = ? AND table_name = ? LIMIT 1",
            [namespace, table_name],
        ).fetchone()
        if not in_schema:
            return None

    # Plan 157 Phase 4.5: every layer below now carries its own resolved
    # namespace (sql_statement_tables/dw_retrieve_tables/
    # sql_statement_columns/dw_retrieve_columns), so a scoped-but-non-default
    # namespace shows its own real usage instead of reading as gated-empty.
    ns_filter = "namespace IS NOT DISTINCT FROM ?"
    all_refs = rows(
        conn.execute(
            f"SELECT source, object, proc_name, line, operation, file "
            f"FROM all_sql_tables WHERE table_name = ? AND {ns_filter} ORDER BY source, object",
            [table_name, namespace],
        )
    )
    if namespace is None and not all_refs:
        return None

    try:
        dws = rows(
            conn.execute(
                f"SELECT DISTINCT object, file FROM dw_retrieve_tables "
                f"WHERE table_name = ? AND {ns_filter} ORDER BY object",
                [table_name, namespace],
            )
        )
    except Exception:
        dws = []
    try:
        columns = rows(
            conn.execute(
                f"SELECT object, column_fqn, column_name "
                f"FROM dw_retrieve_columns WHERE table_name = ? AND {ns_filter} ORDER BY object, column_name",
                [table_name, namespace],
            )
        )
    except Exception:
        columns = []
    try:
        # dw_retrieve_where carries no namespace of its own and is matched
        # by a LIKE over the table name (not a real column-level filter) --
        # unaffected by the namespace scoping in this function.
        where = rows(
            conn.execute(
                "SELECT object, idx, exp1, op, exp2, logic "
                "FROM dw_retrieve_where WHERE exp1 LIKE ? OR exp2 LIKE ? ORDER BY object, idx",
                [f"%{table_name}%", f"%{table_name}%"],
            )
        )
    except Exception:
        where = []
    procedures = rows(
        conn.execute(
            f"SELECT DISTINCT object, proc_name, operation "
            f"FROM all_sql_tables "
            f"WHERE table_name = ? AND source = 'powerscript' AND {ns_filter} ORDER BY object, proc_name",
            [table_name, namespace],
        )
    )
    columns_detail = column_lineage(conn, table_name, namespace)
    impact = impact_lineage(conn, table_name, namespace)

    return {
        "table_name": table_name,
        "namespace": namespace,
        "dw_count": len(dws),
        "ps_count": len(procedures),
        "datawindows": dws,
        "columns": columns,
        "columns_detail": columns_detail,
        "where": where,
        "procedures": procedures,
        "impact": impact,
    }


def resolve_table_namespaces(conn: duckdb.DuckDBPyConnection, table_name: str) -> list[str | None]:
    """Every namespace a table with this name is known under.

    Reads `all_sql_tables` rather than `catalog_columns` so it also resolves
    tables that only ever show up in embedded SQL / DW retrieves with no DDL
    loaded at all (where the true namespace is `None`, a real value, not a
    missing one). A real corpus can legitimately return many rows here --
    e.g. the same table replicated across dozens of per-tenant schemas --
    that is not by itself ambiguity; see `resolve_table_detail`, which
    applies the corpus's own default-namespace rule before treating this
    list as anything more than a fallback.
    """
    result = rows(
        conn.execute(
            "SELECT DISTINCT namespace FROM all_sql_tables WHERE table_name = ?",
            [table_name],
        )
    )
    return [r["namespace"] for r in result]


def resolve_table_detail(conn: duckdb.DuckDBPyConnection, table_name: str) -> dict[str, Any] | None:
    """Bare-name table lookup: resolves the owning namespace and returns
    that table's detail, or None if the name can't be resolved at all.

    Mirrors the compiler's own rule for an unqualified table reference in
    source (`PB.Analysis.SchemaCategory`'s `resolveTableRef`, driven by
    `--default-namespace`): a bare reference means the default schema, not
    "ask which one." A table name existing under many schemas is normal in
    a multi-tenant corpus and is never itself grounds to bail out -- there
    is always an explicit schema per the corpus's own convention, and a bare
    lookup here is exactly the "no explicit schema given" case that
    convention already has an answer for. Only genuinely falls through to
    "can't resolve" (None) when the table isn't in the default namespace
    *and* spans 2+ non-default namespaces with no rule to pick between them
    -- which should mean some other UI surface dropped real per-reference
    namespace context it already had, not that this corpus is ambiguous.
    """
    default_ns = get_default_namespace(conn)
    if default_ns is not None:
        result = get_table_detail(conn, table_name, default_ns)
        if result is not None:
            return result
    candidates = resolve_table_namespaces(conn, table_name)
    if len(candidates) == 1:
        return get_table_detail(conn, table_name, candidates[0])
    return None


def get_table_stats(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    stats: dict[str, Any] = {"default_namespace": get_default_namespace(conn)}
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
        SELECT kind, count(*) AS count FROM objects
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
                  SELECT 1 FROM dw_retrieve_tables d WHERE lower(d.object) = lower(o.object)
              )
              AND NOT EXISTS (
                  SELECT 1 FROM all_sql_tables a WHERE lower(a.table_name) = lower(o.object)
              )
        """).fetchone()
        stats["dead_dw"] = row[0] if row else 0
    except Exception:
        stats["dead_dw"] = 0

    try:
        row = conn.execute("SELECT count(*) FROM catalog_columns").fetchone()
        stats["ddl_loaded"] = bool(row and row[0] > 0)
    except Exception:
        stats["ddl_loaded"] = False

    try:
        fk_graph = get_fk_graph(conn)
        stats["corroborated_fk_count"] = len(fk_graph["corroborated"])
        stats["unenforced_fk_count"] = len(fk_graph["unenforced"])
        stats["unused_fk_count"] = len(fk_graph["unused"])
    except Exception:
        stats["corroborated_fk_count"] = 0
        stats["unenforced_fk_count"] = 0
        stats["unused_fk_count"] = 0

    try:
        stats["dead_column_count"] = len(get_column_usage(conn)["dead"])
    except Exception:
        stats["dead_column_count"] = 0

    try:
        rituals = get_co_update_rituals(conn)["rituals"]
        stats["co_update_pair_count"] = len(rituals)
        stats["co_update_violation_count"] = sum(len(r["violations"]) for r in rituals)
    except Exception:
        stats["co_update_pair_count"] = 0
        stats["co_update_violation_count"] = 0

    return stats
