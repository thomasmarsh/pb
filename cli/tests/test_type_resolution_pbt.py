"""Property-based tests for type resolution — Hypothesis.

Invariants tested:
  1. Conservation: output length is deterministic given inputs
  2. Partition: resolved_kind / resolution_kind cover a fixed enum
  3. Well-formedness: kind→target invariants (static→target_object set, builtin→confidence high, etc.)
  4. Determinism: classify_type is pure — same input → same output
  5. parse_params total: never crashes; every output (name, type) is non-empty
"""

from __future__ import annotations

import string

from hypothesis import given, settings
from hypothesis import strategies as st

from pb_cli.core.models import CallRow, LocalVarRow, ProcedureRow
from pb_cli.core.type_resolution import (
    PB_BUILTINS,
    PRIMITIVES,
    classify_type,
    parse_params,
    resolve_calls,
    resolve_types,
)

# ── Strategies ────────────────────────────────────────────────────────────────

_identifier = st.text(
    alphabet=string.ascii_lowercase + string.digits + "_",
    min_size=1,
    max_size=20,
).filter(lambda s: not s[0].isdigit())

_pb_type = st.sampled_from([
    "string", "integer", "long", "boolean", "double", "decimal",
    "date", "time", "datetime", "any", "blob", "char",
    "datawindow", "datastore", "window", "pointer",
])

_modifier = st.sampled_from(["ref", "readonly", ""])

_param_text = st.lists(
    st.tuples(_modifier, _pb_type, _identifier),
    min_size=0,
    max_size=5,
).map(
    lambda parts: ", ".join(
        f"{m} {t} {n}".strip() for m, t, n in parts if t
    )
)


def _make_local_var(file="f.srw", obj="w_test", proc="of_init"):
    return st.tuples(
        st.just(file), st.just(obj), st.just(proc),
        _identifier, _pb_type, st.integers(min_value=1, max_value=1000),
    ).map(lambda t: LocalVarRow(*t))


def _make_proc(file="f.srw", obj="w_test"):
    return st.tuples(
        st.just(file), st.just(obj),
        st.sampled_from(["function", "subroutine", "event"]),
        _identifier,
        st.none() | st.just("public"),
        _param_text,
        st.none() | _pb_type,
        st.just(1), st.just(10),
        st.just("[]"), st.just(""), st.just(1),
    ).map(lambda t: ProcedureRow(*t))


def _make_call(file="f.srw", obj="w_test", proc="of_init"):
    callee = st.one_of(
        st.just("fn_sqlerror"),
        st.just("isnull"),
        st.just("retrieve"),
        st.tuples(_identifier, _identifier).map(lambda t: f"{t[0]}.{t[1]}"),
        _identifier,
    )
    return st.tuples(
        st.just(file), st.just(obj), st.just(proc),
        callee,
        st.sampled_from(["ExCall", "ExMethodCall", "ExDispatch"]),
    ).map(lambda t: CallRow(*t))


# ── parse_params properties ──────────────────────────────────────────────────

RESOLVED_KINDS = {"primitive", "object", "user_type", "any", "unresolved"}
RESOLUTION_KINDS = {"static", "virtual", "inherited", "builtin", "unresolved"}
CONFIDENCES = {"high", "medium", "low"}


@given(params_text=st.text(min_size=0, max_size=200))
@settings(max_examples=500)
def test_parse_params_total(params_text):
    """parse_params never crashes on any input."""
    result = parse_params(params_text)
    assert isinstance(result, list)
    for name, ptype in result:
        assert name, "param name must be non-empty"
        assert ptype, "param type must be non-empty"


@given(params_text=_param_text)
@settings(max_examples=500)
def test_parse_params_well_formed(params_text):
    """Well-formed param strings produce valid (name, type) pairs."""
    result = parse_params(params_text)
    for name, ptype in result:
        assert name.isidentifier() or "_" in name
        assert ptype


@given(var_type=st.text(min_size=0, max_size=50))
@settings(max_examples=500)
def test_classify_type_total(var_type):
    """classify_type never crashes and always returns a valid kind."""
    kind, target = classify_type(var_type, set(), set())
    assert kind in RESOLVED_KINDS
    if kind == "object":
        assert target is not None
    elif kind == "user_type":
        assert target is not None
    else:
        assert target is None


@given(var_type=st.text(min_size=1, max_size=50))
@settings(max_examples=500)
def test_classify_type_deterministic(var_type):
    """classify_type is pure — same input always yields same output."""
    a = classify_type(var_type, {"w_main"}, {"uo_grid"})
    b = classify_type(var_type, {"w_main"}, {"uo_grid"})
    assert a == b


@given(var_type=_pb_type)
@settings(max_examples=200)
def test_classify_type_primitives_never_unresolved(var_type):
    """Known PB types (primitives + builtins) never resolve to 'unresolved'."""
    kind, _ = classify_type(var_type, set(), set())
    assert kind != "unresolved", f"{var_type!r} should not be unresolved"


@given(
    var_type=st.text(
        alphabet=string.ascii_lowercase + "_",
        min_size=3, max_size=30,
    ).filter(lambda s: s not in PRIMITIVES and s not in PB_BUILTINS and s != "any"),
)
@settings(max_examples=200)
def test_classify_type_unknown_is_unresolved(var_type):
    """Types not in primitives/builtins/objects/user_types resolve to unresolved."""
    kind, target = classify_type(var_type, set(), set())
    assert kind == "unresolved"
    assert target is None


# ── resolve_types properties ──────────────────────────────────────────────────

@given(
    local_vars=st.lists(_make_local_var(), max_size=20),
    procs=st.lists(_make_proc(), max_size=10),
)
@settings(max_examples=300)
def test_resolve_types_conservation(local_vars, procs):
    """Output length equals local_vars + sum(parsed params)."""
    result = resolve_types(local_vars, procs, set(), set())
    expected_params = sum(
        len(parse_params(p.params)) for p in procs if p.params
    )
    assert len(result) == len(local_vars) + expected_params


@given(
    local_vars=st.lists(_make_local_var(), max_size=20),
    procs=st.lists(_make_proc(), max_size=10),
)
@settings(max_examples=300)
def test_resolve_types_partition(local_vars, procs):
    """Every resolved kind belongs to the fixed partition."""
    result = resolve_types(local_vars, procs, set(), set())
    for row in result:
        assert row.resolved_kind in RESOLVED_KINDS
        if row.resolved_kind == "object":
            assert row.resolved_target is not None
        elif row.resolved_kind == "user_type":
            assert row.resolved_target is not None


@given(
    local_vars=st.lists(_make_local_var(), max_size=20),
    procs=st.lists(_make_proc(), max_size=10),
)
@settings(max_examples=200)
def test_resolve_types_param_flag(local_vars, procs):
    """is_parameter=True iff the row came from a procedure param, not a local var."""
    result = resolve_types(local_vars, procs, set(), set())
    param_count = sum(len(parse_params(p.params)) for p in procs if p.params)
    assert sum(1 for r in result if r.is_parameter) == param_count
    assert sum(1 for r in result if not r.is_parameter) == len(local_vars)


# ── resolve_calls properties ─────────────────────────────────────────────────

@given(calls=st.lists(_make_call(), max_size=20))
@settings(max_examples=300)
def test_resolve_calls_conservation(calls):
    """Output length equals input length — every call gets exactly one result."""
    result = resolve_calls(calls, [], [])
    assert len(result) == len(calls)


@given(calls=st.lists(_make_call(), max_size=20))
@settings(max_examples=300)
def test_resolve_calls_partition(calls):
    """Every resolution_kind and confidence belongs to the fixed partition."""
    result = resolve_calls(calls, [], [])
    for row in result:
        assert row.resolution_kind in RESOLUTION_KINDS
        assert row.confidence in CONFIDENCES


@given(calls=st.lists(_make_call(), max_size=20))
@settings(max_examples=300)
def test_resolve_calls_well_formed(calls):
    """Well-formedness invariants between kind, target, and confidence."""
    result = resolve_calls(calls, [], [])
    for row in result:
        if row.resolution_kind == "static":
            assert row.target_object is not None, "static calls must have target_object"
        if row.resolution_kind == "builtin":
            assert row.confidence == "high", "builtin calls must have high confidence"
        if row.resolution_kind == "unresolved":
            assert row.target_object is None, "unresolved calls must not have target_object"
            assert row.target_proc is None, "unresolved calls must not have target_proc"


@given(
    calls=st.lists(_make_call(), max_size=20),
    procs=st.lists(_make_proc(), max_size=10),
)
@settings(max_examples=200)
def test_resolve_calls_deterministic(calls, procs):
    """resolve_calls is deterministic — same inputs → same outputs."""
    a = resolve_calls(calls, procs, [])
    b = resolve_calls(calls, procs, [])
    assert a == b


@given(
    calls=st.lists(
        st.tuples(
            st.just("f.srw"), st.just("w_test"), st.just("of_init"),
            st.just("fn_sqlerror"), st.just("ExCall"),
        ).map(lambda t: CallRow(*t)),
        min_size=1,
        max_size=5,
    ),
)
@settings(max_examples=100)
def test_resolve_calls_global_fn_resolves(calls):
    """Global functions (fn_sqlerror) resolve even without ancestor chain."""
    procs = [ProcedureRow("f.srw", "fn_sqlerror", "function", "fn_sqlerror",
                          None, None, None, 1, 10, "[]", "", 1)]
    result = resolve_calls(calls, procs, [])
    for row in result:
        assert row.resolution_kind == "virtual"
        assert row.target_object == "fn_sqlerror"
        assert row.confidence == "high"


@given(
    calls=st.lists(
        st.tuples(
            st.just("f.srw"), st.just("w_test"), st.just("of_init"),
            st.sampled_from(["isnull", "setnull", "messagebox", "trn",
                             "rgb", "len", "upper", "lower", "abs"]),
            st.just("ExCall"),
        ).map(lambda t: CallRow(*t)),
        min_size=1,
        max_size=5,
    ),
)
@settings(max_examples=100)
def test_resolve_calls_builtin_resolves(calls):
    """Known PB builtins resolve as builtin with high confidence."""
    result = resolve_calls(calls, [], [])
    for row in result:
        assert row.resolution_kind == "builtin"
        assert row.confidence == "high"
