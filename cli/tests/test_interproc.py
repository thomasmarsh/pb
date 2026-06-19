"""Tests for inter-procedural data flow analysis (core/interproc.py)."""

from pb_cli.core.interproc import (
    GlobalDataFlow,
    InterProcEdge,
    build_interproc_flow,
    match_args_to_params,
)


# --- Helpers -----------------------------------------------------------------


def _rc(
    obj: str,
    from_proc: str,
    to_name: str,
    target_obj: str,
    target_proc: str,
    call_line: int | None = 10,
    kind: str = "virtual",
) -> dict:
    return {
        "object": obj,
        "from_proc": from_proc,
        "to_name": to_name,
        "call_line": call_line,
        "target_object": target_obj,
        "target_proc": target_proc,
        "resolution_kind": kind,
    }


def _def(obj: str, proc: str, var: str, line: int, kind: str = "assign") -> dict:
    return {"object": obj, "proc_name": proc, "var_name": var, "line": line, "kind": kind}


def _use(obj: str, proc: str, var: str, line: int, kind: str = "rhs") -> dict:
    return {"object": obj, "proc_name": proc, "var_name": var, "line": line, "kind": kind}


def _proc(obj: str, name: str, params: str = "", return_type: str = "none", file: str = "w.srf") -> dict:
    return {"file": file, "object": obj, "name": name, "params": params, "return_type": return_type}


def _edges_of_kind(gdf: GlobalDataFlow, kind: str) -> list[InterProcEdge]:
    return [e for e in gdf.edges if e.edge_kind == kind]


# --- match_args_to_params ----------------------------------------------------


class TestMatchArgsToParams:
    def test_exact_match(self):
        pairs = match_args_to_params(["x", "y"], ["p1", "p2"])
        assert pairs == [("x", "p1"), ("y", "p2")]

    def test_fewer_args_than_params(self):
        pairs = match_args_to_params(["x"], ["p1", "p2"])
        assert pairs == [("x", "p1")]

    def test_extra_args_marked(self):
        pairs = match_args_to_params(["x", "y", "z"], ["p1"])
        assert pairs == [("x", "p1"), ("y", "*extra"), ("z", "*extra")]

    def test_no_args(self):
        assert match_args_to_params([], ["p1", "p2"]) == []

    def test_no_params(self):
        pairs = match_args_to_params(["x", "y"], [])
        assert pairs == [("x", "*extra"), ("y", "*extra")]


# --- build_interproc_flow: arg edges -----------------------------------------


class TestArgEdges:
    def test_simple_arg_edge(self):
        """A calls B(x) → arg edge mapping x to B's first parameter."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=5)]
        defs = []
        uses = [_use("oa", "procA", "x", 5, "rhs")]
        procs = [
            _proc("oa", "procA"),
            _proc("ob", "procB", params="integer p1"),
        ]
        gdf = build_interproc_flow(rc, defs, uses, set(), procs)
        arg_edges = _edges_of_kind(gdf, "arg")
        assert len(arg_edges) == 1
        e = arg_edges[0]
        assert e.caller_object == "oa"
        assert e.caller_proc == "procA"
        assert e.callee_object == "ob"
        assert e.callee_proc == "procB"
        assert e.var_name == "x"
        assert e.caller_context == "x"
        assert e.callee_context == "p1"

    def test_callee_name_excluded_from_args(self):
        """The callee function name appearing as rhs use is not treated as an arg."""
        rc = [_rc("oa", "procA", "myfunc", "ob", "myfunc", call_line=7)]
        uses = [
            _use("oa", "procA", "myfunc", 7, "rhs"),  # callee name — excluded
            _use("oa", "procA", "argVar", 7, "rhs"),   # real arg
        ]
        procs = [_proc("oa", "procA"), _proc("ob", "myfunc", "string s")]
        gdf = build_interproc_flow(rc, [], uses, set(), procs)
        arg_edges = _edges_of_kind(gdf, "arg")
        assert len(arg_edges) == 1
        assert arg_edges[0].var_name == "argVar"
        assert arg_edges[0].callee_context == "s"

    def test_multiple_args_matched_by_position(self):
        """Multiple args are matched positionally to callee params."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=3)]
        uses = [
            _use("oa", "procA", "v1", 3),
            _use("oa", "procA", "v2", 3),
        ]
        procs = [
            _proc("oa", "procA"),
            _proc("ob", "procB", "integer a, string b"),
        ]
        gdf = build_interproc_flow(rc, [], uses, set(), procs)
        arg_edges = sorted(_edges_of_kind(gdf, "arg"), key=lambda e: e.caller_context)
        assert [(e.var_name, e.callee_context) for e in arg_edges] == [("v1", "a"), ("v2", "b")]

    def test_extra_args_beyond_params(self):
        """Args beyond declared param count get callee_context='*extra'."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=1)]
        uses = [
            _use("oa", "procA", "a", 1),
            _use("oa", "procA", "b", 1),
            _use("oa", "procA", "c", 1),
        ]
        procs = [_proc("oa", "procA"), _proc("ob", "procB", "integer x")]
        gdf = build_interproc_flow(rc, [], uses, set(), procs)
        arg_edges = _edges_of_kind(gdf, "arg")
        extras = [e for e in arg_edges if e.callee_context == "*extra"]
        assert len(extras) == 2

    def test_unresolved_call_no_edge(self):
        """Unresolved calls produce no edges."""
        rc = [_rc("oa", "procA", "mystery", None, None, kind="unresolved")]
        uses = [_use("oa", "procA", "x", 5)]
        procs = [_proc("oa", "procA")]
        gdf = build_interproc_flow(rc, [], uses, set(), procs)
        assert gdf.edges == []

    def test_builtin_call_no_edge(self):
        """Builtin calls (no callee body) produce no edges."""
        rc = [_rc("oa", "procA", "MessageBox", "pb_builtin", "MessageBox", kind="builtin")]
        uses = [_use("oa", "procA", "msg", 5)]
        procs = [_proc("oa", "procA")]
        gdf = build_interproc_flow(rc, [], uses, set(), procs)
        assert gdf.edges == []

    def test_uses_on_different_line_not_included(self):
        """Uses from other lines in the same procedure are excluded."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=10)]
        uses = [
            _use("oa", "procA", "wrongLine", 5),   # different line
            _use("oa", "procA", "rightLine", 10),  # matches call_line
        ]
        procs = [_proc("oa", "procA"), _proc("ob", "procB", "integer p")]
        gdf = build_interproc_flow(rc, [], uses, set(), procs)
        arg_edges = _edges_of_kind(gdf, "arg")
        assert len(arg_edges) == 1
        assert arg_edges[0].var_name == "rightLine"


# --- build_interproc_flow: return edges --------------------------------------


class TestReturnEdges:
    def test_return_value_flows_to_caller(self):
        """When B returns integer and A assigns its result, a return edge is created."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=20)]
        defs = [_def("oa", "procA", "result", 20, "assign")]
        procs = [_proc("oa", "procA"), _proc("ob", "procB", return_type="integer")]
        gdf = build_interproc_flow(rc, defs, [], set(), procs)
        ret_edges = _edges_of_kind(gdf, "return")
        assert len(ret_edges) == 1
        e = ret_edges[0]
        assert e.var_name == "result"
        assert e.callee_context == "return"
        assert e.caller_object == "oa"
        assert e.callee_object == "ob"

    def test_void_callee_no_return_edge(self):
        """Void (none) return type produces no return edge even if assignment exists."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=5)]
        defs = [_def("oa", "procA", "x", 5, "assign")]
        procs = [_proc("oa", "procA"), _proc("ob", "procB", return_type="none")]
        gdf = build_interproc_flow(rc, defs, [], set(), procs)
        assert _edges_of_kind(gdf, "return") == []

    def test_no_assignment_no_return_edge(self):
        """If the caller doesn't assign the return value, no return edge."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=5)]
        defs = []   # no assignment at call_line
        procs = [_proc("oa", "procA"), _proc("ob", "procB", return_type="string")]
        gdf = build_interproc_flow(rc, defs, [], set(), procs)
        assert _edges_of_kind(gdf, "return") == []


# --- build_interproc_flow: global edges --------------------------------------


class TestGlobalEdges:
    def test_global_write_read_edge(self):
        """A writes global G, B reads G → global_write edge from A to B."""
        global_vars = {"g_counter"}
        defs = [_def("obj_a", "procA", "g_counter", 1)]
        uses = [_use("obj_b", "procB", "g_counter", 2)]
        procs = [_proc("obj_a", "procA"), _proc("obj_b", "procB")]
        gdf = build_interproc_flow([], defs, uses, global_vars, procs)
        gw = _edges_of_kind(gdf, "global_write")
        assert len(gw) == 1
        e = gw[0]
        assert e.caller_object == "obj_a"
        assert e.callee_object == "obj_b"
        assert e.var_name == "g_counter"
        assert e.caller_context == "g_counter"
        assert e.callee_context == "g_counter"

    def test_same_proc_no_self_edge(self):
        """A procedure writing and reading the same global does not produce a self-edge."""
        global_vars = {"g_flag"}
        defs = [_def("obj_a", "procA", "g_flag", 1)]
        uses = [_use("obj_a", "procA", "g_flag", 2)]
        procs = [_proc("obj_a", "procA")]
        gdf = build_interproc_flow([], defs, uses, global_vars, procs)
        assert _edges_of_kind(gdf, "global_write") == []

    def test_local_var_not_treated_as_global(self):
        """Variables not in global_var_names produce no global edges."""
        defs = [_def("obj_a", "procA", "local_x", 1)]
        uses = [_use("obj_b", "procB", "local_x", 2)]
        procs = [_proc("obj_a", "procA"), _proc("obj_b", "procB")]
        gdf = build_interproc_flow([], defs, uses, set(), procs)
        assert gdf.edges == []

    def test_multiple_readers_of_global(self):
        """One writer and two readers produce two global_write edges."""
        global_vars = {"g_total"}
        defs = [_def("ow", "writer", "g_total", 1)]
        uses = [
            _use("or1", "reader1", "g_total", 2),
            _use("or2", "reader2", "g_total", 3),
        ]
        procs = [_proc("ow", "writer"), _proc("or1", "reader1"), _proc("or2", "reader2")]
        gdf = build_interproc_flow([], defs, uses, global_vars, procs)
        gw = _edges_of_kind(gdf, "global_write")
        assert len(gw) == 2
        callees = {e.callee_object for e in gw}
        assert callees == {"or1", "or2"}


# --- build_interproc_flow: mutual recursion ----------------------------------


class TestRecursion:
    def test_mutual_recursion_no_crash(self):
        """A→B and B→A call cycle does not cause errors or infinite loops."""
        rc = [
            _rc("oa", "procA", "procB", "ob", "procB", call_line=1),
            _rc("ob", "procB", "procA", "oa", "procA", call_line=2),
        ]
        uses = [
            _use("oa", "procA", "x", 1),
            _use("ob", "procB", "y", 2),
        ]
        procs = [
            _proc("oa", "procA", "integer p"),
            _proc("ob", "procB", "integer q"),
        ]
        gdf = build_interproc_flow(rc, [], uses, set(), procs)
        # Two arg edges: x→p (A→B) and y→q (B→A)
        arg_edges = _edges_of_kind(gdf, "arg")
        assert len(arg_edges) == 2


# --- procedure_summaries -----------------------------------------------------


class TestProcSummaries:
    def test_params_in_populated(self):
        """Procedure summary captures parameter names."""
        procs = [_proc("obj", "proc1", "integer x, string y")]
        gdf = build_interproc_flow([], [], [], set(), procs)
        s = next(s for s in gdf.summaries if s.proc_name == "proc1")
        assert s.params_in == ["x", "y"]

    def test_globals_read_written(self):
        """Summary reflects which global vars each proc reads and writes."""
        global_vars = {"g_a", "g_b"}
        defs = [_def("obj", "proc1", "g_a", 1)]
        uses = [_use("obj", "proc1", "g_b", 2)]
        procs = [_proc("obj", "proc1")]
        gdf = build_interproc_flow([], defs, uses, global_vars, procs)
        s = next(s for s in gdf.summaries if s.proc_name == "proc1")
        assert s.globals_written == ["g_a"]
        assert s.globals_read == ["g_b"]

    def test_return_flows_to_populated(self):
        """Summary records which callers receive this procedure's return value."""
        rc = [_rc("oa", "procA", "procB", "ob", "procB", call_line=5)]
        defs = [_def("oa", "procA", "res", 5, "assign")]
        procs = [_proc("oa", "procA"), _proc("ob", "procB", return_type="integer")]
        gdf = build_interproc_flow(rc, defs, [], set(), procs)
        s = next(s for s in gdf.summaries if s.proc_name == "procB")
        assert len(s.return_flows_to) == 1
        assert s.return_flows_to[0] == {"object": "oa", "proc": "procA", "lhs_var": "res"}
