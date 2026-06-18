"""Render a CFG to Graphviz DOT format.

Pure module — only depends on graphviz and cfg_builder types.
"""

from __future__ import annotations

import graphviz

from pb_cli.core.cfg_builder import CFG, BasicBlock

_STATE_ATTRS: dict[str, dict[str, str]] = {
    "default": {"fillcolor": "white", "style": "filled"},
    "unreachable": {"fillcolor": "#ffffaa", "style": "filled,dashed"},
    "taint-entering": {"fillcolor": "white", "style": "filled", "color": "#d97706"},
    "proven-safe": {"fillcolor": "#f0f0ff", "style": "filled", "color": "#4338ca"},
}


def cfg_to_dot(cfg: CFG, node_states: dict[str, str]) -> graphviz.Digraph:
    dot = graphviz.Digraph(graph_attr={"rankdir": "TB", "splines": "ortho"})
    dot.attr("node", shape="box", fontname="monospace", fontsize="10")

    for bid, block in cfg.blocks.items():
        state = node_states.get(bid, "default")
        attrs = _STATE_ATTRS.get(state, _STATE_ATTRS["default"])
        label = _block_label(bid, block)
        dot.node(bid, label=label, id=bid, **attrs)

    for edge in cfg.edges:
        dot.edge(edge.src, edge.dst, label=edge.label, fontsize="9")

    return dot


def _block_label(bid: str, block: BasicBlock) -> str:
    lines = [f"<{bid}>"]
    stmts = block.stmts[:3]
    for s in stmts:
        node = s.get("node", {})
        tag = node.get("tag", "?")
        line = s.get("line", "")
        text = f"L{line} {tag}"[:60]
        lines.append(text)
    if len(block.stmts) > 3:
        lines.append(f"… +{len(block.stmts) - 3} more")
    return "\n".join(lines)
