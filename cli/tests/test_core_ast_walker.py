import inspect
import typing

from pb_cli.core import ast_generated
from pb_cli.core.ast_generated import (
    BodyStmt,
    DoCondition,
    DwBandKind,
    DwRetrieveOrRaw,
    Expr,
    PbType,
    ProtoDecl,
)
from pb_cli.core.ast_walker import (
    TaggedNode,
    walk_bsraw,
    walk_bsraw_located,
    walk_calls,
    walk_excall_arg_calls,
    walk_exraw,
    walk_tagged,
)


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


# ── walk_excall_arg_calls ─────────────────────────────────────────────────────


def _excall(callee_name: str, args: list[list[str]]) -> dict:
    """Build a minimal ExCall node as produced by the Haskell serialiser."""
    return {"tag": "ExCall", "callee": {"segments": [{"name": callee_name}]}, "args": args}


def test_walk_excall_arg_calls_bare_nested_call():
    # fn_seteditmask(dw, "f", fn_param_maskdate_e()) → yields fn_param_maskdate_e
    node = _excall("fn_seteditmask", [["dw"], ['"f"'], ["fn_param_maskdate_e", "(", ")"]])
    assert list(walk_excall_arg_calls(node)) == ["fn_param_maskdate_e"]


def test_walk_excall_arg_calls_multiple_nested():
    # fn_wrap(fn_a(), fn_b()) → yields fn_a, fn_b
    node = _excall("fn_wrap", [["fn_a", "(", ")"], ["fn_b", "(", ")"]])
    assert list(walk_excall_arg_calls(node)) == ["fn_a", "fn_b"]


def test_walk_excall_arg_calls_skips_method_chain():
    # fn_wrap(obj.method()) — method is preceded by "." so must not be yielded
    node = _excall("fn_wrap", [["obj", ".", "method", "(", ")"]])
    assert list(walk_excall_arg_calls(node)) == []


def test_walk_excall_arg_calls_skips_outer_callee():
    # The outer callee (fn_seteditmask itself) must NOT be yielded
    node = _excall("fn_seteditmask", [["dw"]])
    assert list(walk_excall_arg_calls(node)) == []


def test_walk_excall_arg_calls_no_args():
    node = _excall("fn_no_args", [])
    assert list(walk_excall_arg_calls(node)) == []


def test_walk_excall_arg_calls_literal_arg_not_yielded():
    # String literal token — no following "("
    node = _excall("fn_x", [['"hello"']])
    assert list(walk_excall_arg_calls(node)) == []


def test_walk_excall_arg_calls_nested_in_if_body():
    # walk_excall_arg_calls must recurse through BsIf/BsFor etc.
    body = [
        {
            "line": 1,
            "node": {
                "tag": "BsCall",
                "contents": _excall("outer", [["fn_inner", "(", ")"]]),
            },
        }
    ]
    assert list(walk_excall_arg_calls(body)) == ["fn_inner"]


# ── TaggedNode completeness ────────────────────────────────────────────────


def test_tagged_node_includes_all_sub_unions():
    """TaggedNode must be the union of all tagged sub-unions."""
    expected_sub_unions = {Expr, PbType, DoCondition, BodyStmt, ProtoDecl, DwBandKind, DwRetrieveOrRaw}
    # Python's | flattens nested unions, so get_args returns leaf types.
    # Verify each sub-union's leaves are all present.
    all_leaves = set()
    for sub in expected_sub_unions:
        sub_leaves = typing.get_args(sub) or (sub,)
        all_leaves.update(sub_leaves)
    actual_leaves = set(typing.get_args(TaggedNode))
    assert actual_leaves == all_leaves


def test_tagged_node_covers_all_literal_tagged_classes():
    """Every class with a tag: Literal[...] field must be reachable from TaggedNode."""
    all_classes = {
        name: obj
        for name, obj in inspect.getmembers(ast_generated, inspect.isclass)
        if obj.__module__ == ast_generated.__name__
    }

    tagged_classes: set[str] = set()
    for name, cls in all_classes.items():
        hints = typing.get_type_hints(cls)
        if "tag" in hints:
            tag_type = hints["tag"]
            origin = getattr(tag_type, "__origin__", None)
            if origin is typing.Literal:
                tagged_classes.add(name)

    def collect_type_names(tp: typing.Any) -> set[str]:
        args = typing.get_args(tp)
        if args:
            result: set[str] = set()
            for arg in args:
                result.update(collect_type_names(arg))
            return result
        name = getattr(tp, "__name__", None)
        return {name} if name else set()

    union_names = collect_type_names(TaggedNode)
    missing = tagged_classes - union_names
    assert not missing, f"TaggedNode missing tagged classes: {missing}"
