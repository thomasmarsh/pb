"""DuckDB I/O for type resolution tables — called after import + metrics."""

from __future__ import annotations

from pb_cli.core.models import GlobalVarRow, ResolvedCallRow, ResolvedTypeRow
from pb_cli.core.type_resolution import resolve_calls, resolve_types
from pb_cli.shell.db import INSERT, Conn


def _fetch_sets(conn: Conn) -> tuple[set[str], set[str]]:
    objects = {r[0] for r in conn.execute("SELECT name FROM objects").fetchall()}
    user_types = {r[0] for r in conn.execute("SELECT type_name FROM user_types").fetchall()}
    return objects, user_types


def _fetch_inherits(conn: Conn) -> list[tuple[str, str]]:
    return conn.execute("SELECT from_object, to_object FROM inherits").fetchall()


def _fetch_procedures(conn: Conn):
    from pb_cli.core.models import ProcedureRow
    return [
        ProcedureRow(*r)
        for r in conn.execute(
            "SELECT file, object, proc_type, name, modifiers, params, return_type, "
            "start_line, end_line, body_json, source_rendered, cyclomatic "
            "FROM procedures"
        ).fetchall()
    ]


def _fetch_local_vars(conn: Conn):
    from pb_cli.core.models import LocalVarRow
    return [
        LocalVarRow(*r)
        for r in conn.execute(
            "SELECT file, object, proc_name, var_name, var_type, start_line "
            "FROM local_variables"
        ).fetchall()
    ]


def _fetch_calls(conn: Conn):
    from pb_cli.core.models import CallRow
    return [
        CallRow(*r)
        for r in conn.execute(
            "SELECT file, object, from_proc, to_name, call_type FROM calls"
        ).fetchall()
    ]


def store_resolved_types(conn: Conn, rows: list[ResolvedTypeRow]) -> None:
    conn.execute("DELETE FROM resolved_types")
    if rows:
        conn.executemany(INSERT["resolved_types"], rows)


def store_resolved_calls(conn: Conn, rows: list[ResolvedCallRow]) -> None:
    conn.execute("DELETE FROM resolved_calls")
    if rows:
        conn.executemany(INSERT["resolved_calls"], rows)


def store_global_vars(conn: Conn, rows: list[GlobalVarRow]) -> None:
    conn.execute("DELETE FROM global_vars")
    if rows:
        conn.executemany(INSERT["global_vars"], rows)


def build_type_tables(conn: Conn) -> None:
    """Create resolved_types, resolved_calls, and global_vars tables.

    Called after pb index + metrics are complete.
    """
    objects, user_types = _fetch_sets(conn)
    inherits = _fetch_inherits(conn)
    procedures = _fetch_procedures(conn)
    local_vars = _fetch_local_vars(conn)
    calls = _fetch_calls(conn)

    types = resolve_types(local_vars, procedures, objects, user_types)
    store_resolved_types(conn, types)

    # Build var_types map for call resolution: (object, proc, var) → type
    var_types: dict[tuple[str, str, str], str] = {}
    for rt in types:
        if rt.resolved_target:
            var_types[(rt.object, rt.proc_name, rt.var_name)] = rt.resolved_target
        elif rt.resolved_kind == "primitive":
            var_types[(rt.object, rt.proc_name, rt.var_name)] = rt.raw_type

    # Also index global/instance variables from the global_vars table
    for row in conn.execute(
        "SELECT object, var_name, var_type FROM global_vars"
    ).fetchall():
        obj, vname, vtype = row
        # Use wildcard proc name so it matches any procedure in the object
        var_types[(obj, "", vname)] = vtype

    calls_resolved = resolve_calls(
        calls, procedures, inherits, all_objects=objects, var_types=var_types,
    )
    store_resolved_calls(conn, calls_resolved)
