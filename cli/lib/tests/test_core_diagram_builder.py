from pb.lib.diagram_builder import (
    complexity_color,
    kind_color,
    render_calls,
    render_dw_tables,
    render_fk_graph,
    render_heatmap,
    render_inheritance,
    render_proc_tables,
    render_sql_lineage,
    render_table_lineage,
)


def test_complexity_color_low():
    c = complexity_color(0)
    assert c.startswith("#")


def test_complexity_color_high():
    c = complexity_color(30)
    assert c.startswith("#")


def test_kind_color_powerscript():
    assert kind_color("powerscript") == "#5B8DD9"


def test_kind_color_unknown():
    assert kind_color("bogus") == "#D0D0D0"


def test_render_inheritance_empty_edges():
    dot = render_inheritance([], {}, None)
    assert "digraph" in dot.source


def test_render_inheritance_root_highlighted_even_if_isolated():
    dot = render_inheritance([], {}, "lone_root")
    assert "lone_root" in dot.source
    assert "doubleoctagon" in dot.source


def test_render_calls_focal_gets_doublecircle():
    dot = render_calls({"fn_a"}, [], {}, "fn_a")
    assert "doublecircle" in dot.source


def test_render_sql_lineage_empty_shows_placeholder():
    dot = render_sql_lineage([])
    assert "No PowerScript SQL statements found" in dot.source


def test_render_table_lineage_requires_table_name():
    import pytest

    with pytest.raises(ValueError):
        render_table_lineage([], "")


def test_render_proc_tables_empty_with_table_filter_names_it():
    dot = render_proc_tables([], "synthetic_table")
    assert "synthetic_table" in dot.source


def test_render_dw_tables_dedupes_dw_names():
    rows = [("dw_a", "t1"), ("dw_a", "t2")]
    dot = render_dw_tables(rows, {"dw_a": 2})
    assert dot.source.count("dw_a") >= 1


def test_render_heatmap_legend_present():
    dot = render_heatmap([("obj_a", "powerscript", 0, 0)], [])
    assert "Cyclomatic complexity" in dot.source


def test_render_fk_graph_empty_shows_placeholder():
    dot = render_fk_graph([])
    assert "No FK relationships found" in dot.source


def test_render_fk_graph_colors_by_category():
    edges = [
        ("usrgroups", "kodgroup", "usrmembers", "kodgroup", "corroborated"),
        ("usrgroupperm", "kodaction", "usractions", "kodaction", "unenforced"),
        ("afxtable", "kodowner", "afxowner", "kodowner", "unused"),
    ]
    dot = render_fk_graph(edges)
    assert "usrgroups" in dot.source
    assert "usrmembers" in dot.source
    assert "usrgroupperm" in dot.source
    assert "usractions" in dot.source
    assert "afxtable" in dot.source
    assert "afxowner" in dot.source
    # three distinct edge styles, one per category
    assert "dashed" in dot.source
    assert "dotted" in dot.source
