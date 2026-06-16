from pb_cli.core.ast_walker import count_branches, walk_bsraw, walk_calls, walk_exraw


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


def test_walk_bsraw():
    node = {"tag": "raw", "text": "SELECT 1"}
    assert list(walk_bsraw(node)) == ["SELECT 1"]


def test_walk_bsraw_nested():
    node = {
        "tag": "if",
        "cond": {},
        "then": [{"tag": "raw", "text": "INSERT INTO t"}],
        "elseIfs": [],
        "else": None,
    }
    assert list(walk_bsraw(node)) == ["INSERT INTO t"]


def test_walk_exraw():
    node = {"tag": "raw", "contents": ["foo", "bar"]}
    results = list(walk_exraw(node))
    assert results == [("foo", ["foo", "bar"])]
