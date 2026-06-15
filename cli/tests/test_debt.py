"""Unit tests for pb_cli.debt — pure Python, no cabal needed."""
from pb_cli.debt import (
    BsRawStats, DwStats,
    categorize,
    walk_bsraw, walk_exraw,
)


# ── categorize ────────────────────────────────────────────────────────────────

def test_categorize_sql():
    for kw in ("SELECT foo FROM bar", "INSERT INTO t", "commit", "rollback"):
        cat, first = categorize(kw)
        assert cat == "sql", f"expected sql for {kw!r}, got {cat!r}"


def test_categorize_ctrl():
    for kw in ("if x > 0", "end if", "for i = 1 to 10", "do while"):
        cat, _ = categorize(kw)
        assert cat == "ctrl", f"expected ctrl for {kw!r}, got {cat!r}"


def test_categorize_decl():
    for kw in ("event clicked()", "function integer foo()", "type w_main from window"):
        cat, _ = categorize(kw)
        assert cat == "decl", f"expected decl for {kw!r}, got {cat!r}"


def test_categorize_handled():
    for stmt in ("return 0", "exit", "continue", "call super::clicked"):
        cat, _ = categorize(stmt)
        assert cat == "handled", f"expected handled for {stmt!r}, got {cat!r}"


def test_categorize_label_is_handled():
    cat, _ = categorize("myLabel:")
    assert cat == "handled"


def test_categorize_array_init():
    cat, _ = categorize("{ 1, 2, 3 }")
    assert cat == "array_init"


def test_categorize_other():
    cat, first = categorize("post event ue_load()")
    assert cat == "other"
    assert first == "post"


def test_categorize_empty():
    cat, key = categorize("")
    assert cat == "empty"
    assert key == ""

    cat, key = categorize("   ")
    assert cat == "empty"


# ── walk_bsraw ────────────────────────────────────────────────────────────────

def test_walk_bsraw_finds_raw_text():
    node = {"tag": "BsRaw", "contents": "select 1"}
    assert list(walk_bsraw(node)) == ["select 1"]


def test_walk_bsraw_recurses_into_body():
    node = {"tag": "BsIf", "body": [{"tag": "BsRaw", "contents": "select 1"}]}
    assert list(walk_bsraw(node)) == ["select 1"]


def test_walk_bsraw_ignores_exraw():
    node = {"tag": "ExRaw", "contents": ["foo", "bar"]}
    assert list(walk_bsraw(node)) == []


def test_walk_bsraw_handles_list():
    nodes = [
        {"tag": "BsRaw", "contents": "a"},
        {"tag": "BsRaw", "contents": "b"},
    ]
    assert list(walk_bsraw(nodes)) == ["a", "b"]


def test_walk_bsraw_empty():
    assert list(walk_bsraw({})) == []
    assert list(walk_bsraw([])) == []


# ── walk_exraw ────────────────────────────────────────────────────────────────

def test_walk_exraw_finds_raw_with_tokens():
    node = {"tag": "ExRaw", "contents": ["create", "ClassName"]}
    results = list(walk_exraw(node))
    assert len(results) == 1
    first, toks = results[0]
    assert first == "create"
    assert toks == ["create", "ClassName"]


def test_walk_exraw_skips_empty_tokens():
    node = {"tag": "ExRaw", "contents": []}
    assert list(walk_exraw(node)) == []


def test_walk_exraw_ignores_bsraw():
    node = {"tag": "BsRaw", "contents": "select 1"}
    assert list(walk_exraw(node)) == []


def test_walk_exraw_recurses():
    node = {"tag": "BsCall", "contents": {"tag": "ExRaw", "contents": ["post", "event"]}}
    results = list(walk_exraw(node))
    assert len(results) == 1
    assert results[0][0] == "post"


# ── dataclasses ───────────────────────────────────────────────────────────────

def test_bsraw_stats_defaults():
    s = BsRawStats()
    assert s.bsraw_total == 0
    assert s.exraw_total == 0
    assert len(s.other) == 0


def test_dw_stats_defaults():
    s = DwStats()
    assert s.files == 0
    assert s.total == 0
    assert len(s.fields) == 0
    assert len(s.types) == 0
