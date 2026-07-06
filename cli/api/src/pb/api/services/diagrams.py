"""Diagram service — CFG analysis pipeline and rendering."""

from __future__ import annotations

import json
from typing import Any

import duckdb
import graphviz
from pb.lib.cfg_builder import cfg_from_json, compute_node_states
from pb.lib.cfg_renderer import cfg_to_dot


def get_cfg_diagram(
    conn: duckdb.DuckDBPyConnection,
    object_name: str,
    proc_name: str,
) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT start_line, end_line, cfg_json FROM procedures WHERE object = ? AND proc_name = ? LIMIT 1",
        [object_name, proc_name],
    ).fetchone()
    if not row:
        return None

    proc_start_line: int | None = row[0]
    cfg_json_raw: str | None = row[2]

    if not cfg_json_raw:
        return None
    cfg = cfg_from_json(json.loads(cfg_json_raw))

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
        "sourceOriginal": None,
        "procStartLine": proc_start_line,
    }


def get_wiring_diagram(
    conn: duckdb.DuckDBPyConnection,
    object_name: str,
    proc_name: str,
) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT start_line, wiring_json FROM procedures WHERE object = ? AND proc_name = ? LIMIT 1",
        [object_name, proc_name],
    ).fetchone()
    if not row:
        return None

    proc_start_line: int | None = row[0]
    wiring_json_raw: str | None = row[1]

    if not wiring_json_raw:
        return None
    payload = json.loads(wiring_json_raw)

    return {
        "term": payload["term"],
        "sharedBlocks": payload.get("sharedBlocks", {}),
        "sourceOriginal": None,
        "procStartLine": proc_start_line,
    }
