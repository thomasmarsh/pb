"""Control Flow Graph types and analysis helpers.

Pure module — no I/O, no graphviz, no DuckDB.  The public API is:

    cfg_from_json(d: dict) -> CFG
    mark_unreachable(cfg: CFG) -> set[str]
    compute_node_states(cfg: CFG) -> dict[str, str]
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass


@dataclass
class BasicBlock:
    id: str
    stmts: list[dict]
    first_line: int | None = None
    last_line: int | None = None


@dataclass
class CFGEdge:
    src: str
    dst: str
    label: str = ""


@dataclass
class CFG:
    entry: str
    exits: list[str]
    blocks: dict[str, BasicBlock]
    edges: list[CFGEdge]


def cfg_from_json(d: dict) -> CFG:
    """Deserialise a Haskell-generated cfg_json dict back to a Python CFG."""
    blocks = {
        b["id"]: BasicBlock(
            id=b["id"],
            stmts=b.get("stmts", []),
            first_line=b.get("firstLine"),
            last_line=b.get("lastLine"),
        )
        for b in d.get("blocks", [])
    }
    edges = [
        CFGEdge(src=e["src"], dst=e["dst"], label=e.get("label", ""))
        for e in d.get("edges", [])
    ]
    return CFG(
        entry=d.get("entry", ""),
        exits=d.get("exits", []),
        blocks=blocks,
        edges=edges,
    )


def mark_unreachable(cfg: CFG) -> set[str]:
    """Return set of block ids not reachable from the entry block (forward BFS)."""
    visited: set[str] = set()
    q: deque[str] = deque([cfg.entry])
    while q:
        bid = q.popleft()
        if bid in visited:
            continue
        visited.add(bid)
        for e in cfg.edges:
            if e.src == bid:
                q.append(e.dst)
    return set(cfg.blocks) - visited


def _is_exbool_value(node: dict, value: bool) -> bool:
    """Check if a node is ExBool with the given boolean value."""
    return (
        isinstance(node, dict)
        and node.get("tag") == "ExBool"
        and node.get("contents") == value
    )


def _mark_const_unreachable(cfg: CFG) -> set[str]:
    """Mark blocks unreachable due to constant-folded ExBool conditions.

    For BsIf with ExBool true → false branch unreachable.
    For BsIf with ExBool false → true branch unreachable.
    """
    unreachable: set[str] = set()

    for bid, block in cfg.blocks.items():
        for stmt in block.stmts:
            node = stmt.get("node", {})
            if node.get("tag") != "BsIf":
                continue
            contents = node.get("contents", {})
            cond = contents.get("cond", {})

            if _is_exbool_value(cond, True):
                # True branch is always taken; find false-edge from this block
                for e in cfg.edges:
                    if e.src == bid and e.label == "F":
                        _mark_subgraph_unreachable(e.dst, cfg, unreachable)
            elif _is_exbool_value(cond, False):
                for e in cfg.edges:
                    if e.src == bid and e.label == "T":
                        _mark_subgraph_unreachable(e.dst, cfg, unreachable)

    return unreachable


def _mark_subgraph_unreachable(
    start: str, cfg: CFG, unreachable: set[str]
) -> None:
    """Mark all blocks reachable from `start` (exclusive of merge points)
    as unreachable.  This is a forward BFS that stops at blocks with
    multiple incoming edges (merge points) — only the specific branch
    subgraph is dead."""
    visited: set[str] = set()
    q: deque[str] = deque([start])
    while q:
        bid = q.popleft()
        if bid in visited or bid in unreachable:
            continue
        visited.add(bid)
        unreachable.add(bid)
        for e in cfg.edges:
            if e.src == bid:
                # Only follow if this block has exactly one incoming edge
                # (i.e., it's not a merge point from another branch)
                incoming = sum(1 for x in cfg.edges if x.dst == bid)
                if incoming <= 1:
                    q.append(e.dst)


def compute_node_states(cfg: CFG) -> dict[str, str]:
    """Compute per-block node states: unreachable detection + constant folding."""
    bfs_unreachable = mark_unreachable(cfg)
    const_unreachable = _mark_const_unreachable(cfg)
    all_unreachable = bfs_unreachable | const_unreachable

    return {
        bid: ("unreachable" if bid in all_unreachable else "default")
        for bid in cfg.blocks
    }
