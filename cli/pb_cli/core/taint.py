"""Context-insensitive taint analysis over the P3 data flow model.

Pure module — no I/O, no DuckDB.

Sources:  DB reads (SELECT INTO host vars), event/on handler parameters.
Sinks:    DB writes (INSERT/UPDATE/DELETE), EXECUTE IMMEDIATE.
Propagation: forward BFS through intra-proc use→def chains and interproc_edges.
Paths:    provenance-based back-trace from sink to source.

Public API:
    classify_sources(sql_stmts, procedures) -> list[TaintSource]
    classify_sinks(sql_stmts) -> list[TaintSink]
    propagate_taint(sources, proc_defs, proc_uses, interproc_edges)
        -> (tainted, provenance)
    trace_taint_path(source, sink, provenance) -> list[TaintStep]
    build_taint_annotations(tainted, sources, sinks, proc_defs, proc_uses)
        -> list[dict]
    taint_analysis(interproc_edges, proc_defs, proc_uses, sql_stmts, procedures)
        -> TaintAnalysis
"""

from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass

from pb_cli.core.type_resolution import parse_params

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

_HOSTVAR_RE = re.compile(r":([A-Za-z_]\w*)")
_INTO_FRAG_RE = re.compile(r"\bINTO\b(.*?)(?:\bFROM\b|\Z)", re.IGNORECASE | re.DOTALL)

_WRITE_OPS = frozenset({"INSERT", "UPDATE", "DELETE"})
_EXEC_OPS = frozenset({"EXECUTE"})
_EVENT_PROC_TYPES = frozenset({"event", "on"})

_SEVERITY: dict[str, str] = {
    "db_write": "high",
    "exec_immediate": "critical",
}
_CATEGORY: dict[str, str] = {
    "db_write": "sql_injection",
    "exec_immediate": "exec_immediate",
}


@dataclass
class TaintSource:
    file: str
    var_name: str
    object: str
    proc_name: str
    line: int | None
    source_type: str  # 'db_read' | 'request_param'


@dataclass
class TaintSink:
    file: str
    var_name: str
    object: str
    proc_name: str
    line: int | None
    sink_type: str   # 'db_write' | 'exec_immediate'
    severity: str    # 'critical' | 'high'


@dataclass
class TaintStep:
    object: str
    proc_name: str
    line: int | None
    var_name: str
    step_kind: str   # 'source' | 'def' | 'arg' | 'return' | 'global' | 'sink'
    description: str


@dataclass
class TaintPath:
    source: TaintSource
    sink: TaintSink
    steps: list[TaintStep]
    severity: str
    category: str


@dataclass
class TaintAnalysis:
    sources: list[TaintSource]
    sinks: list[TaintSink]
    paths: list[TaintPath]
    tainted_vars: dict[str, set[tuple[str, str]]]  # var → {(object, proc)}


# ---------------------------------------------------------------------------
# Source classification
# ---------------------------------------------------------------------------

def _extract_into_vars(raw_sql: str) -> list[str]:
    """Extract :identifier names from the INTO clause of a SELECT statement."""
    m = _INTO_FRAG_RE.search(raw_sql)
    if not m:
        return []
    return _HOSTVAR_RE.findall(m.group(1))


def classify_sources(
    sql_stmts: list[dict],
    procedures: list[dict],
) -> list[TaintSource]:
    """Identify taint sources from sql_statements (DB reads) and event handler params."""
    sources: list[TaintSource] = []

    for s in sql_stmts:
        if not s.get("has_into"):
            continue
        raw_sql = s.get("raw_sql") or ""
        for var in _extract_into_vars(raw_sql):
            sources.append(TaintSource(
                file=s.get("file", ""),
                var_name=var,
                object=s.get("object", ""),
                proc_name=s.get("proc_name", ""),
                line=s.get("line"),
                source_type="db_read",
            ))

    for p in procedures:
        if p.get("proc_type") not in _EVENT_PROC_TYPES:
            continue
        params_text = p.get("params") or ""
        if not params_text.strip():
            continue
        for param_name, _ in parse_params(params_text):
            if param_name:
                sources.append(TaintSource(
                    file=p.get("file", ""),
                    var_name=param_name,
                    object=p.get("object", ""),
                    proc_name=p.get("name", ""),
                    line=p.get("start_line"),
                    source_type="request_param",
                ))

    return sources


# ---------------------------------------------------------------------------
# Sink classification
# ---------------------------------------------------------------------------

def _extract_bind_vars(raw_sql: str) -> list[str]:
    """Extract :identifier bind variable names from a SQL statement."""
    return _HOSTVAR_RE.findall(raw_sql)


def classify_sinks(
    sql_stmts: list[dict],
) -> list[TaintSink]:
    """Identify taint sinks from sql_statements write/execute operations."""
    sinks: list[TaintSink] = []

    for s in sql_stmts:
        op = (s.get("operation") or "").upper()
        if op not in _WRITE_OPS and op not in _EXEC_OPS:
            continue

        raw_sql = s.get("raw_sql") or ""
        sink_type = "exec_immediate" if op in _EXEC_OPS else "db_write"
        severity = _SEVERITY[sink_type]
        vars_in_sql = _extract_bind_vars(raw_sql)

        if vars_in_sql:
            for var in vars_in_sql:
                sinks.append(TaintSink(
                    file=s.get("file", ""),
                    var_name=var,
                    object=s.get("object", ""),
                    proc_name=s.get("proc_name", ""),
                    line=s.get("line"),
                    sink_type=sink_type,
                    severity=severity,
                ))
        else:
            # No bind vars in SQL — still a potential sink (bare EXECUTE, etc.)
            sinks.append(TaintSink(
                file=s.get("file", ""),
                var_name="*exec",
                object=s.get("object", ""),
                proc_name=s.get("proc_name", ""),
                line=s.get("line"),
                sink_type=sink_type,
                severity=severity,
            ))

    return sinks


# ---------------------------------------------------------------------------
# Taint propagation
# ---------------------------------------------------------------------------

# Provenance tuple: (pred_obj, pred_proc, pred_var, step_kind, description)
_Provenance = dict[tuple[str, str, str], tuple[str, str, str | None, str, str]]

# Tainted triple: (object, proc_name, var_name)
_Triple = tuple[str, str, str]


def propagate_taint(
    sources: list[TaintSource],
    proc_defs: list[dict],
    proc_uses: list[dict],
    interproc_edges: list[dict],
) -> tuple[set[_Triple], _Provenance]:
    """Forward BFS taint propagation.

    Returns:
        tainted:    set of (object, proc_name, var_name) triples
        provenance: maps each tainted triple → (pred_obj, pred_proc, pred_var | None,
                    step_kind, description) for path reconstruction.
    """
    # Fast lookup: for each (obj, proc, var), which lines is it used on?
    uses_by_triple: dict[_Triple, list[dict]] = {}
    for u in proc_uses:
        k = (u["object"], u["proc_name"], u["var_name"])
        uses_by_triple.setdefault(k, []).append(u)

    # For each (obj, proc, line), which vars are defined?
    defs_by_line: dict[tuple[str, str, int], list[str]] = {}
    for d in proc_defs:
        line = d.get("line")
        if line is not None:
            k = (d["object"], d["proc_name"], line)
            defs_by_line.setdefault(k, []).append(d["var_name"])

    # Index interproc edges by caller side and callee side
    arg_edges_by_caller: dict[tuple[str, str, str], list[dict]] = {}
    return_edges: list[dict] = []
    global_write_edges: dict[tuple[str, str, str], list[dict]] = {}

    for e in interproc_edges:
        kind = e.get("edge_kind", "")
        if kind == "arg":
            k = (e["caller_object"], e["caller_proc"], e["caller_context"])
            arg_edges_by_caller.setdefault(k, []).append(e)
        elif kind == "return":
            return_edges.append(e)
        elif kind == "global_write":
            k = (e["caller_object"], e["caller_proc"], e["var_name"])
            global_write_edges.setdefault(k, []).append(e)

    # Return-edge index: for each callee, which edges flow back to callers?
    return_edges_by_callee: dict[tuple[str, str], list[dict]] = {}
    for e in return_edges:
        k = (e["callee_object"], e["callee_proc"])
        return_edges_by_callee.setdefault(k, []).append(e)

    tainted: set[_Triple] = set()
    provenance: _Provenance = {}
    worklist: deque[_Triple] = deque()

    def _seed(obj: str, proc: str, var: str, step_kind: str, desc: str,
              pred: tuple[str, str, str | None] | None = None) -> None:
        t = (obj, proc, var)
        if t not in tainted:
            tainted.add(t)
            pred_obj, pred_proc, pred_var = pred if pred else (obj, proc, None)
            provenance[t] = (pred_obj, pred_proc, pred_var, step_kind, desc)
            worklist.append(t)

    # Seed from sources
    for src in sources:
        _seed(src.object, src.proc_name, src.var_name, "source",
              f"taint source: {src.source_type}")

    # BFS propagation
    while worklist:
        obj, proc, var = worklist.popleft()

        # 1. Intra-proc: if tainted var is used on a line that also has a def → def is tainted
        for u in uses_by_triple.get((obj, proc, var), []):
            line = u.get("line")
            if line is None:
                continue
            for new_var in defs_by_line.get((obj, proc, line), []):
                if new_var != var:
                    _seed(obj, proc, new_var, "def",
                          f"{var} used in expression that defines {new_var}",
                          pred=(obj, proc, var))

        # 2. Arg edges: tainted caller_context → callee_context
        for e in arg_edges_by_caller.get((obj, proc, var), []):
            _seed(e["callee_object"], e["callee_proc"], e["callee_context"],
                  "arg",
                  f"passed as argument from {obj}.{proc}",
                  pred=(obj, proc, var))

        # 3. Return edges: if tainted var is returned in callee → caller lhs tainted
        callee_key = (obj, proc)
        for u in uses_by_triple.get((obj, proc, var), []):
            if u.get("kind") != "return":
                continue
            for e in return_edges_by_callee.get(callee_key, []):
                _seed(e["caller_object"], e["caller_proc"], e["caller_context"],
                      "return",
                      f"return value of {obj}.{proc} received by caller",
                      pred=(obj, proc, var))

        # 4. Global write edges: tainted global propagates to readers
        for e in global_write_edges.get((obj, proc, var), []):
            _seed(e["callee_object"], e["callee_proc"], e["callee_context"],
                  "global",
                  f"global variable {var} written in {obj}.{proc}",
                  pred=(obj, proc, var))

    return tainted, provenance


# ---------------------------------------------------------------------------
# Path reconstruction
# ---------------------------------------------------------------------------

def trace_taint_path(
    source: TaintSource,
    sink: TaintSink,
    provenance: _Provenance,
) -> list[TaintStep]:
    """Reconstruct the taint path from source to sink using provenance.

    Walks provenance backwards from the sink triple until the source triple or
    a root node is reached. Returns the ordered step list (source → sink).
    Returns an empty list if the path cannot be traced (unreachable).
    """
    sink_triple: _Triple = (sink.object, sink.proc_name, sink.var_name)
    source_triple: _Triple = (source.object, source.proc_name, source.var_name)

    if sink_triple not in provenance and sink_triple != source_triple:
        return []

    # Walk back from sink to source through provenance chain
    chain: list[_Triple] = []
    current = sink_triple
    seen: set[_Triple] = set()
    max_steps = 50

    while current != source_triple and len(chain) < max_steps:
        if current in seen:
            break
        seen.add(current)
        chain.append(current)
        prov = provenance.get(current)
        if prov is None:
            break
        pred_obj, pred_proc, pred_var, _, _ = prov
        if pred_var is None:
            break
        current = (pred_obj, pred_proc, pred_var)

    if current == source_triple:
        chain.append(source_triple)

    chain.reverse()

    steps: list[TaintStep] = []
    for i, triple in enumerate(chain):
        obj, proc, var = triple
        if triple == source_triple:
            step_kind = "source"
            desc = f"taint source: {source.source_type}"
        elif triple == sink_triple:
            step_kind = "sink"
            desc = f"taint sink: {sink.sink_type}"
        else:
            prov = provenance.get(triple)
            step_kind = prov[3] if prov else "def"
            desc = prov[4] if prov else f"tainted variable {var}"

        steps.append(TaintStep(
            object=obj,
            proc_name=proc,
            line=None,
            var_name=var,
            step_kind=step_kind,
            description=desc,
        ))

    return steps


# ---------------------------------------------------------------------------
# Taint annotations
# ---------------------------------------------------------------------------

def build_taint_annotations(
    tainted: set[_Triple],
    sources: list[TaintSource],
    sinks: list[TaintSink],
    proc_defs: list[dict],
    proc_uses: list[dict],
) -> list[dict]:
    """Build per-block annotation rows for the taint_annotations table."""
    # Source/sink locations by (object, proc_name, var_name)
    source_vars: set[_Triple] = {(s.object, s.proc_name, s.var_name) for s in sources}
    sink_vars: set[_Triple] = {(sk.object, sk.proc_name, sk.var_name) for sk in sinks}

    # Collect tainted vars per block
    block_tainted: dict[tuple[str, str, str, str], set[str]] = {}  # (file, obj, proc, block_id) → vars

    for rows in (proc_defs, proc_uses):
        for r in rows:
            triple = (r["object"], r["proc_name"], r["var_name"])
            if triple not in tainted:
                continue
            key = (r.get("file", ""), r["object"], r["proc_name"], r["block_id"])
            block_tainted.setdefault(key, set()).add(r["var_name"])

    annotations = []
    for (file, obj, proc, block_id), tvars in block_tainted.items():
        is_entry = any((obj, proc, v) in source_vars for v in tvars)
        is_sink = any((obj, proc, v) in sink_vars for v in tvars)
        annotations.append({
            "file": file,
            "object": obj,
            "proc_name": proc,
            "block_id": block_id,
            "is_taint_entry": is_entry,
            "is_taint_sink": is_sink,
            "tainted_vars": sorted(tvars),
        })

    return annotations


# ---------------------------------------------------------------------------
# Full pipeline
# ---------------------------------------------------------------------------

def taint_analysis(
    interproc_edges: list[dict],
    proc_defs: list[dict],
    proc_uses: list[dict],
    sql_stmts: list[dict],
    procedures: list[dict],
) -> TaintAnalysis:
    """Full taint analysis: classify sources/sinks → propagate → trace paths."""
    sources = classify_sources(sql_stmts, procedures)
    sinks = classify_sinks(sql_stmts)

    if not sources or not sinks:
        tainted_vars: dict[str, set[tuple[str, str]]] = {}
        return TaintAnalysis(sources=sources, sinks=sinks, paths=[], tainted_vars=tainted_vars)

    tainted, provenance = propagate_taint(sources, proc_defs, proc_uses, interproc_edges)

    # Build tainted_vars summary: var_name → {(object, proc)} where tainted
    tainted_vars = {}
    for obj, proc, var in tainted:
        tainted_vars.setdefault(var, set()).add((obj, proc))

    # Build taint paths: for each (source, sink) where sink triple is tainted
    # and provenance traces back to that source
    paths: list[TaintPath] = []

    # Index sources by triple for fast lookup during back-trace
    source_by_triple: dict[_Triple, TaintSource] = {
        (s.object, s.proc_name, s.var_name): s for s in sources
    }

    for sink in sinks:
        sink_triple: _Triple = (sink.object, sink.proc_name, sink.var_name)
        if sink_triple not in tainted:
            continue

        # Find which source this sink triple traces back to
        src = _find_source_via_provenance(sink_triple, provenance, source_by_triple)
        if src is None:
            continue

        steps = trace_taint_path(src, sink, provenance)
        severity = sink.severity
        category = _CATEGORY.get(sink.sink_type, "general")

        paths.append(TaintPath(
            source=src,
            sink=sink,
            steps=steps,
            severity=severity,
            category=category,
        ))

    return TaintAnalysis(sources=sources, sinks=sinks, paths=paths, tainted_vars=tainted_vars)


def _find_source_via_provenance(
    triple: _Triple,
    provenance: _Provenance,
    source_by_triple: dict[_Triple, TaintSource],
) -> TaintSource | None:
    """Walk provenance back from triple to find the originating TaintSource."""
    current = triple
    seen: set[_Triple] = set()
    max_steps = 50

    while len(seen) < max_steps:
        if current in source_by_triple:
            return source_by_triple[current]
        if current in seen:
            return None
        seen.add(current)
        prov = provenance.get(current)
        if prov is None:
            return None
        pred_obj, pred_proc, pred_var, _, _ = prov
        if pred_var is None:
            # Root node — check if it's a source itself
            root = (pred_obj, pred_proc, current[2])
            return source_by_triple.get(root)
        current = (pred_obj, pred_proc, pred_var)

    return None
