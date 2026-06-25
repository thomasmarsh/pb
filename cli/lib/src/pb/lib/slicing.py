"""Program slicing engine — backward and forward slices over the P3 data flow model.

Pure module — no I/O, no DuckDB.

Public API:
    build_proc_def_use(proc_defs, proc_uses) -> dict[tuple[str, str], dict]
    find_def_at_or_before(pdu, var, line) -> dict | None
    find_uses_at_or_after(pdu, var, line) -> list[dict]
    backward_slice(...) -> SliceResult
    forward_slice(...) -> SliceResult
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class SliceStep:
    object: str
    proc_name: str
    line: int | None
    var_name: str
    statement_text: str
    step_kind: str    # 'definition' | 'use' | 'arg_pass' | 'return' | 'global_read'
    block_id: str | None


@dataclass
class SliceResult:
    origin_object: str
    origin_proc: str
    origin_line: int
    origin_var: str
    direction: str    # 'backward' | 'forward'
    steps: list[SliceStep]
    procedures_traversed: list[str]


def build_proc_def_use(
    proc_defs: list[dict],
    proc_uses: list[dict],
) -> dict[tuple[str, str], dict]:
    """Index proc_defs/proc_uses rows by (object, proc_name) → ProcDefUse dict.

    ProcDefUse shape:
      {
        "all_defs": {var_name: [{line, kind, block_id, stmt_index}]},
        "all_uses": {var_name: [{line, kind, block_id, stmt_index}]},
      }
    """
    result: dict[tuple[str, str], dict] = {}
    for d in proc_defs:
        k = (d["object"], d["proc_name"])
        pdu = result.setdefault(k, {"all_defs": {}, "all_uses": {}})
        pdu["all_defs"].setdefault(d["var_name"], []).append({
            "line": d["line"],
            "kind": d["kind"],
            "block_id": d["block_id"],
            "stmt_index": d["stmt_index"],
        })
    for u in proc_uses:
        k = (u["object"], u["proc_name"])
        pdu = result.setdefault(k, {"all_defs": {}, "all_uses": {}})
        pdu["all_uses"].setdefault(u["var_name"], []).append({
            "line": u["line"],
            "kind": u["kind"],
            "block_id": u["block_id"],
            "stmt_index": u["stmt_index"],
        })
    return result


def find_def_at_or_before(pdu: dict, var: str, line: int) -> dict | None:
    """Find the most recent def of var at or before line in a ProcDefUse dict."""
    defs = [
        d for d in pdu.get("all_defs", {}).get(var, [])
        if d["line"] is not None and d["line"] <= line
    ]
    return max(defs, key=lambda d: d["line"]) if defs else None


def find_uses_at_or_after(pdu: dict, var: str, line: int) -> list[dict]:
    """Find all uses of var at or after line in a ProcDefUse dict."""
    return sorted(
        [
            u for u in pdu.get("all_uses", {}).get(var, [])
            if u["line"] is not None and u["line"] >= line
        ],
        key=lambda u: u["line"],
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _build_interproc_indexes(interproc_edges: list[dict]) -> tuple[
    dict[tuple[str, str, str], list[dict]],  # arg_by_callee_param
    dict[tuple[str, str, str], list[dict]],  # arg_by_caller_context
    dict[tuple[str, str], list[dict]],        # return_by_callee
]:
    """Build lookup indexes over interproc edges for slicing."""
    arg_by_callee: dict[tuple[str, str, str], list[dict]] = {}
    arg_by_caller: dict[tuple[str, str, str], list[dict]] = {}
    return_by_callee: dict[tuple[str, str], list[dict]] = {}

    for e in interproc_edges:
        kind = e.get("edge_kind", "")
        if kind == "arg":
            callee_k = (e["callee_object"], e["callee_proc"], e["callee_context"])
            arg_by_callee.setdefault(callee_k, []).append(e)
            caller_k = (e["caller_object"], e["caller_proc"], e["caller_context"])
            arg_by_caller.setdefault(caller_k, []).append(e)
        elif kind == "return":
            ret_k = (e["callee_object"], e["callee_proc"])
            return_by_callee.setdefault(ret_k, []).append(e)

    return arg_by_callee, arg_by_caller, return_by_callee


def _vars_used_at_line(pdu: dict, line: int) -> list[str]:
    """All distinct variable names used at a given line."""
    seen: set[str] = set()
    result: list[str] = []
    for var, uses in pdu.get("all_uses", {}).items():
        for u in uses:
            if u["line"] == line and var not in seen:
                result.append(var)
                seen.add(var)
    return result


def _vars_defined_at_line(pdu: dict, line: int) -> list[str]:
    """All distinct variable names defined at a given line."""
    seen: set[str] = set()
    result: list[str] = []
    for var, defs in pdu.get("all_defs", {}).items():
        for d in defs:
            if d["line"] == line and var not in seen:
                result.append(var)
                seen.add(var)
    return result


def _detect_var_at_line_def(pdu: dict, line: int) -> str | None:
    """Auto-detect: first variable defined at exactly this line."""
    for var, defs in pdu.get("all_defs", {}).items():
        for d in defs:
            if d["line"] == line:
                return var
    return None


def _detect_var_at_line_use(pdu: dict, line: int) -> str | None:
    """Auto-detect: first variable used at exactly this line."""
    for var, uses in pdu.get("all_uses", {}).items():
        for u in uses:
            if u["line"] == line:
                return var
    return None


# ---------------------------------------------------------------------------
# Backward slice
# ---------------------------------------------------------------------------


def backward_slice(
    object_name: str,
    proc_name: str,
    line: int,
    var_name: str | None,
    proc_def_uses: dict[tuple[str, str], dict],
    interproc_edges: list[dict],
    max_steps: int = 50,
) -> SliceResult:
    """Compute backward slice from expression at given program point.

    Follows def-use chains backward from the use at (line, var_name) to all
    reaching definitions, recursing through inter-procedural arg edges.
    Steps are returned in source-first order (deepest predecessor first).
    """
    arg_by_callee, _, _ = _build_interproc_indexes(interproc_edges)

    if var_name is None:
        pdu = proc_def_uses.get((object_name, proc_name), {})
        var_name = _detect_var_at_line_def(pdu, line)
    if var_name is None:
        return SliceResult(
            origin_object=object_name,
            origin_proc=proc_name,
            origin_line=line,
            origin_var="",
            direction="backward",
            steps=[],
            procedures_traversed=[],
        )

    result: list[SliceStep] = []
    visited: set[tuple[str, str, int | None, str]] = set()
    procs_seen: set[str] = set()

    def trace(obj: str, proc: str, ln: int, var: str) -> None:
        key = (obj, proc, ln, var)
        if key in visited or len(result) >= max_steps:
            return
        visited.add(key)
        procs_seen.add(f"{obj}.{proc}")

        pdu = proc_def_uses.get((obj, proc), {})
        d = find_def_at_or_before(pdu, var, ln)

        if d is not None:
            def_line: int = d["line"]
            result.append(SliceStep(
                object=obj, proc_name=proc, line=def_line,
                var_name=var, statement_text="",
                step_kind="definition", block_id=d.get("block_id"),
            ))
            for used_var in _vars_used_at_line(pdu, def_line):
                if used_var != var:
                    trace(obj, proc, def_line, used_var)

        # Check if var is a parameter of this proc — follow arg edges to caller
        for e in arg_by_callee.get((obj, proc, var), []):
            caller_line = e.get("caller_line") or 0
            caller_var = e["caller_context"]
            result.append(SliceStep(
                object=e["caller_object"], proc_name=e["caller_proc"],
                line=e.get("caller_line"), var_name=caller_var,
                statement_text="", step_kind="arg_pass", block_id=None,
            ))
            trace(e["caller_object"], e["caller_proc"], caller_line, caller_var)

    trace(object_name, proc_name, line, var_name)
    result.reverse()

    return SliceResult(
        origin_object=object_name,
        origin_proc=proc_name,
        origin_line=line,
        origin_var=var_name,
        direction="backward",
        steps=result,
        procedures_traversed=sorted(procs_seen),
    )


# ---------------------------------------------------------------------------
# Forward slice
# ---------------------------------------------------------------------------


def forward_slice(
    object_name: str,
    proc_name: str,
    line: int,
    var_name: str | None,
    proc_def_uses: dict[tuple[str, str], dict],
    interproc_edges: list[dict],
    max_steps: int = 50,
) -> SliceResult:
    """Compute forward slice from definition at given program point.

    Follows use-def chains forward from the definition at (line, var_name) to
    all downstream uses, recursing through inter-procedural arg and return edges.
    """
    _, arg_by_caller, return_by_callee = _build_interproc_indexes(interproc_edges)

    if var_name is None:
        pdu = proc_def_uses.get((object_name, proc_name), {})
        var_name = _detect_var_at_line_use(pdu, line)
    if var_name is None:
        return SliceResult(
            origin_object=object_name,
            origin_proc=proc_name,
            origin_line=line,
            origin_var="",
            direction="forward",
            steps=[],
            procedures_traversed=[],
        )

    result: list[SliceStep] = []
    visited: set[tuple[str, str, int, str]] = set()
    procs_seen: set[str] = set()

    def trace(obj: str, proc: str, ln: int, var: str) -> None:
        key = (obj, proc, ln, var)
        if key in visited or len(result) >= max_steps:
            return
        visited.add(key)
        procs_seen.add(f"{obj}.{proc}")

        pdu = proc_def_uses.get((obj, proc), {})

        for u in find_uses_at_or_after(pdu, var, ln):
            if len(result) >= max_steps:
                break
            use_line = u["line"]
            result.append(SliceStep(
                object=obj, proc_name=proc, line=use_line,
                var_name=var, statement_text="",
                step_kind="use", block_id=u.get("block_id"),
            ))
            for defined_var in _vars_defined_at_line(pdu, use_line):
                if defined_var != var:
                    trace(obj, proc, use_line, defined_var)

        # Follow arg edges forward: var passed as argument to callees
        for e in arg_by_caller.get((obj, proc, var), []):
            callee_var = e["callee_context"]
            result.append(SliceStep(
                object=e["callee_object"], proc_name=e["callee_proc"],
                line=None, var_name=callee_var,
                statement_text="", step_kind="arg_pass", block_id=None,
            ))
            trace(e["callee_object"], e["callee_proc"], 0, callee_var)

        # Follow return edges forward: var returned from this proc to callers
        return_uses = [
            u for u in pdu.get("all_uses", {}).get(var, [])
            if u.get("kind") == "return" and u["line"] is not None and u["line"] >= ln
        ]
        if return_uses:
            for e in return_by_callee.get((obj, proc), []):
                caller_var = e["caller_context"]
                result.append(SliceStep(
                    object=e["caller_object"], proc_name=e["caller_proc"],
                    line=None, var_name=caller_var,
                    statement_text="", step_kind="return", block_id=None,
                ))
                trace(e["caller_object"], e["caller_proc"], 0, caller_var)

    trace(object_name, proc_name, line, var_name)

    return SliceResult(
        origin_object=object_name,
        origin_proc=proc_name,
        origin_line=line,
        origin_var=var_name,
        direction="forward",
        steps=result,
        procedures_traversed=sorted(procs_seen),
    )
