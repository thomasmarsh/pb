"""Tests for core.type_resolution and shell.type_resolution."""

from __future__ import annotations

import json

from pb_cli.core.models import (
    CallRow,
    GlobalVarRow,
    LocalVarRow,
    ProcedureRow,
)
from pb_cli.core.type_resolution import (
    classify_type,
    extract_global_vars,
    parse_params,
    resolve_calls,
    resolve_types,
)
from pb_cli.shell.db import create_schema, db_connection
from pb_cli.shell.type_resolution import build_type_tables

# ── parse_params ──────────────────────────────────────────────────────────────


def test_parse_params_empty():
    assert parse_params("") == []
    assert parse_params("  ") == []


def test_parse_params_single():
    result = parse_params("long ai_id")
    assert result == [("ai_id", "long")]


def test_parse_params_multiple():
    result = parse_params("ref datawindow adw , long row")
    assert result == [("adw", "datawindow"), ("row", "long")]


def test_parse_params_no_type():
    result = parse_params("as_name")
    assert result == []


# ── classify_type ─────────────────────────────────────────────────────────────


def test_classify_primitive():
    objects = set()
    user_types = set()
    for t in ("string", "integer", "long", "boolean", "double", "date", "decimal"):
        kind, target = classify_type(t, objects, user_types)
        assert kind == "primitive", f"{t} should be primitive"
        assert target is None


def test_classify_any():
    kind, target = classify_type("any", set(), set())
    assert kind == "any"


def test_classify_object():
    objects = {"w_main", "nvo_utils"}
    user_types = set()
    kind, target = classify_type("w_main", objects, user_types)
    assert kind == "object"
    assert target == "w_main"


def test_classify_user_type():
    objects = set()
    user_types = {"uo_grid", "sc_misth"}
    kind, target = classify_type("uo_grid", objects, user_types)
    assert kind == "user_type"
    assert target == "uo_grid"


def test_classify_unresolved():
    kind, target = classify_type("zzz_nope", set(), set())
    assert kind == "unresolved"
    assert target is None


def test_classify_datawindow_builtin():
    kind, target = classify_type("datawindow", set(), set())
    assert kind == "primitive"


# ── resolve_types ─────────────────────────────────────────────────────────────


def _make_proc(file, obj, name, params=None, return_type=None, body_json=None):
    return ProcedureRow(
        file=file, object=obj, owner=None, proc_type="function", name=name,
        modifiers=None, params=params, return_type=return_type,
        start_line=1, end_line=10,
        body_json=body_json or "[]",
        source_rendered="", cyclomatic=1,
    )


def test_resolve_types_local_vars():
    local_vars = [
        LocalVarRow("f.srw", "w_test", "of_init", "ls_name", "string", 5),
        LocalVarRow("f.srw", "w_test", "of_init", "ll_count", "long", 6),
        LocalVarRow("f.srw", "w_test", "of_init", "lw_form", "w_main", 7),
    ]
    procedures = [_make_proc("f.srw", "w_test", "of_init")]
    objects = {"w_main"}
    user_types = set()

    result = resolve_types(local_vars, procedures, objects, user_types)
    by_name = {r.var_name: r for r in result}
    assert by_name["ls_name"].resolved_kind == "primitive"
    assert by_name["ll_count"].resolved_kind == "primitive"
    assert by_name["lw_form"].resolved_kind == "object"
    assert by_name["lw_form"].resolved_target == "w_main"


def test_resolve_types_params():
    local_vars = []
    procedures = [
        _make_proc("f.srw", "w_test", "of_retrieve", params="ref datawindow adw , long row"),
    ]
    objects = set()
    user_types = set()

    result = resolve_types(local_vars, procedures, objects, user_types)
    params = [r for r in result if r.is_parameter]
    assert len(params) == 2
    by_name = {r.var_name: r for r in params}
    assert by_name["adw"].raw_type == "datawindow"
    assert by_name["row"].raw_type == "long"
    assert by_name["row"].resolved_kind == "primitive"


# ── resolve_calls ─────────────────────────────────────────────────────────────


def test_resolve_calls_static_dotted():
    calls = [CallRow("f.srw", "w_test", "of_init", "nvo_utils.of_parse", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_test", "of_init", body_json='[]'),
        _make_proc("f.srw", "nvo_utils", "of_parse"),
    ]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    assert len(result) == 1
    r = result[0]
    assert r.target_object == "nvo_utils"
    assert r.target_proc == "of_parse"
    assert r.resolution_kind == "static"
    assert r.confidence == "high"


def test_resolve_calls_virtual_inherited():
    calls = [CallRow("f.srw", "w_child", "open", "of_init", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_child", "open", body_json='[]'),
        _make_proc("f.srw", "w_parent", "of_init"),
    ]
    inherits: list[tuple[str, str]] = [("w_child", "w_parent")]

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.target_object == "w_parent"
    assert r.target_proc == "of_init"
    assert r.resolution_kind == "inherited"
    assert r.confidence == "high"


def test_resolve_calls_virtual_own():
    calls = [CallRow("f.srw", "w_test", "open", "of_init", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_test", "open", body_json='[]'),
        _make_proc("f.srw", "w_test", "of_init"),
    ]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.target_object == "w_test"
    assert r.target_proc == "of_init"
    assert r.resolution_kind == "virtual"


def test_resolve_calls_global_function():
    """Global functions (e.g. fn_sqlerror) are callable from any object.

    They live on a standalone object (fn_sqlerror.fn_sqlerror) and are not
    in the caller's ancestor chain. The resolver must find them via global
    procedure lookup.
    """
    calls = [CallRow("f.srw", "w_filter", "open", "fn_sqlerror", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_filter", "open", body_json='[]'),
        _make_proc("f.srw", "fn_sqlerror", "fn_sqlerror"),
    ]
    inherits: list[tuple[str, str]] = [("w_filter", "w_response")]

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.target_object == "fn_sqlerror"
    assert r.target_proc == "fn_sqlerror"
    assert r.resolution_kind == "virtual"
    assert r.confidence == "high"


def test_resolve_calls_override_nearest_ancestor():
    """Method defined in both child and parent resolves to child (nearest)."""
    calls = [CallRow("f.srw", "w_child", "open", "of_init", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_child", "open", body_json='[]'),
        _make_proc("f.srw", "w_child", "of_init"),
        _make_proc("f.srw", "w_parent", "of_init"),
    ]
    inherits: list[tuple[str, str]] = [("w_child", "w_parent")]

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.target_object == "w_child"
    assert r.target_proc == "of_init"
    assert r.resolution_kind == "virtual"
    assert r.confidence == "high"


def test_resolve_calls_override_three_levels():
    """Method in grandparent, parent, and child — child (nearest) wins."""
    calls = [CallRow("f.srw", "w_grandchild", "open", "of_init", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_grandchild", "open", body_json='[]'),
        _make_proc("f.srw", "w_grandchild", "of_init"),
        _make_proc("f.srw", "w_parent", "of_init"),
        _make_proc("f.srw", "w_grandparent", "of_init"),
    ]
    inherits: list[tuple[str, str]] = [
        ("w_grandchild", "w_parent"),
        ("w_parent", "w_grandparent"),
    ]

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.target_object == "w_grandchild"
    assert r.resolution_kind == "virtual"
    assert r.confidence == "high"


def test_resolve_calls_override_middle_ancestor():
    """Child does NOT override, parent does — parent is resolved (inherited)."""
    calls = [CallRow("f.srw", "w_child", "open", "of_init", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_child", "open", body_json='[]'),
        _make_proc("f.srw", "w_parent", "of_init"),
        _make_proc("f.srw", "w_grandparent", "of_init"),
    ]
    inherits: list[tuple[str, str]] = [
        ("w_child", "w_parent"),
        ("w_parent", "w_grandparent"),
    ]

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.target_object == "w_parent"
    assert r.resolution_kind == "inherited"
    assert r.confidence == "high"


def test_resolve_calls_unresolved():
    calls = [CallRow("f.srw", "w_test", "open", "of_nope", "ExCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.resolution_kind == "unresolved"
    assert r.confidence == "low"


def test_resolve_calls_dispatch_unresolved():
    calls = [CallRow("f.srw", "w_test", "open", "ue_init", "ExDispatch")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.resolution_kind == "unresolved"
    assert r.call_type == "ExDispatch"


def test_resolve_calls_method_unresolved():
    calls = [CallRow("f.srw", "w_test", "open", "customMethod", "ExMethodCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.resolution_kind == "unresolved"
    assert r.call_type == "ExMethodCall"


def test_resolve_calls_line_extraction():
    body = json.dumps([
        {"line": 15, "node": {"tag": "BsCall", "contents": {
            "tag": "ExCall",
            "callee": {"segments": [{"name": "nvo_utils"}, {"name": "of_parse"}]},
            "args": [],
        }}}
    ])
    calls = [CallRow("f.srw", "w_test", "of_init", "nvo_utils.of_parse", "ExCall")]
    procedures = [
        _make_proc("f.srw", "w_test", "of_init", body_json=body),
        _make_proc("f.srw", "nvo_utils", "of_parse"),
    ]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    assert result[0].call_line == 15


# ── return_type from PB API signatures ────────────────────────────────────────


def _builtin_call(to_name: str, call_type: str = "ExCall") -> list:
    return [CallRow("f.srw", "w_test", "open", to_name, call_type)]


def _base_proc():
    return [_make_proc("f.srw", "w_test", "open", body_json="[]")]


def test_builtin_return_type_abs():
    result = resolve_calls(_builtin_call("abs"), _base_proc(), [])
    assert result[0].resolution_kind == "builtin"
    assert result[0].return_type == "any"


def test_builtin_return_type_left():
    result = resolve_calls(_builtin_call("left"), _base_proc(), [])
    assert result[0].resolution_kind == "builtin"
    assert result[0].return_type == "string"


def test_builtin_return_type_mid():
    result = resolve_calls(_builtin_call("mid"), _base_proc(), [])
    assert result[0].resolution_kind == "builtin"
    assert result[0].return_type == "string"


def test_builtin_return_type_retrieve_class_method():
    # dw_1.retrieve — dot-delimited; "retrieve" is a datawindow method returning long.
    result = resolve_calls(
        _builtin_call("dw_1.retrieve"),
        _base_proc(),
        [],
        var_types={("w_test", "open", "dw_1"): "datawindow"},
    )
    assert result[0].resolution_kind == "builtin"
    assert result[0].return_type == "long"


def test_builtin_return_type_void():
    # garbagecollect() returns "none" — should be normalised to return_type=None.
    result = resolve_calls(_builtin_call("garbagecollect"), _base_proc(), [])
    assert result[0].resolution_kind == "builtin"
    assert result[0].return_type is None


def test_user_proc_return_type_none():
    # User-defined calls always have return_type=None regardless of their signature.
    calls = [CallRow("f.srw", "w_test", "open", "of_init", "ExCall")]
    procs = [
        _make_proc("f.srw", "w_test", "open", body_json="[]"),
        _make_proc("f.srw", "w_test", "of_init", return_type="string"),
    ]
    result = resolve_calls(calls, procs, [])
    assert result[0].resolution_kind in ("virtual", "static")
    assert result[0].return_type is None


# ── build_type_tables (integration) ───────────────────────────────────────────


def test_build_type_tables_integration(tmp_path):
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        conn.execute(
            "INSERT INTO objects VALUES (?,?,?,?,?,?,?)",
            ("f.srw", "w_test", "powerscript", None, None, None, None),
        )
        conn.execute(
            "INSERT INTO objects VALUES (?,?,?,?,?,?,?)",
            ("f.srw", "nvo_utils", "powerscript", None, None, None, None),
        )
        conn.execute(
            "INSERT INTO procedures (file, object, proc_type, name, modifiers, params, return_type, start_line, end_line, body_json, source_rendered, cyclomatic) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            ("f.srw", "w_test", "function", "of_init", None, None, None, 1, 10, "[]", "", 1),
        )
        conn.execute(
            "INSERT INTO local_variables VALUES (?,?,?,?,?,?)",
            ("f.srw", "w_test", "of_init", "ls_name", "string", 5),
        )
        conn.execute(
            "INSERT INTO calls VALUES (?,?,?,?,?)",
            ("f.srw", "w_test", "of_init", "nvo_utils.of_parse", "ExCall"),
        )

        build_type_tables(conn)

        types = conn.execute("SELECT resolved_kind, COUNT(*) FROM resolved_types GROUP BY resolved_kind").fetchall()
        assert dict(types) == {"primitive": 1}

        calls = conn.execute("SELECT resolution_kind FROM resolved_calls").fetchall()
        assert calls[0][0] == "static"


# ── extract_global_vars ───────────────────────────────────────────────────────


def test_extract_global_vars_passthrough():
    rows = [
        GlobalVarRow("f.sra", "openpay", "gs_lock", "string", None, "global"),
    ]
    result = extract_global_vars(rows, [])
    assert len(result) == 1
    assert result[0].var_name == "gs_lock"


def test_resolve_calls_instance_var_type():
    """Bare call resolves via instance variable type from global_vars.

    A procedure with no local variables calls retrieve(). The object has
    an instance variable dw_data typed as datawindow. The call should
    resolve because retrieve is a DataWindow method.
    """
    calls = [CallRow("f.srw", "w_test", "open", "retrieve", "ExCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits: list[tuple[str, str]] = []
    # Instance variable from type variables block
    var_types: dict[tuple[str, str, str], str] = {("w_test", "", "dw_data"): "datawindow"}

    result = resolve_calls(calls, procedures, inherits, var_types=var_types)
    r = result[0]
    assert r.resolution_kind == "builtin"
    # retrieve is a DataWindow class method, resolves via var_types
    assert r.confidence == "medium"


def test_resolve_calls_instance_var_inherited_type():
    """Bare call resolves when instance var type inherits from PB class.

    Instance variable typed as u_grid (inherits from datawindow).
    retrieve should resolve by walking u_grid's ancestor chain.
    """
    calls = [CallRow("f.srw", "w_test", "open", "retrieve", "ExCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits: list[tuple[str, str]] = [("u_grid", "datawindow")]
    var_types: dict[tuple[str, str, str], str] = {("w_test", "", "dw_data"): "u_grid"}

    result = resolve_calls(calls, procedures, inherits, var_types=var_types)
    r = result[0]
    assert r.resolution_kind == "builtin"


# ── infer_control_type ────────────────────────────────────────────────────────


def test_infer_control_type_dw():
    from pb_cli.core.type_resolution import infer_control_type
    assert infer_control_type("dw_main") == "datawindow"
    assert infer_control_type("dw_detail") == "datawindow"


def test_infer_control_type_cb():
    from pb_cli.core.type_resolution import infer_control_type
    assert infer_control_type("cb_ok") == "commandbutton"
    assert infer_control_type("cb_cancel") == "commandbutton"


def test_infer_control_type_dddw():
    from pb_cli.core.type_resolution import infer_control_type
    assert infer_control_type("dddw_category") == "datawindowchild"


def test_infer_control_type_no_match():
    from pb_cli.core.type_resolution import infer_control_type
    assert infer_control_type("some_var") is None
    assert infer_control_type("data") is None


def test_infer_control_type_ddlb_before_lb():
    from pb_cli.core.type_resolution import infer_control_type
    # ddlb_ should match before lb_
    assert infer_control_type("ddlb_status") == "dropdownlistbox"


# ── _resolve_pb_class_from_ancestor ───────────────────────────────────────────


def test_ancestor_chain_window():
    from pb_cli.core.type_resolution import _resolve_pb_class_from_ancestor
    objects_table: dict[str, str | None] = {
        "w_misth_final_list": "w_list",
        "w_list": "window",
    }
    assert _resolve_pb_class_from_ancestor("w_misth_final_list", objects_table) == "window"


def test_ancestor_chain_userobject():
    from pb_cli.core.type_resolution import _resolve_pb_class_from_ancestor
    objects_table: dict[str, str | None] = {
        "u_grid": "userobject",
    }
    assert _resolve_pb_class_from_ancestor("u_grid", objects_table) == "userobject"


def test_ancestor_chain_direct_pb():
    from pb_cli.core.type_resolution import _resolve_pb_class_from_ancestor
    objects_table: dict[str, str | None] = {"w_test": "window"}
    assert _resolve_pb_class_from_ancestor("w_test", objects_table) == "window"


def test_ancestor_chain_no_pb():
    from pb_cli.core.type_resolution import _resolve_pb_class_from_ancestor
    objects_table: dict[str, str | None] = {"fn_test": "function_object"}
    # function_object is not in PB_CLASS_METHODS
    assert _resolve_pb_class_from_ancestor("fn_test", objects_table) is None


def test_ancestor_chain_missing_object():
    from pb_cli.core.type_resolution import _resolve_pb_class_from_ancestor
    assert _resolve_pb_class_from_ancestor("nonexistent", {}) is None


# ── resolve_calls with objects_table ──────────────────────────────────────────


def test_resolve_calls_ancestor_chain_builtin():
    """Bare call resolves via objects.ancestor chain to PB built-in class."""
    calls = [CallRow("f.srw", "w_test", "open", "setfocus", "ExCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits: list[tuple[str, str]] = []
    objects_table: dict[str, str | None] = {"w_test": "window"}

    result = resolve_calls(calls, procedures, inherits, objects_table=objects_table)
    r = result[0]
    assert r.resolution_kind == "builtin"
    assert r.confidence == "high"


def test_resolve_calls_ancestor_chain_indirect():
    """Bare call resolves via multi-step ancestor chain."""
    calls = [CallRow("f.srw", "w_child", "open", "setredraw", "ExCall")]
    procedures = [_make_proc("f.srw", "w_child", "open", body_json='[]')]
    inherits: list[tuple[str, str]] = [("w_child", "w_parent")]
    objects_table: dict[str, str | None] = {"w_child": "w_parent", "w_parent": "window"}

    result = resolve_calls(calls, procedures, inherits, objects_table=objects_table)
    r = result[0]
    assert r.resolution_kind == "builtin"


def test_resolve_calls_dotted_ancestor_builtin():
    """Dotted call where first segment is not an object stays unresolved."""
    calls = [CallRow("f.srw", "w_test", "open", "dw_main.setredraw", "ExCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits: list[tuple[str, str]] = []
    objects_table: dict[str, str | None] = {}

    # dw_main is not an object, no var_types → unresolved
    result = resolve_calls(calls, procedures, inherits, objects_table=objects_table)
    r = result[0]
    assert r.resolution_kind == "unresolved"


def test_resolve_calls_dotted_control_type_inference():
    """Dotted call resolves when first segment is typed via var_types."""
    calls = [CallRow("f.srw", "w_test", "open", "dw_main.setredraw", "ExCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits: list[tuple[str, str]] = []
    objects_table: dict[str, str | None] = {}
    var_types: dict[tuple[str, str, str], str] = {("w_test", "open", "dw_main"): "datawindow"}

    result = resolve_calls(calls, procedures, inherits, var_types=var_types, objects_table=objects_table)
    r = result[0]
    assert r.resolution_kind == "builtin"
    assert r.confidence == "medium"


def test_resolve_calls_control_type_inference():
    """Bare call resolves via control type inference from naming convention."""
    calls = [CallRow("f.srw", "w_test", "open", "retrieve", "ExCall")]
    procedures = [_make_proc("f.srw", "w_test", "open", body_json='[]')]
    inherits: list[tuple[str, str]] = []
    # No explicit type, but dw_main should be inferred as datawindow
    var_types: dict[tuple[str, str, str], str] = {("w_test", "open", "dw_main"): "datawindow"}

    result = resolve_calls(calls, procedures, inherits, var_types=var_types)
    r = result[0]
    assert r.resolution_kind == "builtin"


# ── ExCallArg call type ────────────────────────────────────────────────────────


def test_resolve_calls_excall_arg_global_function():
    """ExCallArg rows (nested calls in ExCall args) resolve via global lookup.

    Models fn_seteditmask(..., fn_param_round()) where fn_param_round is a
    standalone global function living on the fn_param_round object.
    """
    calls = [CallRow("f.srw", "w_misth", "of_init", "fn_param_round", "ExCallArg")]
    procedures = [
        _make_proc("f.srw", "w_misth", "of_init", body_json='[]'),
        _make_proc("fn_param_round.srf", "fn_param_round", "fn_param_round"),
    ]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.target_object == "fn_param_round"
    assert r.target_proc == "fn_param_round"
    assert r.resolution_kind == "virtual"
    assert r.confidence == "high"


def test_resolve_calls_excall_arg_unresolved():
    """ExCallArg for a name not in any procedure resolves as unresolved."""
    calls = [CallRow("f.srw", "w_misth", "of_init", "count", "ExCallArg")]
    procedures = [_make_proc("f.srw", "w_misth", "of_init", body_json='[]')]
    inherits = []

    result = resolve_calls(calls, procedures, inherits)
    r = result[0]
    assert r.resolution_kind == "unresolved"
    assert r.target_object is None
