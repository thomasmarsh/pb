"""Analysis service functions — dead code, taint, slicing, annotations, sources, sinks."""

from __future__ import annotations

import json
from typing import Any

import duckdb
from pb.api.routes.dependencies import rows
from pb.api.services.objects import read_source_lines
from pb.lib.slicing import backward_slice, build_proc_def_use, forward_slice


def get_dead_code(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    return rows(conn.execute(
        "SELECT proc_name AS name, object, proc_type, cyclomatic, "
        "caller_count_naive, caller_count_scoped "
        "FROM dead_code ORDER BY object, proc_name"
    ))


def get_dead_vars(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    return rows(conn.execute(
        "SELECT object, proc_name, var_name, line, kind "
        "FROM dead_vars ORDER BY object, proc_name, var_name"
    ))


def get_type_mismatches(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    return rows(conn.execute(
        "SELECT object, proc_name, line, target, lhs_type, rhs_desc, kind "
        "FROM type_mismatches ORDER BY object, proc_name, line"
    ))


def get_live_procedures(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    """Procedures the live_proc table confirms reachable and not dead
    (Plan 161 Phase 4 — see PB.Pipeline.DuckDb.materializeLiveProc)."""
    return rows(conn.execute(
        "SELECT object, proc AS proc_name FROM live_proc ORDER BY object, proc_name"
    ))


def get_taint_paths(
    conn: duckdb.DuckDBPyConnection,
    *,
    category: str | None = None,
    severity: str | None = None,
    source_type: str | None = None,
    sink_type: str | None = None,
    object_name: str | None = None,
    proc_name: str | None = None,
    limit: int = 100,
) -> dict[str, Any]:
    where: list[str] = []
    params: list = []

    if category is not None:
        where.append("category = ?")
        params.append(category)
    if severity is not None:
        where.append("severity = ?")
        params.append(severity)
    # source_type and sink_type no longer in taint_paths (new Haskell schema) — ignored
    if object_name is not None:
        where.append("(object = ? OR target_object = ?)")
        params.extend([object_name, object_name])
    if proc_name is not None:
        where.append("(proc_name = ? OR target_proc = ?)")
        params.extend([proc_name, proc_name])

    where_clause = ("WHERE " + " AND ".join(where)) if where else ""
    query = (
        "SELECT rowid AS id, object, proc_name, var_name, "
        "target_object, target_proc, target_var, severity, category "
        f"FROM taint_paths {where_clause} ORDER BY rowid LIMIT ?"
    )
    path_rows = rows(conn.execute(query, params + [limit]))

    count_query = f"SELECT COUNT(*) FROM taint_paths {where_clause}"
    total = conn.execute(count_query, params).fetchone()[0]  # type: ignore[index]

    paths = [
        {
            "id": r["id"],
            "source": {
                "object": r["object"],
                "proc": r["proc_name"],
                "var": r["var_name"],
                "line": None,
                "type": None,
            },
            "sink": {
                "object": r["target_object"],
                "proc": r["target_proc"],
                "var": r["target_var"],
                "line": None,
                "type": None,
                "severity": r["severity"],
            },
            "severity": r["severity"],
            "category": r["category"],
        }
        for r in path_rows
    ]
    return {"paths": paths, "total": total}


def get_taint_path(
    conn: duckdb.DuckDBPyConnection,
    path_id: int,
) -> dict[str, Any] | None:
    path_rows = rows(
        conn.execute(
            "SELECT rowid AS id, object, proc_name, var_name, "
            "target_object, target_proc, target_var, severity, category, steps_json "
            "FROM taint_paths WHERE rowid = ?",
            [path_id],
        )
    )
    if not path_rows:
        return None
    r = path_rows[0]
    steps_raw = r.get("steps_json") or "[]"
    try:
        steps = json.loads(steps_raw)
    except Exception:
        steps = []
    return {
        "id": r["id"],
        "source": {
            "object": r["object"],
            "proc_name": r["proc_name"],
            "var": r["var_name"],
            "line": None,
            "type": None,
        },
        "sink": {
            "object": r["target_object"],
            "proc_name": r["target_proc"],
            "var": r["target_var"],
            "line": None,
            "type": None,
            "severity": r["severity"],
        },
        "severity": r["severity"],
        "category": r["category"],
        "steps": steps,
    }


def get_program_slice(
    conn: duckdb.DuckDBPyConnection,
    object_name: str,
    proc_name: str,
    line: int,
    *,
    direction: str = "backward",
    var: str | None = None,
) -> dict[str, Any]:
    interproc = rows(conn.execute("SELECT * FROM interproc_edges"))

    related: set[tuple[str, str]] = {(object_name, proc_name)}
    for e in interproc:
        if e["caller_object"] == object_name and e["caller_proc"] == proc_name:
            related.add((e["callee_object"], e["callee_proc"]))
        elif e["callee_object"] == object_name and e["callee_proc"] == proc_name:
            related.add((e["caller_object"], e["caller_proc"]))

    proc_defs: list[dict] = []
    proc_uses: list[dict] = []
    for obj, proc in related:
        proc_defs.extend(rows(conn.execute(
            "SELECT * FROM proc_defs WHERE object = ? AND proc_name = ?",
            [obj, proc],
        )))
        proc_uses.extend(rows(conn.execute(
            "SELECT * FROM proc_uses WHERE object = ? AND proc_name = ?",
            [obj, proc],
        )))

    pdu = build_proc_def_use(proc_defs, proc_uses)

    if direction == "backward":
        result = backward_slice(object_name, proc_name, line, var, pdu, interproc)
    else:
        result = forward_slice(object_name, proc_name, line, var, pdu, interproc)

    return {
        "origin": {
            "object": result.origin_object,
            "proc": result.origin_proc,
            "line": result.origin_line,
            "var": result.origin_var,
        },
        "direction": result.direction,
        "steps": [
            {
                "object": s.object,
                "proc": s.proc_name,
                "line": s.line,
                "var": s.var_name,
                "kind": s.step_kind,
                "text": s.statement_text,
            }
            for s in result.steps
        ],
        "procedures_traversed": result.procedures_traversed,
    }


def get_taint_annotations(
    conn: duckdb.DuckDBPyConnection,
    object_name: str,
    proc_name: str,
) -> dict[str, Any] | None:
    ann_rows = rows(
        conn.execute(
            "SELECT block_id, is_taint_entry, is_taint_sink, tainted_vars "
            "FROM taint_annotations "
            "WHERE object = ? AND proc_name = ? "
            "ORDER BY block_id",
            [object_name, proc_name],
        )
    )
    if not ann_rows:
        return None
    annotations = [
        {
            "blockId": r["block_id"],
            "isTaintEntry": r["is_taint_entry"],
            "isTaintSink": r["is_taint_sink"],
            "taintedVars": json.loads(r["tainted_vars"]) if r.get("tainted_vars") else [],
        }
        for r in ann_rows
    ]
    return {"annotations": annotations}


def get_explain_pseudocode(
    conn: duckdb.DuckDBPyConnection,
    object_name: str,
    proc_name: str,
) -> dict[str, Any] | None:
    pc_rows = rows(
        conn.execute(
            "SELECT pseudocode_json FROM proc_pseudocode "
            "WHERE object = ? AND proc_name = ?",
            [object_name, proc_name],
        )
    )
    if not pc_rows:
        return None
    result = json.loads(pc_rows[0]["pseudocode_json"])

    proc_rows = rows(
        conn.execute(
            "SELECT file, start_line, end_line FROM procedures "
            "WHERE object = ? AND proc_name = ?",
            [object_name, proc_name],
        )
    )
    source_original = None
    proc_start_line = None
    if proc_rows:
        proc = proc_rows[0]
        file_path, start, end = proc.get("file"), proc.get("start_line"), proc.get("end_line")
        proc_start_line = start
        if file_path and start and end:
            all_lines = read_source_lines(conn, file_path)
            if all_lines is not None:
                source_original = "\n".join(all_lines[max(0, start - 1) : end])

    result["sourceOriginal"] = source_original
    result["procStartLine"] = proc_start_line
    return result


def get_capability_catalog(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    """Corpus-wide capability catalog (Plan 225 Layer 6): one row per display
    capability (PB.Analysis.CallClassify.capabilityLabel's grouping of the 7
    EffectTag constructors), with the count of distinct procedures carrying it."""
    catalog_rows = rows(
        conn.execute(
            "SELECT capability, COUNT(DISTINCT object || '.' || proc_name) AS proc_count "
            "FROM proc_effects "
            "GROUP BY capability "
            "ORDER BY proc_count DESC"
        )
    )
    return {"capabilities": catalog_rows}


def get_capability_procedures(
    conn: duckdb.DuckDBPyConnection,
    capability: str,
) -> dict[str, Any]:
    proc_rows = rows(
        conn.execute(
            "SELECT DISTINCT object, proc_name "
            "FROM proc_effects "
            "WHERE capability = ? "
            "ORDER BY object, proc_name",
            [capability],
        )
    )
    return {"procedures": proc_rows}


def get_taint_sources(
    conn: duckdb.DuckDBPyConnection,
    *,
    source_type: str | None = None,
    limit: int = 100,
) -> dict[str, Any]:
    where = "WHERE source_type = ?" if source_type is not None else ""
    params = [source_type] if source_type is not None else []
    src_rows = rows(
        conn.execute(
            f"SELECT * FROM taint_sources {where} ORDER BY object, proc_name, line LIMIT ?",
            params + [limit],
        )
    )
    total = conn.execute(
        f"SELECT COUNT(*) FROM taint_sources {where}", params
    ).fetchone()[0]  # type: ignore[index]
    return {"sources": src_rows, "total": total}


def get_type_coverage(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    """Token-level type-resolution coverage. Mirrors
    PB.Pipeline.DuckDb.Relations.typeCoverageStats's SQL exactly (same
    __stdlib__/-prefixed row exclusion, same identifier_tokens denominator) so
    the CLI-reported percentage always matches the compiler-side measurement."""
    total_tokens, resolved_tokens, var_total, var_resolved, call_total, call_resolved = conn.execute(
        "WITH resolved_positions AS ( "
        "  SELECT file, name_start_line AS l, name_start_col AS c "
        "  FROM resolved_var_refs "
        "  WHERE name_start_line IS NOT NULL AND file NOT LIKE '__stdlib__/%' "
        "  UNION "
        "  SELECT file, to_name_start_line AS l, to_name_start_col AS c "
        "  FROM resolved_calls "
        "  WHERE to_name_start_line IS NOT NULL AND file NOT LIKE '__stdlib__/%' "
        ") "
        "SELECT "
        "  (SELECT COUNT(*) FROM identifier_tokens WHERE file NOT LIKE '__stdlib__/%'), "
        "  (SELECT COUNT(*) FROM identifier_tokens it "
        "     WHERE it.file NOT LIKE '__stdlib__/%' "
        "     AND EXISTS (SELECT 1 FROM resolved_positions rp "
        "                 WHERE rp.file = it.file AND rp.l = it.start_line AND rp.c = it.start_col)), "
        "  (SELECT COUNT(*) FROM resolved_var_refs WHERE file NOT LIKE '__stdlib__/%'), "
        "  (SELECT COUNT(*) FROM resolved_var_refs WHERE file NOT LIKE '__stdlib__/%' AND kind != 'unresolved'), "
        "  (SELECT COUNT(*) FROM resolved_calls WHERE file NOT LIKE '__stdlib__/%'), "
        "  (SELECT COUNT(*) FROM resolved_calls WHERE file NOT LIKE '__stdlib__/%' AND kind != 'unresolved')"
    ).fetchone()  # type: ignore[misc]

    def pct(numerator: int, denominator: int) -> float:
        return round(numerator / denominator * 100, 2) if denominator else 0.0

    var_ref_kind_counts = rows(conn.execute(
        "SELECT kind, COUNT(*) AS count FROM resolved_var_refs "
        "WHERE file NOT LIKE '__stdlib__/%' GROUP BY kind ORDER BY count DESC"
    ))
    call_kind_counts = rows(conn.execute(
        "SELECT kind, COUNT(*) AS count FROM resolved_calls "
        "WHERE file NOT LIKE '__stdlib__/%' GROUP BY kind ORDER BY count DESC"
    ))
    # (kind, confidence) breakdown, not just kind: a kind that's usually high
    # confidence (e.g. dw_property) showing a new low-confidence bump is the
    # signal that a currently-unhandled shape (e.g. the Object.DataWindow.
    # Tree.Level bandname, scoped out of full resolution -- see TypeResolve's
    # classifyMemberOf) started appearing in a different corpus, without
    # needing a dedicated kind value per scoped-out gap.
    var_ref_kind_confidence_counts = rows(conn.execute(
        "SELECT kind, confidence, COUNT(*) AS count FROM resolved_var_refs "
        "WHERE file NOT LIKE '__stdlib__/%' GROUP BY kind, confidence ORDER BY kind, count DESC"
    ))
    call_kind_confidence_counts = rows(conn.execute(
        "SELECT kind, confidence, COUNT(*) AS count FROM resolved_calls "
        "WHERE file NOT LIKE '__stdlib__/%' GROUP BY kind, confidence ORDER BY kind, count DESC"
    ))
    return {
        "total_identifier_tokens": total_tokens,
        "resolved_identifier_tokens": resolved_tokens,
        "token_coverage_pct": pct(resolved_tokens, total_tokens),
        "var_ref_total": var_total,
        "var_ref_resolved": var_resolved,
        "var_ref_pct": pct(var_resolved, var_total),
        "call_total": call_total,
        "call_resolved": call_resolved,
        "call_pct": pct(call_resolved, call_total),
        "var_ref_kind_counts": var_ref_kind_counts,
        "call_kind_counts": call_kind_counts,
        "var_ref_kind_confidence_counts": var_ref_kind_confidence_counts,
        "call_kind_confidence_counts": call_kind_confidence_counts,
    }


def get_code_quality_report(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    """Aggregated code-quality signals — pure SQL over already-computed tables
    (Plan 174 T0-5)."""
    top_complexity_procedures = rows(conn.execute(
        "SELECT object, proc_name, proc_type, cyclomatic FROM procedures "
        "WHERE cyclomatic IS NOT NULL ORDER BY cyclomatic DESC LIMIT 10"
    ))
    dead_procedures_by_object = rows(conn.execute(
        "SELECT object, COUNT(*) AS dead_count FROM dead_code "
        "GROUP BY object ORDER BY dead_count DESC LIMIT 10"
    ))
    taint_severity_distribution = rows(conn.execute(
        "SELECT severity, COUNT(*) AS count FROM taint_paths "
        "GROUP BY severity ORDER BY count DESC"
    ))
    sql_statement_complexity_histogram = rows(conn.execute(
        "SELECT table_count, COUNT(*) AS statement_count FROM ("
        "  SELECT CASE WHEN tables IS NULL OR tables = '' THEN 0 "
        "         ELSE len(string_split(tables, ',')) END AS table_count "
        "  FROM sql_statements"
        ") GROUP BY table_count ORDER BY table_count"
    ))
    return {
        "top_complexity_procedures": top_complexity_procedures,
        "dead_procedures_by_object": dead_procedures_by_object,
        "taint_severity_distribution": taint_severity_distribution,
        "sql_statement_complexity_histogram": sql_statement_complexity_histogram,
    }


def get_sql_lint_summary(conn: duckdb.DuckDBPyConnection) -> dict[str, Any]:
    """Aggregate counts from sql_lint_issues (PB.Analysis.SqlLint), grouped by
    issue_code/severity, plus a grand total."""
    by_code = rows(conn.execute(
        "SELECT issue_code, severity, COUNT(*) AS n FROM sql_lint_issues "
        "GROUP BY issue_code, severity ORDER BY n DESC"
    ))
    total = conn.execute("SELECT COUNT(*) FROM sql_lint_issues").fetchone()[0]  # type: ignore[index]
    return {"total": total, "by_code": by_code}


def get_taint_sinks(
    conn: duckdb.DuckDBPyConnection,
    *,
    sink_type: str | None = None,
    severity: str | None = None,
    limit: int = 100,
) -> dict[str, Any]:
    where: list[str] = []
    params: list = []
    if sink_type is not None:
        where.append("sink_type = ?")
        params.append(sink_type)
    if severity is not None:
        where.append("severity = ?")
        params.append(severity)
    where_clause = ("WHERE " + " AND ".join(where)) if where else ""
    sink_rows = rows(
        conn.execute(
            f"SELECT * FROM taint_sinks {where_clause} ORDER BY object, proc_name, line LIMIT ?",
            params + [limit],
        )
    )
    total = conn.execute(
        f"SELECT COUNT(*) FROM taint_sinks {where_clause}", params
    ).fetchone()[0]  # type: ignore[index]
    return {"sinks": sink_rows, "total": total}
