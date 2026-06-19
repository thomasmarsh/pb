"""Tests for taint analysis (core/taint.py)."""

from pb_cli.core.taint import (
    TaintAnalysis,
    TaintPath,
    TaintSink,
    TaintSource,
    TaintStep,
    classify_sinks,
    classify_sources,
    propagate_taint,
    taint_analysis,
    trace_taint_path,
)


# --- Helpers -----------------------------------------------------------------


def _sql(
    obj: str,
    proc: str,
    line: int,
    op: str,
    raw_sql: str,
    has_into: bool = False,
    file: str = "w.srf",
) -> dict:
    return {
        "file": file,
        "object": obj,
        "proc_name": proc,
        "line": line,
        "operation": op,
        "raw_sql": raw_sql,
        "has_into": has_into,
    }


def _proc(
    obj: str,
    name: str,
    proc_type: str = "function",
    params: str = "",
    start_line: int = 1,
    file: str = "w.srf",
) -> dict:
    return {
        "file": file,
        "object": obj,
        "name": name,
        "proc_type": proc_type,
        "params": params,
        "start_line": start_line,
    }


def _def(
    obj: str,
    proc: str,
    var: str,
    line: int,
    kind: str = "assign",
    block_id: str = "b0",
    file: str = "w.srf",
) -> dict:
    return {
        "file": file,
        "object": obj,
        "proc_name": proc,
        "var_name": var,
        "line": line,
        "kind": kind,
        "block_id": block_id,
        "stmt_index": 0,
    }


def _use(
    obj: str,
    proc: str,
    var: str,
    line: int,
    kind: str = "rhs",
    block_id: str = "b0",
    file: str = "w.srf",
) -> dict:
    return {
        "file": file,
        "object": obj,
        "proc_name": proc,
        "var_name": var,
        "line": line,
        "kind": kind,
        "block_id": block_id,
        "stmt_index": 0,
    }


def _edge(
    caller_obj: str,
    caller_proc: str,
    callee_obj: str,
    callee_proc: str,
    kind: str,
    var: str,
    caller_ctx: str,
    callee_ctx: str,
    caller_line: int | None = None,
) -> dict:
    return {
        "caller_object": caller_obj,
        "caller_proc": caller_proc,
        "caller_line": caller_line,
        "callee_object": callee_obj,
        "callee_proc": callee_proc,
        "edge_kind": kind,
        "var_name": var,
        "caller_context": caller_ctx,
        "callee_context": callee_ctx,
    }


# --- TestClassifySources -----------------------------------------------------


class TestClassifySources:
    def test_db_read_single_into_var(self):
        stmts = [_sql("oa", "pA", 5, "SELECT", "SELECT col INTO :ls_result FROM tbl", has_into=True)]
        sources = classify_sources(stmts, [])
        assert len(sources) == 1
        s = sources[0]
        assert s.var_name == "ls_result"
        assert s.object == "oa"
        assert s.proc_name == "pA"
        assert s.line == 5
        assert s.source_type == "db_read"

    def test_db_read_multiple_into_vars(self):
        stmts = [_sql("oa", "pA", 10, "SELECT", "SELECT a, b INTO :ls_a, :ls_b FROM tbl", has_into=True)]
        sources = classify_sources(stmts, [])
        var_names = {s.var_name for s in sources}
        assert var_names == {"ls_a", "ls_b"}
        assert all(s.source_type == "db_read" for s in sources)

    def test_select_without_into_no_source(self):
        stmts = [_sql("oa", "pA", 5, "SELECT", "SELECT col FROM tbl", has_into=False)]
        assert classify_sources(stmts, []) == []

    def test_event_handler_param(self):
        procs = [_proc("oa", "pA", proc_type="event", params="string as_arg", start_line=3)]
        sources = classify_sources([], procs)
        assert len(sources) == 1
        s = sources[0]
        assert s.var_name == "as_arg"
        assert s.object == "oa"
        assert s.proc_name == "pA"
        assert s.source_type == "request_param"

    def test_on_block_param(self):
        procs = [_proc("oa", "pA", proc_type="on", params="integer ai_row", start_line=1)]
        sources = classify_sources([], procs)
        assert len(sources) == 1
        assert sources[0].source_type == "request_param"
        assert sources[0].var_name == "ai_row"

    def test_non_event_proc_no_source(self):
        procs = [_proc("oa", "pA", proc_type="function", params="string as_name")]
        assert classify_sources([], procs) == []


# --- TestClassifySinks -------------------------------------------------------


class TestClassifySinks:
    def test_insert_stmt_is_sink(self):
        stmts = [_sql("oa", "pA", 15, "INSERT", "INSERT INTO tbl (col) VALUES (:ls_val)")]
        sinks = classify_sinks(stmts)
        assert len(sinks) == 1
        sk = sinks[0]
        assert sk.var_name == "ls_val"
        assert sk.object == "oa"
        assert sk.proc_name == "pA"
        assert sk.line == 15
        assert sk.sink_type == "db_write"
        assert sk.severity == "high"

    def test_update_stmt_is_sink(self):
        stmts = [_sql("oa", "pA", 20, "UPDATE", "UPDATE tbl SET col = :ls_new WHERE id = :ls_id")]
        sinks = classify_sinks(stmts)
        assert len(sinks) == 2
        assert all(sk.sink_type == "db_write" for sk in sinks)
        assert {sk.var_name for sk in sinks} == {"ls_new", "ls_id"}

    def test_delete_stmt_is_sink(self):
        stmts = [_sql("oa", "pA", 25, "DELETE", "DELETE FROM tbl WHERE id = :ls_key")]
        sinks = classify_sinks(stmts)
        assert len(sinks) == 1
        assert sinks[0].sink_type == "db_write"
        assert sinks[0].severity == "high"
        assert sinks[0].var_name == "ls_key"

    def test_execute_is_critical_sink(self):
        stmts = [_sql("oa", "pA", 30, "EXECUTE", "EXECUTE IMMEDIATE :ls_sql")]
        sinks = classify_sinks(stmts)
        assert len(sinks) == 1
        sk = sinks[0]
        assert sk.sink_type == "exec_immediate"
        assert sk.severity == "critical"
        assert sk.var_name == "ls_sql"

    def test_select_no_sink(self):
        stmts = [_sql("oa", "pA", 5, "SELECT", "SELECT col INTO :ls_x FROM tbl", has_into=True)]
        assert classify_sinks(stmts) == []


# --- TestPropagateTaint ------------------------------------------------------


class TestPropagateTaint:
    def _source(self, obj: str, proc: str, var: str) -> TaintSource:
        return TaintSource(file="w.srf", var_name=var, object=obj, proc_name=proc, line=1, source_type="db_read")

    def test_intra_proc_assignment(self):
        """Tainted ls_a used on same line as ls_b is defined → ls_b tainted."""
        sources = [self._source("oa", "pA", "ls_a")]
        defs = [_def("oa", "pA", "ls_b", line=5)]
        uses = [_use("oa", "pA", "ls_a", line=5)]
        tainted, _ = propagate_taint(sources, defs, uses, [])
        assert ("oa", "pA", "ls_a") in tainted
        assert ("oa", "pA", "ls_b") in tainted

    def test_arg_edge_propagation(self):
        """Arg edge: tainted caller var x → callee param p1 tainted."""
        sources = [self._source("oa", "pA", "x")]
        e = _edge("oa", "pA", "ob", "pB", "arg", "x", "x", "p1")
        tainted, _ = propagate_taint(sources, [], [], [e])
        assert ("ob", "pB", "p1") in tainted

    def test_return_edge_propagation(self):
        """Tainted var returned from callee → caller lhs tainted."""
        sources = [self._source("ob", "pB", "ls_val")]
        ret_use = _use("ob", "pB", "ls_val", line=10, kind="return")
        e = _edge("oa", "pA", "ob", "pB", "return", "result", "result", "return")
        tainted, _ = propagate_taint(sources, [], [ret_use], [e])
        assert ("oa", "pA", "result") in tainted

    def test_global_write_propagation(self):
        """Tainted global written in A propagates to reader in B."""
        sources = [self._source("oa", "pA", "g_val")]
        e = _edge("oa", "pA", "ob", "pB", "global_write", "g_val", "g_val", "g_val")
        tainted, _ = propagate_taint(sources, [], [], [e])
        assert ("ob", "pB", "g_val") in tainted

    def test_no_propagation_without_connection(self):
        """Tainted var in oa/pA does not infect unrelated var in ob/pB."""
        sources = [self._source("oa", "pA", "ls_x")]
        tainted, _ = propagate_taint(sources, [], [], [])
        assert ("ob", "pB", "ls_x") not in tainted


# --- TestTaintAnalysis -------------------------------------------------------


class TestTaintAnalysis:
    def test_db_read_to_insert(self):
        """Same var tainted by SELECT INTO then used in INSERT → one path."""
        stmts = [
            _sql("oa", "pA", 5, "SELECT", "SELECT col INTO :ls_val FROM tbl", has_into=True),
            _sql("oa", "pA", 10, "INSERT", "INSERT INTO other (col) VALUES (:ls_val)"),
        ]
        result = taint_analysis([], [], [], stmts, [])
        assert len(result.sources) >= 1
        assert len(result.sinks) >= 1
        assert len(result.paths) == 1
        p = result.paths[0]
        assert p.source.var_name == "ls_val"
        assert p.sink.var_name == "ls_val"
        assert p.severity == "high"
        assert p.category == "sql_injection"

    def test_event_param_to_db_write(self):
        """Event handler param directly used in INSERT → one path."""
        procs = [_proc("oa", "pA", proc_type="event", params="string as_key")]
        stmts = [_sql("oa", "pA", 8, "INSERT", "INSERT INTO tbl VALUES (:as_key)")]
        result = taint_analysis([], [], [], stmts, procs)
        assert len(result.paths) == 1
        p = result.paths[0]
        assert p.source.source_type == "request_param"
        assert p.sink.sink_type == "db_write"

    def test_interproc_taint(self):
        """Taint flows from caller via arg edge to callee's INSERT."""
        stmts = [
            _sql("oa", "pA", 5, "SELECT", "SELECT x INTO :ls_x FROM t", has_into=True),
            _sql("ob", "pB", 20, "INSERT", "INSERT INTO t VALUES (:p1)"),
        ]
        edges = [_edge("oa", "pA", "ob", "pB", "arg", "ls_x", "ls_x", "p1")]
        result = taint_analysis(edges, [], [], stmts, [])
        assert len(result.paths) == 1
        p = result.paths[0]
        assert p.source.object == "oa"
        assert p.sink.object == "ob"

    def test_global_taint_path(self):
        """Tainted global propagates to reader proc that has INSERT — cross-object path."""
        stmts = [
            _sql("oa", "pA", 5, "SELECT", "SELECT v INTO :g_val FROM t", has_into=True),
            _sql("ob", "pB", 30, "INSERT", "INSERT INTO log VALUES (:g_val)"),
        ]
        edges = [_edge("oa", "pA", "ob", "pB", "global_write", "g_val", "g_val", "g_val")]
        result = taint_analysis(edges, [], [], stmts, [])
        assert len(result.paths) == 1
        p = result.paths[0]
        # Source and sink are in different objects — global propagation crossed the boundary
        assert p.source.object == "oa"
        assert p.sink.object == "ob"

    def test_no_taint_clean_code(self):
        """No sources, no sinks → empty analysis."""
        result = taint_analysis([], [], [], [], [])
        assert result.sources == []
        assert result.sinks == []
        assert result.paths == []

    def test_multiple_sources_one_sink_each(self):
        """Two independent source-sink pairs produce two paths."""
        stmts = [
            _sql("oa", "pA", 5, "SELECT", "SELECT x INTO :ls_x FROM t", has_into=True, file="a.srf"),
            _sql("oa", "pA", 10, "INSERT", "INSERT INTO t VALUES (:ls_x)", file="a.srf"),
            _sql("ob", "pB", 5, "SELECT", "SELECT y INTO :ls_y FROM t", has_into=True, file="b.srf"),
            _sql("ob", "pB", 10, "INSERT", "INSERT INTO t VALUES (:ls_y)", file="b.srf"),
        ]
        result = taint_analysis([], [], [], stmts, [])
        assert len(result.paths) == 2
