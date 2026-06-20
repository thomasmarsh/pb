"""Diagram service — CFG analysis pipeline and rendering."""

from __future__ import annotations

import json
from typing import Any

import duckdb
import graphviz

from pb_cli.core.cfg_builder import build_cfg, compute_node_states
from pb_cli.core.cfg_renderer import cfg_to_dot


def get_cfg_diagram(
    conn: duckdb.DuckDBPyConnection,
    object_name: str,
    proc_name: str,
) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT body_json, start_line, end_line FROM procedures WHERE object = ? AND name = ? LIMIT 1",
        [object_name, proc_name],
    ).fetchone()
    if not row or not row[0]:
        return None

    body = json.loads(row[0])
    proc_start_line: int | None = row[1]
    proc_end_line: int | None = row[2]

    source_original: str | None = None
    if proc_start_line and proc_end_line:
        src_row = conn.execute(
            "SELECT source_text FROM objects WHERE name = ? LIMIT 1", [object_name]
        ).fetchone()
        if src_row and src_row[0]:
            all_lines = src_row[0].splitlines(keepends=True)
            source_original = "".join(all_lines[max(0, proc_start_line - 1) : proc_end_line])

    cfg = build_cfg(body)

    node_states = compute_node_states(cfg)

    try:
        ann_rows = conn.execute(
            "SELECT block_id, is_taint_entry FROM taint_annotations "
            "WHERE object = ? AND proc_name = ?",
            [object_name, proc_name],
        ).fetchall()
        for block_id, is_taint_entry in ann_rows:
            if is_taint_entry and node_states.get(block_id) != "unreachable":
                node_states[block_id] = "taint-entering"
    except Exception:
        pass

    dot = cfg_to_dot(cfg, node_states)
    try:
        svg = dot.pipe(format="svg").decode("utf-8")
    except graphviz.backend.execute.ExecutableNotFound:
        raise

    def _stmt_label(s: dict) -> str:
        tag = s.get("node", {}).get("tag", "?")
        line = s.get("line", "")
        return f"L{line} {tag}" if line else tag

    block_details = [
        {
            "blockId": bid,
            "firstLine": block.first_line,
            "lastLine": block.last_line,
            "stmts": [_stmt_label(s) for s in block.stmts],
        }
        for bid, block in cfg.blocks.items()
    ]

    return {
        "svg": svg,
        "nodeStates": [{"blockId": bid, "state": s} for bid, s in node_states.items()],
        "blocks": block_details,
        "sourceOriginal": source_original,
        "procStartLine": proc_start_line,
    }
