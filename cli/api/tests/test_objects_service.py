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
    assert "procedures" in result
    assert "metrics" in result
    assert "ancestors" in result
    assert "descendants" in result
    assert "callers" in result
    assert "callees" in result
    assert isinstance(result["procedures"], list)


def test_get_object_detail_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_detail(db_conn, "__nonexistent__") is None


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
    assert all(r["from_proc"] for r in instance_refs)


def test_get_resolved_calls_returns_span_columns(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object FROM resolved_calls GROUP BY object ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no resolved_calls rows in fixture corpus"
    result = get_resolved_calls(db_conn, row[0])
    assert len(result) > 0
    call = result[0]
    for key in (
        "from_proc", "to_name", "call_type", "line", "target_object",
        "target_proc", "kind", "confidence",
        "to_name_start_line", "to_name_start_col",
        "to_name_end_line", "to_name_end_col",
    ):
        assert key in call


def test_get_resolved_calls_scoped_to_object(db_conn: duckdb.DuckDBPyConnection):
    assert get_resolved_calls(db_conn, "__nonexistent__") == []


def test_get_resolved_var_refs_returns_span_columns(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object FROM resolved_var_refs GROUP BY object ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no resolved_var_refs rows in fixture corpus"
    result = get_resolved_var_refs(db_conn, row[0])
    assert len(result) > 0
    ref = result[0]
    for key in (
        "from_proc", "line", "name", "access", "target_object", "kind", "confidence",
        "name_start_line", "name_start_col", "name_end_line", "name_end_col", "declared_type",
    ):
        assert key in ref


def test_get_resolved_var_refs_scoped_to_proc(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object, from_proc FROM resolved_var_refs WHERE from_proc != '' "
        "GROUP BY object, from_proc ORDER BY count(*) DESC LIMIT 1"
    ).fetchone()
    assert row is not None, "no proc-scoped resolved_var_refs rows in fixture corpus"
    object_name, proc_name = row
    scoped = get_resolved_var_refs(db_conn, object_name, proc_name)
    assert len(scoped) > 0
    assert all(r["from_proc"] == proc_name for r in scoped)
    unscoped = get_resolved_var_refs(db_conn, object_name)
    assert len(unscoped) >= len(scoped)


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
        assert obj["procedures"] == []


# ── DataWindowFile wire-format integration tests ─────────────────────────────
# These tests catch drift between PB.Pipeline.Serialise (Haskell) and the
# manually maintained ui/src/types/ast.ts TypeScript types.

_DW_TOP_LEVEL_KEYS = {"release", "object", "table", "bands", "groups", "controls", "unknowns", "meta"}
_CONTROL_KEYS = {"type", "band", "name", "id", "x", "y", "width", "height",
                 "visible", "expression", "parsedExpression", "format", "parsedFormat",
                 "tabSeq", "attrs"}


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
