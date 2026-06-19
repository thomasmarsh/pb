"""Inter-procedural data flow analysis — edge building across call boundaries.

Pure module — no I/O, no DuckDB.

Public API:
    build_interproc_flow(resolved_calls, proc_defs, proc_uses,
                         global_var_names, proc_info) -> GlobalDataFlow
"""

from __future__ import annotations

from dataclasses import dataclass, field

from pb_cli.core.type_resolution import parse_params


@dataclass
class InterProcEdge:
    caller_object: str
    caller_proc: str
    caller_line: int | None
    callee_object: str
    callee_proc: str
    edge_kind: str    # 'arg' | 'return' | 'global_write' | 'global_read'
    var_name: str
    caller_context: str
    callee_context: str


@dataclass
class ProcSummary:
    file: str
    object: str
    proc_name: str
    params_in: list[str]
    globals_read: list[str]
    globals_written: list[str]
    return_flows_to: list[dict]  # [{object, proc, lhs_var}]


@dataclass
class GlobalDataFlow:
    edges: list[InterProcEdge]
    summaries: list[ProcSummary]


def _index_by_proc(rows: list[dict], obj_key: str = "object", proc_key: str = "proc_name") -> dict[tuple[str, str], list[dict]]:
    """Group a list of row-dicts by (object, proc_name)."""
    index: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        key = (row[obj_key], row[proc_key])
        index.setdefault(key, []).append(row)
    return index


def match_args_to_params(
    caller_arg_vars: list[str],
    callee_params: list[str],
) -> list[tuple[str, str]]:
    """Pair caller arg variable names with callee param names by position.

    Extra args beyond the declared param count get callee_context='*extra'.
    """
    pairs: list[tuple[str, str]] = []
    for i, arg_var in enumerate(caller_arg_vars):
        param = callee_params[i] if i < len(callee_params) else "*extra"
        pairs.append((arg_var, param))
    return pairs


def build_interproc_flow(
    resolved_calls: list[dict],
    proc_defs: list[dict],
    proc_uses: list[dict],
    global_var_names: set[str],
    proc_info: list[dict],  # {file, object, name, params, return_type}
) -> GlobalDataFlow:
    """Build inter-procedural data flow edges.

    Produces:
    - arg edges: call-site argument variables → callee parameter names
    - return edges: callee return value → caller assignment target
    - global_write/global_read edges: procedures sharing global variables
    """
    # --- Index structures ---
    defs_by_proc = _index_by_proc(proc_defs)
    uses_by_proc = _index_by_proc(proc_uses)

    # Param names and return types, keyed by (object, proc_name)
    params_by_proc: dict[tuple[str, str], list[str]] = {}
    return_type_by_proc: dict[tuple[str, str], str] = {}
    for p in proc_info:
        key = (p["object"], p["name"])
        parsed = parse_params(p.get("params") or "")
        params_by_proc[key] = [name for name, _type in parsed]
        return_type_by_proc[key] = (p.get("return_type") or "").lower()

    edges: list[InterProcEdge] = []

    # --- Arg and return edges from direct call sites ---
    for rc in resolved_calls:
        if rc.get("resolution_kind") not in ("virtual", "inherited"):
            continue
        if not rc.get("target_object") or not rc.get("target_proc"):
            continue

        caller_obj = rc["object"]
        caller_proc = rc["from_proc"]
        call_line = rc.get("call_line")
        callee_obj = rc["target_object"]
        callee_proc = rc["target_proc"]
        callee_name_lower = (rc.get("to_name") or "").lower()

        caller_key = (caller_obj, caller_proc)
        callee_key = (callee_obj, callee_proc)
        callee_params = params_by_proc.get(callee_key, [])

        # Collect variable uses at the call line — these are the call arguments.
        # Exclude the callee function name itself (it appears as an rhs use for ExCall).
        call_arg_vars: list[str] = []
        seen_vars: set[str] = set()
        for u in uses_by_proc.get(caller_key, []):
            if u.get("line") != call_line:
                continue
            vname = u["var_name"]
            if vname.lower() == callee_name_lower:
                continue
            if vname not in seen_vars:
                seen_vars.add(vname)
                call_arg_vars.append(vname)

        for arg_var, param_name in match_args_to_params(call_arg_vars, callee_params):
            edges.append(InterProcEdge(
                caller_object=caller_obj,
                caller_proc=caller_proc,
                caller_line=call_line,
                callee_object=callee_obj,
                callee_proc=callee_proc,
                edge_kind="arg",
                var_name=arg_var,
                caller_context=arg_var,
                callee_context=param_name,
            ))

        # Return value flow: if callee has a non-void return type and the caller
        # has an assignment at call_line, the return flows into that assignment target.
        ret_type = return_type_by_proc.get(callee_key, "")
        if ret_type and ret_type not in ("none", ""):
            for d in defs_by_proc.get(caller_key, []):
                if d.get("line") == call_line and d.get("kind") == "assign":
                    edges.append(InterProcEdge(
                        caller_object=caller_obj,
                        caller_proc=caller_proc,
                        caller_line=call_line,
                        callee_object=callee_obj,
                        callee_proc=callee_proc,
                        edge_kind="return",
                        var_name=d["var_name"],
                        caller_context=d["var_name"],
                        callee_context="return",
                    ))

    # --- Global variable edges ---
    # Find which procedures write and read each global variable.
    global_writers: dict[str, set[tuple[str, str]]] = {}
    global_readers: dict[str, set[tuple[str, str]]] = {}

    for d in proc_defs:
        if d["var_name"] in global_var_names:
            key = (d["object"], d["proc_name"])
            global_writers.setdefault(d["var_name"], set()).add(key)

    for u in proc_uses:
        if u["var_name"] in global_var_names:
            key = (u["object"], u["proc_name"])
            global_readers.setdefault(u["var_name"], set()).add(key)

    for gvar in global_var_names:
        writers = global_writers.get(gvar, set())
        readers = global_readers.get(gvar, set())
        for writer_key in writers:
            for reader_key in readers:
                if writer_key == reader_key:
                    continue
                edges.append(InterProcEdge(
                    caller_object=writer_key[0],
                    caller_proc=writer_key[1],
                    caller_line=None,
                    callee_object=reader_key[0],
                    callee_proc=reader_key[1],
                    edge_kind="global_write",
                    var_name=gvar,
                    caller_context=gvar,
                    callee_context=gvar,
                ))

    # --- Build procedure summaries ---
    # Collect all known procedure keys from proc_info (includes file for disambiguation)
    all_proc_info: dict[tuple[str, str, str], dict] = {}
    for p in proc_info:
        key = (p["file"], p["object"], p["name"])
        all_proc_info[key] = p

    # Index return edges to build return_flows_to per callee
    return_flows: dict[tuple[str, str], list[dict]] = {}
    for e in edges:
        if e.edge_kind == "return":
            callee_key = (e.callee_object, e.callee_proc)
            return_flows.setdefault(callee_key, []).append({
                "object": e.caller_object,
                "proc": e.caller_proc,
                "lhs_var": e.var_name,
            })

    summaries: list[ProcSummary] = []
    for (file, obj, pname), p in all_proc_info.items():
        proc_key = (obj, pname)
        parsed = parse_params(p.get("params") or "")
        params_in = [name for name, _type in parsed]

        all_defs = defs_by_proc.get(proc_key, [])
        all_uses = uses_by_proc.get(proc_key, [])

        globals_written = sorted({
            d["var_name"] for d in all_defs if d["var_name"] in global_var_names
        })
        globals_read = sorted({
            u["var_name"] for u in all_uses if u["var_name"] in global_var_names
        })
        return_flows_to = return_flows.get(proc_key, [])

        summaries.append(ProcSummary(
            file=file,
            object=obj,
            proc_name=pname,
            params_in=params_in,
            globals_read=globals_read,
            globals_written=globals_written,
            return_flows_to=return_flows_to,
        ))

    return GlobalDataFlow(edges=edges, summaries=summaries)
