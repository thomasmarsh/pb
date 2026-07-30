"""Unit tests for pb.api.services.objects."""

from __future__ import annotations

import duckdb
import pytest
from pb.api.services.objects import (
    get_dw_layout,
    get_explore_tree,
    get_object_detail,
    get_object_layout,
    get_object_source,
    get_object_uses,
    get_resolved_calls,
    get_resolved_var_refs,
    pbl_name,
)


def test_pbl_name_extracts_library():
    assert pbl_name("repo/mylib.pbl/w_obj.srw") == "mylib.pbl"


def test_pbl_name_fallback_to_parent():
    assert pbl_name("repo/objects/w_obj.srw") == "objects"


def test_pbl_name_unknown():
    assert pbl_name("single") == "(unknown)"


def test_get_object_detail_returns_dict(db_conn: duckdb.DuckDBPyConnection):
    result = get_object_detail(db_conn, "fn_sqlerror")
    assert result is not None
    assert result["name"] == "fn_sqlerror"
    assert result["category"] == "function"  # fn_sqlerror.srf
    assert "procedures" in result
    assert "metrics" in result
    assert "ancestors" in result
    assert "descendants" in result
    assert "callers" in result
    assert "callees" in result
    assert isinstance(result["procedures"], list)


def test_get_object_detail_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_detail(db_conn, "__nonexistent__") is None


def test_get_object_detail_stdlib_object(db_conn: duckdb.DuckDBPyConnection):
    """A System-category (stdlib) object must resolve by name like any other --
    the exclusion in get_object_detail's WHERE clause only makes sense for the
    unscoped listing/tree queries, not a lookup keyed on an exact name."""
    row = db_conn.execute("SELECT object FROM objects WHERE category = 'system' LIMIT 1").fetchone()
    assert row is not None, "no category='system' object found in the fixture corpus"
    result = get_object_detail(db_conn, row[0])
    assert result is not None
    assert result["category"] == "system"


def test_get_object_source_returns_dict(db_conn: duckdb.DuckDBPyConnection):
    result = get_object_source(db_conn, "fn_sqlerror")
    assert result is not None
    assert "file" in result
    assert "lines" in result
    assert "procedures" in result
    assert "knownObjects" in result
    assert "resolvedCalls" in result
    assert "resolvedVarRefs" in result
    assert isinstance(result["lines"], list)


def test_get_object_source_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_source(db_conn, "__nonexistent__") is None


def test_get_object_source_var_refs_include_instance_vars(db_conn: duckdb.DuckDBPyConnection):
    """An object's instance (data member) variable reads must reach the source
    viewer's resolvedVarRefs with kind == "instance", scoped by the actual
    procedure the reference occurs in -- Plan 195 Phase F."""
    row = db_conn.execute(
        "SELECT object FROM resolved_var_refs WHERE kind = 'instance' "
        "GROUP BY object ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no objects with instance var refs in fixture corpus"
    result = get_object_source(db_conn, row[0])
    assert result is not None
    instance_refs = [r for r in result["resolvedVarRefs"] if r["kind"] == "instance"]
    assert len(instance_refs) > 0
    assert all(r["proc_name"] for r in instance_refs)


def test_get_resolved_calls_returns_span_columns(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object FROM resolved_calls GROUP BY object ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no resolved_calls rows in fixture corpus"
    result = get_resolved_calls(db_conn, row[0])
    assert len(result) > 0
    call = result[0]
    for key in (
        "proc_name", "to_name", "call_type", "line", "target_object",
        "target_proc", "kind", "confidence",
        "to_name_start_line", "to_name_start_col",
        "to_name_end_line", "to_name_end_col",
    ):
        assert key in call


def test_get_resolved_calls_scoped_to_object(db_conn: duckdb.DuckDBPyConnection):
    assert get_resolved_calls(db_conn, "__nonexistent__") == []


def test_get_resolved_calls_returns_target_signature_columns(db_conn: duckdb.DuckDBPyConnection):
    """The source-hover tooltip renders a PB QuickInfo-style signature header
    (`<Function> name (params) returns type`), which needs the *target*
    procedure's own signature alongside the call-resolution metadata."""
    row = db_conn.execute(
        "SELECT rc.object FROM resolved_calls rc "
        "JOIN procedures p ON LOWER(p.object) = LOWER(rc.target_object) "
        "AND LOWER(p.proc_name) = LOWER(rc.target_proc) "
        "WHERE p.params IS NOT NULL "
        "GROUP BY rc.object ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no resolved_calls row in fixture corpus has a target with known params"
    result = get_resolved_calls(db_conn, row[0])
    with_sig = [c for c in result if c["target_params"] is not None]
    assert len(with_sig) > 0
    assert with_sig[0]["target_proc_type"] in ("function", "subroutine", "event", "on")


def test_get_resolved_calls_target_signature_null_when_unresolved(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object FROM resolved_calls WHERE kind = 'unresolved' LIMIT 1"
    ).fetchone()
    assert row is not None, "no unresolved resolved_calls row in fixture corpus"
    result = get_resolved_calls(db_conn, row[0])
    unresolved = [c for c in result if c["kind"] == "unresolved"]
    assert len(unresolved) > 0
    assert unresolved[0]["target_proc_type"] is None


def test_get_resolved_calls_signature_resolves_through_multihop_ancestor_chain(
    db_conn: duckdb.DuckDBPyConnection,
):
    """Plan 214 scope-item-3: a builtin method declared only on a distant
    runtime/*.sru ancestor (TriggerEvent lives on powerobject.sru, 4 hops up
    from a real window's own ancestor chain) must still resolve to a real
    target signature, not just the resolution kind/confidence."""
    row = db_conn.execute(
        "SELECT object FROM resolved_calls "
        "WHERE LOWER(to_name) = 'triggerevent' AND kind = 'inherited' LIMIT 1"
    ).fetchone()
    assert row is not None, "no inherited TriggerEvent call in fixture corpus"
    result = get_resolved_calls(db_conn, row[0])
    hits = [c for c in result if c["to_name"].lower() == "triggerevent" and c["kind"] == "inherited"]
    assert len(hits) > 0
    assert hits[0]["target_object"] == "powerobject"
    assert hits[0]["target_proc_type"] == "function"
    assert hits[0]["target_params"] is not None


def test_get_resolved_calls_signature_resolves_for_plan_214_backfilled_method(
    db_conn: duckdb.DuckDBPyConnection,
):
    """Plan 214 backfill: datastore.Retrieve had zero methods declared on
    runtime/datastore.sru before this plan (the file was 10 lines, type
    variables only) -- a real corpus call to it must now get a signature."""
    row = db_conn.execute(
        "SELECT object FROM resolved_calls "
        "WHERE LOWER(to_name) = 'retrieve' AND target_object = 'datastore' LIMIT 1"
    ).fetchone()
    assert row is not None, "no datastore.Retrieve call in fixture corpus"
    result = get_resolved_calls(db_conn, row[0])
    hits = [c for c in result if c["to_name"].lower() == "retrieve" and c["target_object"] == "datastore"]
    assert len(hits) > 0
    assert hits[0]["target_proc_type"] == "function"
    assert hits[0]["target_params"] is not None


def test_get_resolved_var_refs_returns_span_columns(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object FROM resolved_var_refs GROUP BY object ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no resolved_var_refs rows in fixture corpus"
    result = get_resolved_var_refs(db_conn, row[0])
    assert len(result) > 0
    ref = result[0]
    for key in (
        "proc_name", "line", "name", "access", "target_object", "kind", "confidence",
        "name_start_line", "name_start_col", "name_end_line", "name_end_col", "declared_type",
    ):
        assert key in ref


def test_get_resolved_var_refs_scoped_to_proc(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object, proc_name FROM resolved_var_refs WHERE proc_name != '' "
        "GROUP BY object, proc_name ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no proc-scoped resolved_var_refs rows in fixture corpus"
    object_name, proc_name = row
    scoped = get_resolved_var_refs(db_conn, object_name, proc_name)
    assert len(scoped) > 0
    assert all(r["proc_name"] == proc_name for r in scoped)
    unscoped = get_resolved_var_refs(db_conn, object_name)
    assert len(unscoped) >= len(scoped)


def test_get_object_detail_structures_empty_when_no_inline_structures(db_conn: duckdb.DuckDBPyConnection):
    """fn_sqlerror owns no inline structure -- `structures` must be an empty
    list, not absent, matching every other list-shaped detail field."""
    result = get_object_detail(db_conn, "fn_sqlerror")
    assert result is not None
    assert result["structures"] == []


def _object_detail_conn_with_inline_structure() -> duckdb.DuckDBPyConnection:
    """Synthetic corpus: `w_fish` owns an inline structure `s_fish` with two
    fields. The real openpay fixture (used by `db_conn`) has zero inline
    structures -- only standalone `.srs` files -- so this case needs a
    hand-built DB, following `test_tables_service.py`'s `:memory:` pattern.
    """
    conn = duckdb.connect(":memory:")
    conn.execute("CREATE TABLE objects (file TEXT, kind TEXT, object TEXT, ancestor TEXT, category TEXT)")
    conn.execute("CREATE TABLE object_metrics (object TEXT)")
    conn.execute("CREATE TABLE procedures (file TEXT, object TEXT, owner TEXT, proc_type TEXT, proc_name TEXT, params TEXT, return_type TEXT, start_line INTEGER, end_line INTEGER, cyclomatic INTEGER)")
    conn.execute("CREATE TABLE structures (file TEXT, object TEXT, owner TEXT)")
    conn.execute("CREATE TABLE global_vars (file TEXT, object TEXT, var_name TEXT, var_type TEXT, mods TEXT)")
    conn.execute("CREATE TABLE call_sites (file TEXT, object TEXT, proc_name TEXT, to_name TEXT)")
    conn.execute("CREATE TABLE all_sql_tables (file TEXT, object TEXT, source TEXT, table_name TEXT)")
    conn.execute("CREATE TABLE window_opens (file TEXT, object TEXT, proc_name TEXT, line INTEGER, target_object TEXT)")
    conn.execute("CREATE TABLE object_creates (file TEXT, object TEXT, proc_name TEXT, line INTEGER, target_object TEXT)")
    conn.execute("CREATE TABLE window_menu_bindings (file TEXT, object TEXT, menu_name TEXT)")
    conn.execute("CREATE TABLE dw_bindings (file TEXT, object TEXT, control_name TEXT, dw_name TEXT)")
    conn.execute("CREATE TABLE resolved_calls (file TEXT, object TEXT, proc_name TEXT, to_name TEXT, call_type TEXT, line INTEGER, target_object TEXT, target_proc TEXT, kind TEXT, confidence TEXT)")
    conn.execute("INSERT INTO objects VALUES ('w_fish.srw', 'powerscript', 'w_fish', NULL, 'window')")
    conn.execute("INSERT INTO structures VALUES ('w_fish.srw', 's_fish', 'w_fish')")
    conn.execute(
        "INSERT INTO global_vars VALUES "
        "('w_fish.srw', 's_fish', 'species', 'string', NULL), "
        "('w_fish.srw', 's_fish', 'weight', 'decimal', NULL)"
    )
    return conn


def test_get_object_detail_includes_inline_structure_fields():
    conn = _object_detail_conn_with_inline_structure()
    result = get_object_detail(conn, "w_fish")
    assert result is not None
    assert result["structures"] == [
        {
            "name": "s_fish",
            "fields": [
                {"var_name": "species", "var_type": "string", "modifiers": None},
                {"var_name": "weight", "var_type": "decimal", "modifiers": None},
            ],
        }
    ]


# ── "Uses" (Plan 210 Phase 4b) ───────────────────────────────────────────────
# w_misth_final_details_list is real openpay corpus data exercising all five
# use-kinds at once: it opens 2 windows, creates its own popup menu, binds
# that menu, binds a DW control, and calls 4 distinct global functions. It
# also has `call super::create/destroy/open` (resolving to its ancestor
# w_list) and inherited Open/OpenSheet dispatch (resolving to the builtin
# `window`/`powerobject` stdlib classes) -- both must NOT appear as uses.

_USES_OBJECT = "w_misth_final_details_list"


def test_get_object_uses_real_corpus(db_conn: duckdb.DuckDBPyConnection):
    uses = get_object_uses(db_conn, _USES_OBJECT)
    by_kind: dict[str, list[dict]] = {}
    for u in uses:
        by_kind.setdefault(u["kind"], []).append(u)

    assert {u["target"] for u in by_kind.get("window_open", [])} == {
        "wiz_misth_final_details", "wprn_final_atomiki_misth_arg",
    }
    assert [u["target"] for u in by_kind.get("object_create", [])] == ["m_misth_final_details_list"]
    assert [u["target"] for u in by_kind.get("menu_binding", [])] == ["m_misth_final_details_list"]
    assert by_kind.get("dw_binding") == [
        {
            "kind": "dw_binding",
            "target": "dw_misth_final_details_list",
            "target_category": "datawindow",
            "proc_name": None,
            "line": None,
            "control_name": "dw",
        }
    ]
    assert {u["target"] for u in by_kind.get("function_call", [])} == {
        "fn_perm", "fn_sqlerror", "gsc_misth_final_ypal_reset", "trn",
    }
    # Ancestor-dispatch (`call super::...`) and builtin-class noise must not leak through.
    noise = {"w_list", "window", "powerobject"}
    assert not ({u["target"] for u in uses} & noise)


def test_get_object_uses_not_found_returns_empty(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_uses(db_conn, "__nonexistent__") == []


def test_get_object_detail_includes_uses_field(db_conn: duckdb.DuckDBPyConnection):
    result = get_object_detail(db_conn, _USES_OBJECT)
    assert result is not None
    assert result["uses"] == get_object_uses(db_conn, _USES_OBJECT)


def test_get_object_detail_dws_used_via_dw_bindings(db_conn: duckdb.DuckDBPyConnection):
    """BACKLOG 2026-07-22: dws_used must come from dw_bindings, not the old
    call_sites heuristic (which returned [] for this real object -- a
    control->DataWindow binding is not a function call)."""
    result = get_object_detail(db_conn, _USES_OBJECT)
    assert result is not None
    assert result["dws_used"] == ["dw_misth_final_details_list"]


def test_get_object_detail_tables_accessed_via_dw_bindings(db_conn: duckdb.DuckDBPyConnection):
    result = get_object_detail(db_conn, _USES_OBJECT)
    assert result is not None
    assert result["tables_accessed"] == [
        "misth_final", "misth_final_ypal", "misth_ypal", "misth_zpkat", "misth_zpperiod",
    ]


def test_get_object_detail_control_owned_event_has_control_owner(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object, proc_name FROM procedures "
        "WHERE proc_type = 'event' AND owner IS NOT NULL AND owner != object LIMIT 1"
    ).fetchone()
    assert row is not None, "expected at least one control-owned event in the openpay corpus"
    obj, proc_name = row
    detail = get_object_detail(db_conn, obj)
    assert detail is not None
    match = next(p for p in detail["procedures"] if p["name"] == proc_name)
    assert match["owner"] not in (None, obj)


def test_get_explore_tree_control_owned_event_has_control_owner(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object, proc_name FROM procedures "
        "WHERE proc_type = 'event' AND owner IS NOT NULL AND owner != object LIMIT 1"
    ).fetchone()
    assert row is not None, "expected at least one control-owned event in the openpay corpus"
    obj, proc_name = row
    result = get_explore_tree(db_conn)
    all_objects = [o for lib in result["libraries"] for o in lib["objects"]]
    target = next(o for o in all_objects if o["name"] == obj)
    match = next(p for p in target["procedures"] if p["name"] == proc_name)
    assert match["owner"] not in (None, obj)


def test_get_explore_tree(db_conn: duckdb.DuckDBPyConnection):
    result = get_explore_tree(db_conn)
    assert "libraries" in result
    assert isinstance(result["libraries"], list)
    assert len(result["libraries"]) > 0
    lib = result["libraries"][0]
    assert "name" in lib
    assert "objects" in lib
    if lib["objects"]:
        obj = lib["objects"][0]
        assert "procedures" in obj
        assert isinstance(obj["procedures"], list)


def test_get_explore_tree_includes_datawindows(db_conn: duckdb.DuckDBPyConnection):
    result = get_explore_tree(db_conn)
    all_objects = [obj for lib in result["libraries"] for obj in lib["objects"]]
    kinds = {obj["kind"] for obj in all_objects}
    assert "datawindow" in kinds, "explore tree must include DataWindow objects"
    dw_objs = [obj for obj in all_objects if obj["kind"] == "datawindow"]
    assert len(dw_objs) > 0
    for obj in dw_objs:
        assert "name" in obj
        assert "file" in obj
        assert obj["category"] == "datawindow"
        assert obj["procedures"] == []


# ── DataWindowFile wire-format integration tests ─────────────────────────────
# These tests catch drift between PB.Pipeline.Serialise (Haskell) and the
# manually maintained ui/src/types/ast.ts TypeScript types.

_DW_TOP_LEVEL_KEYS = {"release", "object", "table", "bands", "groups", "controls", "unknowns", "meta"}
_CONTROL_KEYS = {"type", "band", "name", "id", "x", "y", "width", "height",
                 "visible", "expression", "parsedExpression", "format", "parsedFormat",
                 "tabSeq", "attrs"}


def test_get_explore_tree_category_matches_file_extension(db_conn: duckdb.DuckDBPyConnection):
    """Every PowerScript object's category agrees with its export extension
    across the whole real corpus, not just one hand-picked name."""
    result = get_explore_tree(db_conn)
    all_objects = [obj for lib in result["libraries"] for obj in lib["objects"]]
    ext_to_category = {
        ".srw": "window", ".sru": "userobject", ".srm": "menu",
        ".sra": "application", ".srf": "function",
    }
    checked = 0
    for obj in all_objects:
        file = obj.get("file", "").lower()
        for ext, expected in ext_to_category.items():
            if file.endswith(ext):
                assert obj["category"] == expected, f"{file}: expected category {expected}, got {obj['category']}"
                checked += 1
    assert checked > 0, "no PowerScript objects found in the fixture corpus to check category against"


def test_dw_layout_top_level_keys(db_conn: duckdb.DuckDBPyConnection):
    """DataWindowFile JSON has all expected top-level keys."""
    row = db_conn.execute("SELECT object FROM dw_objects LIMIT 1").fetchone()
    assert row is not None, "no DW objects in fixture corpus"
    layout = get_dw_layout(db_conn, row[0])
    assert layout is not None
    missing = _DW_TOP_LEVEL_KEYS - layout.keys()
    assert not missing, f"DataWindowFile missing keys: {missing}"


def test_dw_layout_controls_have_expected_keys(db_conn: duckdb.DuckDBPyConnection):
    """Each DwControl in the layout has all expected field keys."""
    rows = db_conn.execute("SELECT object FROM dw_objects LIMIT 10").fetchall()
    for (name,) in rows:
        layout = get_dw_layout(db_conn, name)
        if not layout:
            continue
        for ctrl in layout["controls"]:
            missing = _CONTROL_KEYS - ctrl.keys()
            assert not missing, f"DwControl in {name} missing keys: {missing}"


def test_dw_layout_parsed_expression_has_tag(db_conn: duckdb.DuckDBPyConnection):
    """parsedExpression nodes carry a 'tag' discriminant matching the Expr union."""
    rows = db_conn.execute("SELECT object FROM dw_objects LIMIT 30").fetchall()
    checked = 0
    for (name,) in rows:
        layout = get_dw_layout(db_conn, name)
        if not layout:
            continue
        for ctrl in layout["controls"]:
            for field in ("parsedExpression", "parsedFormat"):
                pe = ctrl.get(field)
                if pe is not None:
                    assert isinstance(pe, dict), f"{field} must be a dict, got {type(pe)}"
                    assert "tag" in pe, f"{field} missing 'tag' key: {pe}"
                    checked += 1
    # non-zero check: the openpay corpus has expressions; if this fires the fixture changed
    assert checked > 0, "no parsedExpression/parsedFormat found in 30 DW objects — fixture may be empty"


def test_get_object_layout_returns_window_shape(db_conn: duckdb.DuckDBPyConnection):
    """get_object_layout returns {name, type, width, height, controls} for a .srw object.

    Filters on layout_json actually having a "height" key, not just being
    non-null: extractWindowLayout (PB.Pipeline.Emit) only emits width/height
    when the source window declares them explicitly, so plenty of real
    objects have layout_json with width but no height. An unfiltered/
    unordered LIMIT 1 over "any object with layout_json" is a coin flip on
    whether the picked window happens to have one -- it must pick
    deterministically from windows that actually satisfy what the test
    asserts, not from all non-null rows.
    """
    row = db_conn.execute(
        "SELECT object FROM objects WHERE kind = 'powerscript' "
        "AND json_extract(layout_json, '$.height') IS NOT NULL ORDER BY object LIMIT 1"
    ).fetchone()
    if row is None:
        pytest.skip("no objects with layout_json in fixture corpus")
    layout = get_object_layout(db_conn, row[0])
    assert layout is not None
    assert "name" in layout
    assert "type" in layout
    assert "width" in layout
    assert "height" in layout
    assert "controls" in layout
    assert isinstance(layout["controls"], list)
    # Numeric dimensions (not strings)
    assert isinstance(layout["width"], int), f"width should be int, got {type(layout['width'])}"
    assert isinstance(layout["height"], int), f"height should be int, got {type(layout['height'])}"


def test_get_object_layout_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_layout(db_conn, "__nonexistent__") is None


def test_dw_layout_band_kind_has_tag(db_conn: duckdb.DuckDBPyConnection):
    """DwBandKind nodes carry a 'tag' discriminant matching the DwBandKind union."""
    row = db_conn.execute("SELECT object FROM dw_objects LIMIT 1").fetchone()
    assert row is not None
    layout = get_dw_layout(db_conn, row[0])
    assert layout is not None
    for band in layout["bands"]:
        assert "kind" in band
        assert "tag" in band["kind"], f"DwBand.kind missing 'tag': {band['kind']}"
    for ctrl in layout["controls"]:
        if ctrl.get("band") is not None:
            assert "tag" in ctrl["band"], f"DwControl.band missing 'tag': {ctrl['band']}"
