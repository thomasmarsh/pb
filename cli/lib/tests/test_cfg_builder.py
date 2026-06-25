"""Tests for cfg_builder analysis helpers and cfg_renderer."""

from __future__ import annotations

from pb.lib.cfg_builder import (
    CFG,
    BasicBlock,
    CFGEdge,
    _is_exbool_value,
    compute_node_states,
    mark_unreachable,
)
from pb.lib.cfg_renderer import cfg_to_dot

# ---------------------------------------------------------------------------
# Helpers — construct CFG objects directly
# ---------------------------------------------------------------------------

def _block(bid: str, stmts: list[dict] | None = None, first_line: int | None = None, last_line: int | None = None) -> BasicBlock:
    return BasicBlock(id=bid, stmts=stmts or [], first_line=first_line, last_line=last_line)


def _edge(src: str, dst: str, label: str = "") -> CFGEdge:
    return CFGEdge(src=src, dst=dst, label=label)


def _cfg(entry: str, blocks: list[BasicBlock], edges: list[CFGEdge], exits: list[str] | None = None) -> CFG:
    return CFG(entry=entry, exits=exits or [], blocks={b.id: b for b in blocks}, edges=edges)


def _loc(tag: str, contents=None, line: int = 1) -> dict:
    node: dict = {"tag": tag}
    if contents is not None:
        node["contents"] = contents
    return {"line": line, "node": node}


# ---------------------------------------------------------------------------
# mark_unreachable
# ---------------------------------------------------------------------------

class TestMarkUnreachable:
    def test_fully_connected_no_unreachable(self):
        cfg = _cfg("b0", [_block("b0")], [])
        assert mark_unreachable(cfg) == set()

    def test_disconnected_block(self):
        cfg = _cfg(
            "b0",
            [_block("b0"), _block("b1")],
            [],
        )
        unreachable = mark_unreachable(cfg)
        assert "b1" in unreachable

    def test_linear_chain(self):
        cfg = _cfg(
            "b0",
            [_block("b0"), _block("b1"), _block("b2")],
            [_edge("b0", "b1"), _edge("b1", "b2")],
        )
        assert mark_unreachable(cfg) == set()

    def test_unreachable_branch(self):
        cfg = _cfg(
            "b0",
            [_block("b0"), _block("b1"), _block("b2")],
            [_edge("b0", "b1")],
        )
        unreachable = mark_unreachable(cfg)
        assert "b2" in unreachable


# ---------------------------------------------------------------------------
# compute_node_states
# ---------------------------------------------------------------------------

class TestComputeNodeStates:
    def test_all_default_for_linear(self):
        cfg = _cfg("b0", [_block("b0", [_loc("BsAssign")])], [])
        states = compute_node_states(cfg)
        assert all(s == "default" for s in states.values())

    def test_unreachable_block(self):
        cfg = _cfg(
            "b0",
            [_block("b0"), _block("b1")],
            [],
        )
        states = compute_node_states(cfg)
        assert states["b1"] == "unreachable"

    def test_exbool_constant_folding_true(self):
        cond = {"tag": "ExBool", "contents": True}
        then_stmt = _loc("BsAssign")
        else_stmt = _loc("BsAssign")
        body = [_loc("BsIf", contents={"cond": cond, "then": [then_stmt], "elseIfs": [], "else": [else_stmt]})]
        cfg = _cfg(
            "b0",
            [
                _block("b0", body, first_line=1, last_line=1),
                _block("b1", [_loc("BsAssign")], first_line=10),
                _block("b2", [_loc("BsAssign")], first_line=20),
                _block("b3"),
            ],
            [
                _edge("b0", "b1", "T"),
                _edge("b0", "b2", "F"),
                _edge("b1", "b3"),
                _edge("b2", "b3"),
            ],
        )
        states = compute_node_states(cfg)
        assert states["b2"] == "unreachable"

    def test_exbool_constant_folding_false(self):
        cond = {"tag": "ExBool", "contents": False}
        then_stmt = _loc("BsAssign")
        else_stmt = _loc("BsAssign")
        body = [_loc("BsIf", contents={"cond": cond, "then": [then_stmt], "elseIfs": [], "else": [else_stmt]})]
        cfg = _cfg(
            "b0",
            [
                _block("b0", body, first_line=1, last_line=1),
                _block("b1", [_loc("BsAssign")], first_line=10),
                _block("b2", [_loc("BsAssign")], first_line=20),
                _block("b3"),
            ],
            [
                _edge("b0", "b1", "T"),
                _edge("b0", "b2", "F"),
                _edge("b1", "b3"),
                _edge("b2", "b3"),
            ],
        )
        states = compute_node_states(cfg)
        assert states["b1"] == "unreachable"


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
        cfg = _cfg(
            "b0",
            [
                _block("b0", [_loc("BsAssign")]),
                _block("b1", [_loc("BsAssign")]),
                _block("b2", [_loc("BsAssign")]),
            ],
            [_edge("b0", "b1"), _edge("b0", "b2")],
        )
        states = compute_node_states(cfg)
        dot = cfg_to_dot(cfg, states)
        assert "digraph" in dot.source
        for bid in cfg.blocks:
            assert bid in dot.source

    def test_unreachable_block_appears_in_dot(self):
        cfg = _cfg(
            "b0",
            [
                _block("b0", [_loc("BsAssign")]),
                _block("b1", [_loc("BsAssign")]),
                _block("b2", [_loc("BsAssign")]),
            ],
            [_edge("b0", "b1")],
        )
        states = compute_node_states(cfg)
        dot = cfg_to_dot(cfg, states)
        assert "dashed" in dot.source

    def test_taint_entering_state(self):
        cfg = _cfg(
            "b0",
            [_block("b0"), _block("b1")],
            [_edge("b0", "b1")],
        )
        states = {"b0": "default", "b1": "taint-entering"}
        dot = cfg_to_dot(cfg, states)
        assert "#d97706" in dot.source
