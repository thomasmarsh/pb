from pb_cli.core.ast_walker import count_branches, walk_bsraw, walk_bsraw_located, walk_calls, walk_exraw, walk_local_vars, walk_tagged


def test_walk_calls_excall():
    node = {"tag": "ExCall", "callee": {"segments": [{"name": "fn_sqlerror"}]}}
    calls = walk_calls(node)
    assert calls == [("fn_sqlerror", "ExCall")]


def test_walk_calls_nested():
    node = {
        "tag": "BsIf",
        "contents": {
            "cond": {"tag": "ExCall", "callee": {"segments": [{"name": "f1"}]}},
            "then": [{"tag": "BsCall", "contents": {"tag": "ExCall", "callee": {"segments": [{"name": "f2"}]}}}],
        },
    }
    calls = walk_calls(node)
    assert len(calls) == 2


def test_count_branches_if():
    node = {"tag": "BsIf", "contents": {"cond": {}, "then": [], "elseIfs": [], "else": None}}
    assert count_branches(node) == 1


def test_count_branches_nested():
    node = {
        "tag": "BsFor",
        "contents": {"body": [{"tag": "BsIf", "contents": {"cond": {}, "then": [], "elseIfs": [], "else": None}}]},
    }
    assert count_branches(node) == 2


# ── walk_tagged ────────────────────────────────────────────────────────────


def test_walk_tagged_finds_top_level_tag():
    node = {"tag": "BsRaw", "contents": "select 1"}
    results = list(walk_tagged(node))
    assert results == [("BsRaw", node, None)]


def test_walk_tagged_tracks_located_line():
    node = {"line": 42, "node": {"tag": "BsRaw", "contents": "select 1"}}
    results = list(walk_tagged(node))
    tags = {(tag, line) for tag, _n, line in results}
    assert ("BsRaw", 42) in tags


def test_walk_tagged_line_does_not_leak_across_siblings():
    """A node's own 'line' must not get overwritten by an unrelated sibling subtree."""
    node = [
        {"line": 1, "node": {"tag": "BsRaw", "contents": "a"}},
        {"line": 2, "node": {"tag": "BsRaw", "contents": "b"}},
    ]
    results = [(tag, line) for tag, n, line in walk_tagged(node) if tag == "BsRaw"]
    assert results == [("BsRaw", 1), ("BsRaw", 2)]


def test_walk_tagged_recurses_through_unknown_wrapper_shapes():
    """No hand-coded field names: a BsRaw nested under an arbitrarily-named
    future field must still be found, since walk_tagged recurses into every
    dict value unconditionally."""
    node = {"tag": "BsTryCatch", "contents": {"tryBody": [{"tag": "BsRaw", "contents": "select 1"}]}}
    tags = [tag for tag, _n, _line in walk_tagged(node)]
    assert "BsRaw" in tags


# ── walk_bsraw / walk_bsraw_located ──────────────────────────────────────────


def test_walk_bsraw():
    node = {"tag": "BsRaw", "contents": "SELECT 1"}
    assert list(walk_bsraw(node)) == ["SELECT 1"]


def test_walk_bsraw_nested():
    node = {
        "tag": "BsIf",
        "contents": {
            "cond": {},
            "then": [{"tag": "BsRaw", "contents": "INSERT INTO t"}],
            "elseIfs": [],
            "else": None,
        },
    }
    assert list(walk_bsraw(node)) == ["INSERT INTO t"]


def test_walk_bsraw_located_reports_real_line():
    node = {
        "line": 1,
        "node": {
            "tag": "BsIf",
            "contents": {
                "cond": {},
                "then": [{"line": 7, "node": {"tag": "BsRaw", "contents": "SELECT 1"}}],
                "elseIfs": [],
                "else": None,
            },
        },
    }
    assert list(walk_bsraw_located(node)) == [("SELECT 1", 7)]


# ── walk_exraw ────────────────────────────────────────────────────────────


def test_walk_exraw():
    node = {"tag": "ExRaw", "contents": ["foo", "bar"]}
    results = list(walk_exraw(node))
    assert results == [("foo", ["foo", "bar"])]


# ── walk_local_vars ────────────────────────────────────────────────────────


def test_walk_local_vars_simple():
    node = {
        "tag": "BsLocalVar",
        "mods": [],
        "type": {"tag": "PtPrimitive", "contents": "integer"},
        "name": "i_count",
        "init": None,
    }
    results = walk_local_vars(node)
    assert results == [("i_count", "integer")]


def test_walk_local_vars_with_mods():
    node = {
        "tag": "BsLocalVar",
        "mods": ["constant"],
        "type": {"tag": "PtPrimitive", "contents": "long"},
        "name": "ll_max",
        "init": {"tag": "ExInt", "contents": "100"},
    }
    results = walk_local_vars(node)
    assert results == [("ll_max", "long")]


def test_walk_local_vars_user_defined_type():
    node = {
        "tag": "BsLocalVar",
        "mods": [],
        "type": {"tag": "PtUserDefined", "contents": "n_cst_service"},
        "name": "svc",
        "init": None,
    }
    results = walk_local_vars(node)
    assert results == [("svc", "n_cst_service")]


def test_walk_local_vars_any_type():
    node = {
        "tag": "BsLocalVar",
        "mods": [],
        "type": {"tag": "PtAny"},
        "name": "ax",
        "init": None,
    }
    results = walk_local_vars(node)
    assert results == [("ax", "any")]


def test_walk_local_vars_decimal_precision():
    node = {
        "tag": "BsLocalVar",
        "mods": [],
        "type": {"tag": "PtDecimalPrec", "contents": 10},
        "name": "lc_val",
        "init": None,
    }
    results = walk_local_vars(node)
    assert results == [("lc_val", "decimal{10}")]


def test_walk_local_vars_nested_in_if():
    node = {
        "tag": "BsIf",
        "contents": {
            "cond": {},
            "then": [
                {
                    "tag": "BsLocalVar",
                    "mods": [],
                    "type": {"tag": "PtPrimitive", "contents": "string"},
                    "name": "ls_name",
                    "init": None,
                }
            ],
            "elseIfs": [],
            "else": None,
        },
    }
    results = walk_local_vars(node)
    assert results == [("ls_name", "string")]


def test_walk_local_vars_empty_body():
    node = {"tag": "BsIf", "contents": {"cond": {}, "then": [], "elseIfs": [], "else": None}}
    results = walk_local_vars(node)
    assert results == []
