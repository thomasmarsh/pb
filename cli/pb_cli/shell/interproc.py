"""DuckDB I/O for inter-procedural data flow tables — called after build_dataflow_tables."""

from __future__ import annotations

import json

from pb_cli.core.interproc import build_interproc_flow
from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn


def build_interproc_tables(conn: Conn) -> None:
    """Build interproc_edges and procedure_summaries tables.

    Reads resolved_calls (virtual+inherited), proc_defs, proc_uses, global_vars,
    and procedures from DuckDB. Calls the pure build_interproc_flow, then stores
    results. Does not re-run analyze_procedure.
    """
    conn.execute("TRUNCATE TABLE interproc_edges")
    conn.execute("TRUNCATE TABLE procedure_summaries")

    # Fetch resolved_calls: virtual/inherited for user-proc edges; builtin calls
    # with a non-void return_type for synthetic return/arg edge generation.
    rc_rows = conn.execute("""
        SELECT object, from_proc, to_name, call_line, target_object, target_proc,
               resolution_kind, return_type
        FROM resolved_calls
        WHERE (resolution_kind IN ('virtual', 'inherited')
               AND target_object IS NOT NULL
               AND target_proc IS NOT NULL)
           OR (resolution_kind = 'builtin'
               AND return_type IS NOT NULL
               AND lower(return_type) NOT IN ('void', 'none'))
    """).fetchall()
    resolved_calls = [
        {
            "object": r[0], "from_proc": r[1], "to_name": r[2],
            "call_line": r[3], "target_object": r[4], "target_proc": r[5],
            "resolution_kind": r[6], "return_type": r[7],
        }
        for r in rc_rows
    ]

    # Fetch proc_defs
    def_rows = conn.execute(
        "SELECT object, proc_name, var_name, line, kind FROM proc_defs"
    ).fetchall()
    proc_defs = [
        {"object": r[0], "proc_name": r[1], "var_name": r[2], "line": r[3], "kind": r[4]}
        for r in def_rows
    ]

    # Fetch proc_uses
    use_rows = conn.execute(
        "SELECT object, proc_name, var_name, line, kind FROM proc_uses"
    ).fetchall()
    proc_uses = [
        {"object": r[0], "proc_name": r[1], "var_name": r[2], "line": r[3], "kind": r[4]}
        for r in use_rows
    ]

    # Fetch global var names
    gvar_rows = conn.execute("SELECT DISTINCT var_name FROM global_vars").fetchall()
    global_var_names: set[str] = {r[0] for r in gvar_rows}

    # Fetch procedure metadata — use (file, object, name) to handle duplicate names
    proc_rows = conn.execute(
        "SELECT file, object, name, params, return_type FROM procedures"
    ).fetchall()
    proc_info = [
        {"file": r[0], "object": r[1], "name": r[2], "params": r[3], "return_type": r[4]}
        for r in proc_rows
    ]

    gdf = build_interproc_flow(resolved_calls, proc_defs, proc_uses, global_var_names, proc_info)

    _EDGE_COLS = [
        "caller_object", "caller_proc", "caller_line",
        "callee_object", "callee_proc", "edge_kind",
        "var_name", "caller_context", "callee_context",
    ]
    bulk_insert(conn, "interproc_edges", _EDGE_COLS, [
        (
            e.caller_object, e.caller_proc, e.caller_line,
            e.callee_object, e.callee_proc, e.edge_kind,
            e.var_name, e.caller_context, e.callee_context,
        )
        for e in gdf.edges
    ])

    _SUMMARY_COLS = [
        "file", "object", "proc_name",
        "params_in", "globals_read", "globals_written", "return_flows_to",
    ]
    bulk_insert(conn, "procedure_summaries", _SUMMARY_COLS, [
        (
            s.file, s.object, s.proc_name,
            json.dumps(s.params_in) if s.params_in else None,
            json.dumps(s.globals_read) if s.globals_read else None,
            json.dumps(s.globals_written) if s.globals_written else None,
            json.dumps(s.return_flows_to) if s.return_flows_to else None,
        )
        for s in gdf.summaries
    ])
