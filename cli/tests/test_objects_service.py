"""Unit tests for pb_cli.explorer.services.objects."""

from __future__ import annotations

import duckdb
import pytest

from pb_cli.explorer.services.objects import (
    get_dw_layout,
    get_explore_tree,
    get_object_detail,
    get_object_layout,
    get_object_source,
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
    assert "knownProcs" in result
    assert isinstance(result["lines"], list)


def test_get_object_source_not_found(db_conn: duckdb.DuckDBPyConnection):
    assert get_object_source(db_conn, "__nonexistent__") is None


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
    """get_object_layout returns {name, type, width, height, controls} for a .srw object."""
    row = db_conn.execute(
        "SELECT object FROM objects WHERE kind = 'powerscript' AND layout_json IS NOT NULL LIMIT 1"
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
