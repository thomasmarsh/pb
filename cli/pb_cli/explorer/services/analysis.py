"""Dead-code reachability and related analysis queries."""

from __future__ import annotations

from typing import Any

import duckdb

from pb_cli.explorer.routes.dependencies import rows

_DEAD_CODE_SQL = """
WITH RECURSIVE
call_edges(caller_obj, caller_proc, callee_obj, callee_proc) AS (
    -- Same-object calls: callee lives in the same object as the caller
    SELECT c.object, c.from_proc, p2.object, p2.name
    FROM calls c
    JOIN procedures p2 ON p2.object = c.object AND p2.name = c.to_name
    UNION ALL
    -- Cross-object calls: use target_object/target_proc from resolved_calls
    SELECT rc.object, rc.from_proc, rc.target_object, rc.target_proc
    FROM resolved_calls rc
    WHERE rc.target_object IS NOT NULL AND rc.target_proc IS NOT NULL
    UNION ALL
    -- Override edges: if B.m is a call edge target and C inherits from B
    -- and overrides m, add B.m -> C.m so virtual dispatch is modelled.
    SELECT p1.object, p1.name, p2.object, p2.name
    FROM procedures p1
    JOIN inherits inh ON inh.to_object = p1.object
    JOIN procedures p2 ON p2.object = inh.from_object AND p2.name = p1.name
),
reachable(obj, proc) AS (
    -- Seed 1: event/on handlers are always reachable entry points
    SELECT object, name FROM procedures WHERE proc_type IN ('event', 'on')
    UNION
    -- Seed 2: DataWindow compute controls run whenever data is displayed
    SELECT DISTINCT c.object, c.from_proc
    FROM calls c
    WHERE c.object IN (SELECT DISTINCT dw_name FROM dw_controls)
    UNION
    -- Recursive step: follow call edges from all known-reachable nodes
    SELECT e.callee_obj, e.callee_proc
    FROM call_edges e
    JOIN reachable r ON r.obj = e.caller_obj AND r.proc = e.caller_proc
)
SELECT
    p.name,
    p.object,
    p.proc_type,
    p.cyclomatic,
    (SELECT COUNT(DISTINCT c.object || '.' || c.from_proc)
     FROM calls c WHERE c.to_name = p.name) AS caller_count_naive,
    (SELECT COUNT(*)
     FROM resolved_calls rc
     WHERE rc.target_object = p.object AND rc.target_proc = p.name) AS caller_count_scoped
FROM procedures p
WHERE NOT EXISTS (
    SELECT 1 FROM reachable r WHERE r.obj = p.object AND r.proc = p.name
)
ORDER BY p.object, p.name
"""


def get_dead_code(conn: duckdb.DuckDBPyConnection) -> list[dict[str, Any]]:
    return rows(conn.execute(_DEAD_CODE_SQL))
