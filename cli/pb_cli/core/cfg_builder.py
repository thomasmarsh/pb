"""Build a Control Flow Graph from a procedure's body_json.

Pure module — no I/O, no graphviz, no DuckDB.  The public API is:

    build_cfg(body: list) -> CFG
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


class _Counter:
    __slots__ = ("_n",)

    def __init__(self) -> None:
        self._n = 0

    def next(self) -> str:
        bid = f"b{self._n}"
        self._n += 1
        return bid


def _flush_block(
    cfg: CFG,
    counter: _Counter,
    current_id: str,
    stmts: list[dict],
) -> str | None:
    """Flush accumulated statements into a block.  Returns the block id if non-empty."""
    if not stmts:
        return current_id
    block = cfg.blocks[current_id]
    block.stmts.extend(stmts)
    for s in stmts:
        line = s.get("line")
        if isinstance(line, int):
            if block.first_line is None:
                block.first_line = line
            block.last_line = line
    return current_id


def _new_block(cfg: CFG, counter: _Counter) -> str:
    bid = counter.next()
    cfg.blocks[bid] = BasicBlock(id=bid, stmts=[])
    return bid


def _add_edge(cfg: CFG, src: str, dst: str, label: str = "") -> None:
    cfg.edges.append(CFGEdge(src=src, dst=dst, label=label))


def _lower(
    stmts: list[dict],
    cfg: CFG,
    counter: _Counter,
    current_id: str,
    loop_head: str | None,
) -> str:
    """Process a list of Located BodyStmt dicts, returning the id of the block
    that subsequent statements should append to.

    `loop_head` is the block id of the nearest enclosing loop header (for
    BsContinue back-edges).
    """
    pending: list[dict] = []

    for stmt in stmts:
        node = stmt.get("node", {})
        tag = node.get("tag", "")

        if tag in ("BsIf", "BsFor", "BsDo", "BsChoose"):
            pending.append(stmt)
            _flush_block(cfg, counter, current_id, pending)
            pending = []
            if tag == "BsIf":
                current_id = _lower_if(node, cfg, counter, current_id, loop_head)
            elif tag == "BsFor":
                current_id = _lower_for(node, cfg, counter, current_id, loop_head)
            elif tag == "BsDo":
                current_id = _lower_do(node, cfg, counter, current_id, loop_head)
            else:
                current_id = _lower_choose(node, cfg, counter, current_id, loop_head)

        elif tag in ("BsReturn", "BsExit"):
            pending.append(stmt)
            _flush_block(cfg, counter, current_id, pending)
            pending = []
            cfg.exits.append(current_id)
            current_id = _new_block(cfg, counter)

        elif tag == "BsContinue":
            pending.append(stmt)
            _flush_block(cfg, counter, current_id, pending)
            pending = []
            if loop_head:
                _add_edge(cfg, current_id, loop_head, "loop")
            current_id = _new_block(cfg, counter)

        else:
            pending.append(stmt)

    _flush_block(cfg, counter, current_id, pending)
    return current_id


def _lower_if(
    node: dict,
    cfg: CFG,
    counter: _Counter,
    current_id: str,
    loop_head: str | None,
) -> str:
    contents = node.get("contents", {})
    then_stmts = contents.get("then", [])
    else_ifs = contents.get("elseIfs", [])
    else_stmts = contents.get("else")

    merge_id = _new_block(cfg, counter)

    # True branch — T edge from dispatch block
    then_entry = _new_block(cfg, counter)
    _add_edge(cfg, current_id, then_entry, "T")
    then_exit = _lower(then_stmts, cfg, counter, then_entry, loop_head)
    _add_edge(cfg, then_exit, merge_id)

    # ElseIf branches — each gets its own sub-dispatch
    prev_fallthrough = current_id
    for i, elif_node in enumerate(else_ifs):
        elif_entry = _new_block(cfg, counter)
        elif_stmts = elif_node.get("body", [])
        label = "F" if i == 0 else "F"
        _add_edge(cfg, prev_fallthrough, elif_entry, label)
        elif_exit = _lower(elif_stmts, cfg, counter, elif_entry, loop_head)
        _add_edge(cfg, elif_exit, merge_id)
        prev_fallthrough = elif_entry

    # False branch — F edge from last fallthrough
    if else_stmts is not None:
        else_entry = _new_block(cfg, counter)
        _add_edge(cfg, prev_fallthrough, else_entry, "F")
        else_exit = _lower(else_stmts, cfg, counter, else_entry, loop_head)
        _add_edge(cfg, else_exit, merge_id)
    else:
        _add_edge(cfg, prev_fallthrough, merge_id, "F")

    return merge_id


def _lower_for(
    node: dict,
    cfg: CFG,
    counter: _Counter,
    current_id: str,
    loop_head: str | None,
) -> str:
    contents = node.get("contents", {})
    body_stmts = contents.get("body", [])

    cond_id = _new_block(cfg, counter)
    _add_edge(cfg, current_id, cond_id)

    body_entry = _new_block(cfg, counter)
    _add_edge(cfg, cond_id, body_entry, "T")

    body_exit = _lower(body_stmts, cfg, counter, body_entry, cond_id)
    _add_edge(cfg, body_exit, cond_id, "loop")

    post_id = _new_block(cfg, counter)
    _add_edge(cfg, cond_id, post_id, "F")

    return post_id


def _lower_do(
    node: dict,
    cfg: CFG,
    counter: _Counter,
    current_id: str,
    loop_head: str | None,
) -> str:
    contents = node.get("contents", {})
    body_stmts = contents.get("body", [])
    cond = contents.get("cond")
    loop = contents.get("loop")

    merge_id = _new_block(cfg, counter)

    if cond is not None:
        # DO WHILE condition: condition at top
        cond_id = _new_block(cfg, counter)
        _add_edge(cfg, current_id, cond_id)

        body_entry = _new_block(cfg, counter)
        _add_edge(cfg, cond_id, body_entry, "T")

        body_exit = _lower(body_stmts, cfg, counter, body_entry, cond_id)
        _add_edge(cfg, body_exit, cond_id, "loop")

        _add_edge(cfg, cond_id, merge_id, "F")
        return merge_id

    elif loop is not None:
        # DO ... LOOP WHILE/UNTIL: condition at bottom
        body_entry = _new_block(cfg, counter)
        _add_edge(cfg, current_id, body_entry)

        body_exit = _lower(body_stmts, cfg, counter, body_entry, body_entry)
        _add_edge(cfg, body_exit, merge_id, "loop")

        return merge_id

    else:
        # DO ... LOOP (infinite — no condition)
        body_entry = _new_block(cfg, counter)
        _add_edge(cfg, current_id, body_entry)

        body_exit = _lower(body_stmts, cfg, counter, body_entry, body_entry)
        _add_edge(cfg, body_exit, merge_id)

        return merge_id


def _lower_choose(
    node: dict,
    cfg: CFG,
    counter: _Counter,
    current_id: str,
    loop_head: str | None,
) -> str:
    contents = node.get("contents", {})
    clauses = contents.get("clauses", [])

    merge_id = _new_block(cfg, counter)

    for i, clause in enumerate(clauses):
        clause_entry = _new_block(cfg, counter)
        _add_edge(cfg, current_id, clause_entry, f"case:{i}")

        clause_body = clause.get("body", [])
        clause_exit = _lower(clause_body, cfg, counter, clause_entry, loop_head)
        _add_edge(cfg, clause_exit, merge_id)

    if not clauses:
        _add_edge(cfg, current_id, merge_id)

    return merge_id


def build_cfg(body: list) -> CFG:
    """Convert a procedure body_json list into a Control Flow Graph."""
    counter = _Counter()
    cfg = CFG(entry="", exits=[], blocks={}, edges=[])
    entry_id = _new_block(cfg, counter)
    cfg.entry = entry_id

    _lower(body, cfg, counter, entry_id, loop_head=None)

    return cfg


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
