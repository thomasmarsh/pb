"""DuckDB I/O for taint analysis tables — called after build_interproc_tables."""

from __future__ import annotations

import json

from pb_cli.core.taint import build_taint_annotations, taint_analysis
from pb_cli.shell.db import Conn


def build_taint_tables(conn: Conn) -> None:
    """Run taint analysis and store results in four DuckDB tables."""
    conn.execute("DROP TABLE IF EXISTS taint_sources")
    conn.execute("DROP TABLE IF EXISTS taint_sinks")
    conn.execute("DROP TABLE IF EXISTS taint_paths")
    conn.execute("DROP TABLE IF EXISTS taint_annotations")

    conn.execute("""
        CREATE TABLE taint_sources (
            file       TEXT NOT NULL,
            object     TEXT NOT NULL,
            proc_name  TEXT NOT NULL,
            var_name   TEXT NOT NULL,
            line       INT,
            source_type TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE taint_sinks (
            file       TEXT NOT NULL,
            object     TEXT NOT NULL,
            proc_name  TEXT NOT NULL,
            var_name   TEXT NOT NULL,
            line       INT,
            sink_type  TEXT NOT NULL,
            severity   TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE taint_paths (
            id           INT NOT NULL,
            source_object TEXT NOT NULL,
            source_proc  TEXT NOT NULL,
            source_var   TEXT NOT NULL,
            source_line  INT,
            source_type  TEXT NOT NULL,
            sink_object  TEXT NOT NULL,
            sink_proc    TEXT NOT NULL,
            sink_var     TEXT NOT NULL,
            sink_line    INT,
            sink_type    TEXT NOT NULL,
            severity     TEXT NOT NULL,
            category     TEXT NOT NULL,
            steps_json   TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE taint_annotations (
            file           TEXT NOT NULL,
            object         TEXT NOT NULL,
            proc_name      TEXT NOT NULL,
            block_id       TEXT NOT NULL,
            is_taint_entry BOOLEAN NOT NULL,
            is_taint_sink  BOOLEAN NOT NULL,
            tainted_vars   TEXT
        )
    """)

    # Fetch sql_statements
    sql_rows = conn.execute("""
        SELECT file, object, proc_name, line, operation, raw_sql, has_into
        FROM sql_statements
    """).fetchall()
    sql_stmts = [
        {
            "file": r[0], "object": r[1], "proc_name": r[2], "line": r[3],
            "operation": r[4], "raw_sql": r[5], "has_into": r[6],
        }
        for r in sql_rows
    ]

    # Fetch procedures (for event/on handler source classification)
    proc_rows = conn.execute("""
        SELECT file, object, proc_type, name, params, start_line
        FROM procedures
    """).fetchall()
    procedures = [
        {
            "file": r[0], "object": r[1], "proc_type": r[2],
            "name": r[3], "params": r[4], "start_line": r[5],
        }
        for r in proc_rows
    ]

    # Fetch proc_defs and proc_uses
    def_rows = conn.execute(
        "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind FROM proc_defs"
    ).fetchall()
    proc_defs = [
        {
            "file": r[0], "object": r[1], "proc_name": r[2], "var_name": r[3],
            "block_id": r[4], "stmt_index": r[5], "line": r[6], "kind": r[7],
        }
        for r in def_rows
    ]

    use_rows = conn.execute(
        "SELECT file, object, proc_name, var_name, block_id, stmt_index, line, kind FROM proc_uses"
    ).fetchall()
    proc_uses = [
        {
            "file": r[0], "object": r[1], "proc_name": r[2], "var_name": r[3],
            "block_id": r[4], "stmt_index": r[5], "line": r[6], "kind": r[7],
        }
        for r in use_rows
    ]

    # Fetch interproc_edges
    edge_rows = conn.execute("""
        SELECT caller_object, caller_proc, caller_line, callee_object, callee_proc,
               edge_kind, var_name, caller_context, callee_context
        FROM interproc_edges
    """).fetchall()
    interproc_edges = [
        {
            "caller_object": r[0], "caller_proc": r[1], "caller_line": r[2],
            "callee_object": r[3], "callee_proc": r[4], "edge_kind": r[5],
            "var_name": r[6], "caller_context": r[7], "callee_context": r[8],
        }
        for r in edge_rows
    ]

    result = taint_analysis(interproc_edges, proc_defs, proc_uses, sql_stmts, procedures)

    # Insert taint_sources
    if result.sources:
        conn.executemany(
            "INSERT INTO taint_sources VALUES (?,?,?,?,?,?)",
            [(s.file, s.object, s.proc_name, s.var_name, s.line, s.source_type)
             for s in result.sources],
        )

    # Insert taint_sinks
    if result.sinks:
        conn.executemany(
            "INSERT INTO taint_sinks VALUES (?,?,?,?,?,?,?)",
            [(sk.file, sk.object, sk.proc_name, sk.var_name, sk.line, sk.sink_type, sk.severity)
             for sk in result.sinks],
        )

    # Insert taint_paths
    if result.paths:
        conn.executemany(
            "INSERT INTO taint_paths VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                (
                    i,
                    p.source.object, p.source.proc_name, p.source.var_name, p.source.line,
                    p.source.source_type,
                    p.sink.object, p.sink.proc_name, p.sink.var_name, p.sink.line,
                    p.sink.sink_type,
                    p.severity, p.category,
                    json.dumps([
                        {
                            "object": st.object,
                            "proc_name": st.proc_name,
                            "line": st.line,
                            "var_name": st.var_name,
                            "step_kind": st.step_kind,
                            "description": st.description,
                        }
                        for st in p.steps
                    ]),
                )
                for i, p in enumerate(result.paths)
            ],
        )

    # Reconstruct full tainted triple set from tainted_vars summary
    tainted: set[tuple[str, str, str]] = {
        (obj, proc, var)
        for var, locs in result.tainted_vars.items()
        for obj, proc in locs
    }
    annotations = build_taint_annotations(tainted, result.sources, result.sinks, proc_defs, proc_uses)

    if annotations:
        conn.executemany(
            "INSERT INTO taint_annotations VALUES (?,?,?,?,?,?,?)",
            [
                (
                    a["file"], a["object"], a["proc_name"], a["block_id"],
                    a["is_taint_entry"], a["is_taint_sink"],
                    json.dumps(a["tainted_vars"]),
                )
                for a in annotations
            ],
        )
