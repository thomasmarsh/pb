"""Tests for cfg_builder and cfg_renderer."""

from __future__ import annotations

from pb_cli.core.cfg_builder import (
    _is_exbool_value,
    build_cfg,
    compute_node_states,
    mark_unreachable,
)
from pb_cli.core.cfg_renderer import cfg_to_dot

# ---------------------------------------------------------------------------
# Fixtures — inline body_json dicts matching the wire format
# ---------------------------------------------------------------------------

def _loc(tag: str, contents=None, line: int = 1, **extra) -> dict:
    """Build a Located BodyStmt dict."""
    node: dict = {"tag": tag}
    if contents is not None:
        node["contents"] = contents
    node.update(extra)
    return {"line": line, "node": node}


def _assign(line: int = 1) -> dict:
    return _loc("BsAssign", line=line, contents=([{"segments": [{"name": "x", "subscript": None}]}], {"tag": "ExInt", "contents": "1"}))


def _call(line: int = 1) -> dict:
    return _loc("BsCall", line=line, contents={"tag": "ExCall", "callee": {"segments": [{"name": "foo", "subscript": None}]}, "args": []})


def _return_true(line: int = 100) -> dict:
    return _loc("BsReturn", line=line, contents={"tag": "ExBool", "contents": True})


def _return_false(line: int = 100) -> dict:
    return _loc("BsReturn", line=line, contents={"tag": "ExBool", "contents": False})


def _bsif(cond_tag: str, cond_val, then_stmts: list, else_stmts=None, elifs=None, line: int = 10) -> dict:
    cond = {"tag": cond_tag, "contents": cond_val}
    contents = {
        "cond": cond,
        "then": then_stmts,
        "elseIfs": elifs or [],
        "else": else_stmts,
    }
    return _loc("BsIf", line=line, contents=contents)


def _bsfor(body_stmts: list, line: int = 20) -> dict:
    contents = {
        "var": {"segments": [{"name": "i", "subscript": None}]},
        "from": {"tag": "ExInt", "contents": "1"},
        "to": {"tag": "ExInt", "contents": "10"},
        "step": None,
        "body": body_stmts,
    }
    return _loc("BsFor", line=line, contents=contents)


def _bsdo_while(cond_val, body_stmts: list, line: int = 30) -> dict:
    contents = {
        "cond": {"tag": "DoWhile", "contents": cond_val},
        "body": body_stmts,
        "loop": None,
    }
    return _loc("BsDo", line=line, contents=contents)


def _bsdo_loop_until(cond_val, body_stmts: list, line: int = 30) -> dict:
    contents = {
        "cond": None,
        "body": body_stmts,
        "loop": {"tag": "DoUntil", "contents": cond_val},
    }
    return _loc("BsDo", line=line, contents=contents)


def _bschoose(clauses: list, line: int = 40) -> dict:
    contents = {
        "expr": {"tag": "ExLvalue", "contents": {"segments": [{"name": "x", "subscript": None}]}},
        "clauses": clauses,
    }
    return _loc("BsChoose", line=line, contents=contents)


def _case_clause(expr_tokens, body_stmts: list) -> dict:
    return {"expr": expr_tokens, "body": body_stmts}


def _bs_continue(line: int = 50) -> dict:
    return _loc("BsContinue", line=line)


def _bs_exit(line: int = 50) -> dict:
    return _loc("BsExit", line=line)


def _bs_raw(text: str = "SQL", line: int = 1) -> dict:
    return _loc("BsRaw", line=line, contents=text)


# ---------------------------------------------------------------------------
# Linear body
# ---------------------------------------------------------------------------

class TestLinearBody:
    def test_single_block(self):
        body = [_assign(1), _assign(2), _call(3)]
        cfg = build_cfg(body)
        assert len(cfg.blocks) == 1
        assert len(cfg.blocks[cfg.entry].stmts) == 3
        assert cfg.blocks[cfg.entry].first_line == 1
        assert cfg.blocks[cfg.entry].last_line == 3

    def test_empty_body(self):
        cfg = build_cfg([])
        assert len(cfg.blocks) == 1
        assert cfg.blocks[cfg.entry].stmts == []


# ---------------------------------------------------------------------------
# BsIf
# ---------------------------------------------------------------------------

class TestBsIf:
    def test_if_no_else(self):
        body = [
            _assign(1),
            _bsif("ExBool", False, [_assign(10)], line=5),
            _assign(20),
        ]
        cfg = build_cfg(body)
        # Entry block has stmt before if, merge block has stmt after
        tags = [e.label for e in cfg.edges]
        assert "T" in tags
        assert "F" in tags

    def test_if_with_else(self):
        body = [
            _bsif("ExBool", False, [_assign(10)], else_stmts=[_assign(20)], line=5),
        ]
        cfg = build_cfg(body)
        # Should have: entry → then, entry → else, both → merge
        assert len(cfg.blocks) >= 3
        assert len(cfg.edges) >= 4  # T, F, then→merge, else→merge

    def test_if_constant_true_marks_false_unreachable(self):
        body = [_bsif("ExBool", True, [_assign(10)], else_stmts=[_assign(20)], line=5)]
        cfg = build_cfg(body)
        states = compute_node_states(cfg)
        unreachable = [bid for bid, s in states.items() if s == "unreachable"]
        assert len(unreachable) >= 1

    def test_if_constant_false_marks_true_unreachable(self):
        body = [_bsif("ExBool", False, [_assign(10)], else_stmts=[_assign(20)], line=5)]
        cfg = build_cfg(body)
        states = compute_node_states(cfg)
        unreachable = [bid for bid, s in states.items() if s == "unreachable"]
        assert len(unreachable) >= 1


# ---------------------------------------------------------------------------
# BsFor
# ---------------------------------------------------------------------------

class TestBsFor:
    def test_for_loop_structure(self):
        body = [_bsfor([_assign(21), _assign(22)], line=20)]
        cfg = build_cfg(body)
        # Should have: entry, cond, body, post
        assert len(cfg.blocks) >= 4
        loop_edges = [e for e in cfg.edges if e.label == "loop"]
        assert len(loop_edges) == 1
        assert loop_edges[0].label == "loop"


# ---------------------------------------------------------------------------
# BsDo
# ---------------------------------------------------------------------------

class TestBsDo:
    def test_do_while(self):
        body = [_bsdo_while({"tag": "ExBool", "contents": True}, [_assign(31)], line=30)]
        cfg = build_cfg(body)
        # entry → cond, cond→T body, body→loop cond, cond→F merge
        assert len(cfg.blocks) >= 4

    def test_do_loop_until(self):
        body = [_bsdo_loop_until({"tag": "ExBool", "contents": True}, [_assign(31)], line=30)]
        cfg = build_cfg(body)
        # entry → body, body→loop body, body→merge
        assert len(cfg.blocks) >= 3


# ---------------------------------------------------------------------------
# BsChoose
# ---------------------------------------------------------------------------

class TestBsChoose:
    def test_choose_n_clauses(self):
        clauses = [
            _case_clause(["1"], [_assign(41)]),
            _case_clause(["2"], [_assign(42)]),
            _case_clause(["3"], [_assign(43)]),
        ]
        body = [_bschoose(clauses, line=40)]
        cfg = build_cfg(body)
        case_edges = [e for e in cfg.edges if e.label.startswith("case:")]
        assert len(case_edges) == 3
        # All clause entries are different
        clause_entries = {e.dst for e in case_edges}
        assert len(clause_entries) == 3
        # Each clause entry has an outgoing ""-label edge to the merge block
        merge_targets = set()
        for e in cfg.edges:
            if e.src in clause_entries and e.label == "":
                merge_targets.add(e.dst)
        assert len(merge_targets) == 1


# ---------------------------------------------------------------------------
# BsReturn / BsExit / BsContinue
# ---------------------------------------------------------------------------

class TestTerminals:
    def test_return_creates_exit_block(self):
        body = [_assign(1), _return_true(2)]
        cfg = build_cfg(body)
        assert len(cfg.exits) == 1

    def test_return_marks_post_block_unreachable(self):
        body = [_assign(1), _return_true(2), _assign(3)]
        cfg = build_cfg(body)
        states = compute_node_states(cfg)
        unreachable = [bid for bid, s in states.items() if s == "unreachable"]
        assert len(unreachable) >= 1

    def test_exit_creates_exit_block(self):
        body = [_bs_exit(5)]
        cfg = build_cfg(body)
        assert len(cfg.exits) >= 1

    def test_continue_creates_back_edge(self):
        body = [
            _bsfor([_assign(21), _bs_continue(22)], line=20),
        ]
        cfg = build_cfg(body)
        loop_edges = [e for e in cfg.edges if e.label == "loop"]
        assert len(loop_edges) >= 1


# ---------------------------------------------------------------------------
# Nested control flow
# ---------------------------------------------------------------------------

class TestNesting:
    def test_nested_if_inside_for(self):
        body = [
            _bsfor(
                [
                    _assign(21),
                    _bsif("ExBool", False, [_assign(31)], line=25),
                    _assign(22),
                ],
                line=20,
            ),
        ]
        cfg = build_cfg(body)
        # No block id collision
        assert len(cfg.blocks) == len(set(cfg.blocks.keys()))

    def test_chained_if_elseif_else(self):
        body = [
            _bsif(
                "ExBool", False,
                [_assign(10)],
                elifs=[{"cond": {"tag": "ExBool", "contents": False}, "body": [_assign(20)]}],
                else_stmts=[_assign(30)],
                line=5,
            ),
        ]
        cfg = build_cfg(body)
        # Should have multiple branches merging
        assert len(cfg.blocks) >= 4


# ---------------------------------------------------------------------------
# mark_unreachable
# ---------------------------------------------------------------------------

class TestMarkUnreachable:
    def test_fully_connected_no_unreachable(self):
        body = [_assign(1), _assign(2)]
        cfg = build_cfg(body)
        assert mark_unreachable(cfg) == set()

    def test_disconnected_block(self):
        body = [_assign(1), _return_true(2), _assign(3)]
        cfg = build_cfg(body)
        unreachable = mark_unreachable(cfg)
        assert len(unreachable) >= 1


# ---------------------------------------------------------------------------
# compute_node_states
# ---------------------------------------------------------------------------

class TestComputeNodeStates:
    def test_all_default_for_linear(self):
        body = [_assign(1), _assign(2)]
        cfg = build_cfg(body)
        states = compute_node_states(cfg)
        assert all(s == "default" for s in states.values())

    def test_exbool_constant_folding(self):
        body = [_bsif("ExBool", True, [_assign(10)], else_stmts=[_assign(20)], line=5)]
        cfg = build_cfg(body)
        states = compute_node_states(cfg)
        unreachable = [bid for bid, s in states.items() if s == "unreachable"]
        assert len(unreachable) >= 1


# ---------------------------------------------------------------------------
# _is_exbool_value
# ---------------------------------------------------------------------------

class TestIsExBoolValue:
    def test_true(self):
        assert _is_exbool_value({"tag": "ExBool", "contents": True}, True)

    def test_false(self):
        assert _is_exbool_value({"tag": "ExBool", "contents": False}, False)

    def test_wrong_value(self):
        assert not _is_exbool_value({"tag": "ExBool", "contents": True}, False)

    def test_not_exbool(self):
        assert not _is_exbool_value({"tag": "ExInt", "contents": "1"}, True)


# ---------------------------------------------------------------------------
# cfg_to_dot
# ---------------------------------------------------------------------------

class TestCfgToDot:
    def test_renders_all_blocks(self):
        body = [_assign(1), _bsif("ExBool", False, [_assign(10)], line=5), _assign(20)]
        cfg = build_cfg(body)
        states = compute_node_states(cfg)
        dot = cfg_to_dot(cfg, states)
        assert "digraph" in dot.source
        for bid in cfg.blocks:
            assert bid in dot.source

    def test_unreachable_block_appears_in_dot(self):
        body = [_bsif("ExBool", True, [_assign(10)], else_stmts=[_assign(20)], line=5)]
        cfg = build_cfg(body)
        states = compute_node_states(cfg)
        dot = cfg_to_dot(cfg, states)
        assert "dashed" in dot.source
