"""Tests for core/slicing.py — backward and forward program slicing."""

from pb_cli.core.slicing import (
    SliceResult,
    SliceStep,
    backward_slice,
    build_proc_def_use,
    find_def_at_or_before,
    find_uses_at_or_after,
    forward_slice,
)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


def _def(obj: str, proc: str, var: str, line: int, kind: str = "assign", block: str = "b0") -> dict:
    return {"object": obj, "proc_name": proc, "var_name": var, "line": line,
            "kind": kind, "block_id": block, "stmt_index": 0}


def _use(obj: str, proc: str, var: str, line: int, kind: str = "rhs", block: str = "b0") -> dict:
    return {"object": obj, "proc_name": proc, "var_name": var, "line": line,
            "kind": kind, "block_id": block, "stmt_index": 0}


def _arg_edge(caller_obj, caller_proc, caller_line, caller_ctx, callee_obj, callee_proc, callee_ctx) -> dict:
    return {
        "caller_object": caller_obj, "caller_proc": caller_proc,
        "caller_line": caller_line, "caller_context": caller_ctx,
        "callee_object": callee_obj, "callee_proc": callee_proc,
        "callee_context": callee_ctx,
        "edge_kind": "arg", "var_name": caller_ctx,
    }


def _return_edge(callee_obj, callee_proc, caller_obj, caller_proc, caller_ctx) -> dict:
    return {
        "callee_object": callee_obj, "callee_proc": callee_proc,
        "caller_object": caller_obj, "caller_proc": caller_proc,
        "caller_context": caller_ctx,
        "edge_kind": "return", "var_name": caller_ctx,
        "caller_line": None, "callee_context": caller_ctx,
    }


# ---------------------------------------------------------------------------
# build_proc_def_use
# ---------------------------------------------------------------------------


def test_build_proc_def_use_indexes_by_key():
    proc_defs = [_def("w", "p", "x", 10), _def("w", "p", "y", 20)]
    proc_uses = [_use("w", "p", "x", 15)]
    pdu = build_proc_def_use(proc_defs, proc_uses)
    assert ("w", "p") in pdu
    assert "x" in pdu[("w", "p")]["all_defs"]
    assert "y" in pdu[("w", "p")]["all_defs"]
    assert "x" in pdu[("w", "p")]["all_uses"]


def test_build_proc_def_use_multiple_procs():
    proc_defs = [_def("w", "p1", "x", 5), _def("w", "p2", "y", 8)]
    pdu = build_proc_def_use(proc_defs, [])
    assert ("w", "p1") in pdu
    assert ("w", "p2") in pdu


# ---------------------------------------------------------------------------
# find_def_at_or_before
# ---------------------------------------------------------------------------


def test_find_def_at_or_before_returns_most_recent():
    pdu = build_proc_def_use([_def("w", "p", "x", 5), _def("w", "p", "x", 10)], [])
    d = find_def_at_or_before(pdu[("w", "p")], "x", 12)
    assert d is not None
    assert d["line"] == 10


def test_find_def_at_or_before_exact_match():
    pdu = build_proc_def_use([_def("w", "p", "x", 7)], [])
    d = find_def_at_or_before(pdu[("w", "p")], "x", 7)
    assert d is not None
    assert d["line"] == 7


def test_find_def_at_or_before_none_when_all_after():
    pdu = build_proc_def_use([_def("w", "p", "x", 20)], [])
    d = find_def_at_or_before(pdu[("w", "p")], "x", 5)
    assert d is None


# ---------------------------------------------------------------------------
# find_uses_at_or_after
# ---------------------------------------------------------------------------


def test_find_uses_at_or_after_sorted():
    pdu = build_proc_def_use([], [_use("w", "p", "x", 30), _use("w", "p", "x", 10), _use("w", "p", "x", 20)])
    uses = find_uses_at_or_after(pdu[("w", "p")], "x", 15)
    assert [u["line"] for u in uses] == [20, 30]


def test_find_uses_at_or_after_empty_when_none_qualify():
    pdu = build_proc_def_use([], [_use("w", "p", "x", 5)])
    uses = find_uses_at_or_after(pdu[("w", "p")], "x", 10)
    assert uses == []


# ---------------------------------------------------------------------------
# backward_slice — intra-procedural
# ---------------------------------------------------------------------------


def test_backward_slice_simple_def():
    """Backward from use of x at line 20: finds def of x at line 10."""
    proc_defs = [_def("w", "p", "x", 10)]
    proc_uses = [_use("w", "p", "x", 20)]
    pdu = build_proc_def_use(proc_defs, proc_uses)
    result = backward_slice("w", "p", 20, "x", pdu, [])
    assert result.direction == "backward"
    assert result.origin_var == "x"
    kinds = [s.step_kind for s in result.steps]
    assert "definition" in kinds


def test_backward_slice_definition_chain():
    """x defined using y at line 10; y defined at line 5."""
    proc_defs = [_def("w", "p", "x", 10), _def("w", "p", "y", 5)]
    proc_uses = [_use("w", "p", "y", 10)]  # y used at same line x is defined
    pdu = build_proc_def_use(proc_defs, proc_uses)
    result = backward_slice("w", "p", 15, "x", pdu, [])
    vars_in_steps = {s.var_name for s in result.steps}
    assert "x" in vars_in_steps
    assert "y" in vars_in_steps


def test_backward_slice_no_def_returns_empty():
    """Backward from unknown var with no definition: returns empty steps."""
    pdu = build_proc_def_use([], [])
    result = backward_slice("w", "p", 10, "z", pdu, [])
    assert result.steps == []
    assert result.origin_var == "z"


def test_backward_slice_auto_detect_var():
    """var_name=None: auto-detect from defs at the given line."""
    proc_defs = [_def("w", "p", "x", 10)]
    pdu = build_proc_def_use(proc_defs, [])
    result = backward_slice("w", "p", 10, None, pdu, [])
    assert result.origin_var == "x"


# ---------------------------------------------------------------------------
# backward_slice — inter-procedural (via arg edges)
# ---------------------------------------------------------------------------


def test_backward_slice_crosses_call_boundary():
    """Backward through an arg edge: callee param → caller variable."""
    # callee proc: "callee" has param "p_val" (defined by arg edge)
    proc_defs = [_def("w", "callee", "p_val", 1, "local_var")]
    proc_uses = []
    # caller: caller passes "ls_src" at line 30 to callee as "p_val"
    caller_defs = [_def("w", "caller", "ls_src", 20)]
    pdu = build_proc_def_use(proc_defs + caller_defs, proc_uses)

    edges = [_arg_edge("w", "caller", 30, "ls_src", "w", "callee", "p_val")]
    result = backward_slice("w", "callee", 5, "p_val", pdu, edges)

    kinds = [s.step_kind for s in result.steps]
    assert "arg_pass" in kinds
    vars_in_steps = {s.var_name for s in result.steps}
    assert "ls_src" in vars_in_steps
    procs = result.procedures_traversed
    assert "w.callee" in procs
    assert "w.caller" in procs


# ---------------------------------------------------------------------------
# forward_slice — intra-procedural
# ---------------------------------------------------------------------------


def test_forward_slice_simple_use():
    """Forward from def of x at line 5: finds use at line 15."""
    proc_defs = [_def("w", "p", "x", 5)]
    proc_uses = [_use("w", "p", "x", 15)]
    pdu = build_proc_def_use(proc_defs, proc_uses)
    result = forward_slice("w", "p", 5, "x", pdu, [])
    assert result.direction == "forward"
    assert result.origin_var == "x"
    assert any(s.step_kind == "use" and s.line == 15 for s in result.steps)


def test_forward_slice_use_chain():
    """x used at line 10 defining y; y then used at line 20."""
    proc_defs = [_def("w", "p", "x", 5), _def("w", "p", "y", 10)]
    proc_uses = [_use("w", "p", "x", 10), _use("w", "p", "y", 20)]
    pdu = build_proc_def_use(proc_defs, proc_uses)
    result = forward_slice("w", "p", 5, "x", pdu, [])
    vars_in_steps = {s.var_name for s in result.steps}
    assert "x" in vars_in_steps
    assert "y" in vars_in_steps


def test_forward_slice_no_uses_returns_empty():
    """Forward from var with no downstream uses: returns empty steps."""
    proc_defs = [_def("w", "p", "x", 5)]
    pdu = build_proc_def_use(proc_defs, [])
    result = forward_slice("w", "p", 5, "x", pdu, [])
    assert result.steps == []


def test_forward_slice_auto_detect_var():
    """var_name=None: auto-detect from uses at the given line."""
    pdu = build_proc_def_use([], [_use("w", "p", "x", 10)])
    result = forward_slice("w", "p", 10, None, pdu, [])
    assert result.origin_var == "x"


# ---------------------------------------------------------------------------
# forward_slice — inter-procedural (via arg and return edges)
# ---------------------------------------------------------------------------


def test_forward_slice_crosses_call_boundary():
    """Forward through arg edge: caller var → callee param."""
    proc_defs = [_def("w", "caller", "ls_src", 5)]
    proc_uses = [_use("w", "caller", "ls_src", 10)]
    callee_defs = [_def("w", "callee", "p_val", 1, "local_var")]
    callee_uses = [_use("w", "callee", "p_val", 15)]
    pdu = build_proc_def_use(proc_defs + callee_defs, proc_uses + callee_uses)

    edges = [_arg_edge("w", "caller", 10, "ls_src", "w", "callee", "p_val")]
    result = forward_slice("w", "caller", 5, "ls_src", pdu, edges)

    kinds = [s.step_kind for s in result.steps]
    assert "arg_pass" in kinds
    vars_in_steps = {s.var_name for s in result.steps}
    assert "p_val" in vars_in_steps
    assert "w.callee" in result.procedures_traversed


def test_forward_slice_crosses_return_boundary():
    """Forward through return edge: callee var returned → caller lhs."""
    callee_defs = [_def("w", "callee", "ret_val", 5)]
    callee_uses = [_use("w", "callee", "ret_val", 10, "return")]
    caller_defs = [_def("w", "caller", "ls_result", 1)]
    caller_uses = [_use("w", "caller", "ls_result", 20)]
    pdu = build_proc_def_use(callee_defs + caller_defs, callee_uses + caller_uses)

    edges = [_return_edge("w", "callee", "w", "caller", "ls_result")]
    result = forward_slice("w", "callee", 5, "ret_val", pdu, edges)

    kinds = [s.step_kind for s in result.steps]
    assert "return" in kinds
    vars_in_steps = {s.var_name for s in result.steps}
    assert "ls_result" in vars_in_steps


# ---------------------------------------------------------------------------
# max_steps limit
# ---------------------------------------------------------------------------


def test_backward_slice_respects_max_steps():
    """Backward slice truncates at max_steps."""
    # Chain: x10 ← y9 ← z8 ← ... a1 (10 levels)
    vars_ = [chr(ord("a") + i) for i in range(10)]
    proc_defs = [_def("w", "p", v, i + 1) for i, v in enumerate(vars_)]
    proc_uses = [_use("w", "p", vars_[i], i + 2) for i in range(9)]
    pdu = build_proc_def_use(proc_defs, proc_uses)
    result = backward_slice("w", "p", 10, vars_[-1], pdu, [], max_steps=3)
    assert len(result.steps) <= 3


def test_forward_slice_respects_max_steps():
    """Forward slice truncates at max_steps."""
    proc_defs = [_def("w", "p", "x", 1)]
    proc_uses = [_use("w", "p", "x", i) for i in range(2, 20)]
    pdu = build_proc_def_use(proc_defs, proc_uses)
    result = forward_slice("w", "p", 1, "x", pdu, [], max_steps=5)
    assert len(result.steps) <= 5


# ---------------------------------------------------------------------------
# Unknown proc / var returns empty result
# ---------------------------------------------------------------------------


def test_backward_slice_unknown_proc():
    pdu = build_proc_def_use([], [])
    result = backward_slice("no_obj", "no_proc", 1, "x", pdu, [])
    assert result.steps == []


def test_forward_slice_unknown_proc():
    pdu = build_proc_def_use([], [])
    result = forward_slice("no_obj", "no_proc", 1, None, pdu, [])
    assert result.steps == []
    assert result.origin_var == ""
