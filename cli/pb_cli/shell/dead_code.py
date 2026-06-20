"""DuckDB I/O for dead_procedures table — called after build_taint_tables."""

from __future__ import annotations

from pb_cli.core.dead_code import compute_dead_procedures
from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn


def build_dead_code_table(conn: Conn) -> None:
    """Compute reachability and store dead procedures."""
    procedures = conn.execute(
        "SELECT object, name, proc_type, cyclomatic FROM procedures"
    ).fetchall()
    calls = conn.execute(
        "SELECT object, from_proc, to_name FROM calls"
    ).fetchall()
    resolved = conn.execute(
        "SELECT object, from_proc, target_object, target_proc "
        "FROM resolved_calls "
        "WHERE target_object IS NOT NULL AND target_proc IS NOT NULL"
    ).fetchall()
    inherits = conn.execute(
        "SELECT from_object, to_object FROM inherits"
    ).fetchall()
    dw_objects = {
        r[0] for r in conn.execute(
            "SELECT DISTINCT dw_name FROM dw_controls"
        ).fetchall()
    }

    dead = compute_dead_procedures(procedures, calls, resolved, inherits, dw_objects)

    conn.execute("DELETE FROM dead_procedures")
    if dead:
        bulk_insert(
            conn,
            "dead_procedures",
            ["object", "name", "proc_type", "cyclomatic", "confidence",
             "caller_count_naive", "caller_count_scoped"],
            [tuple(d) for d in dead],
        )
