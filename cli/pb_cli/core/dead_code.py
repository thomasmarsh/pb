"""Dead code reachability analysis — pure BFS over a call graph.

Pure module — no I/O, no DuckDB.

Public API:
    compute_dead_procedures(procedures, calls, resolved, inherits, dw_objects)
        -> list[DeadProcedure]
"""

from __future__ import annotations

from collections import defaultdict, deque
from typing import NamedTuple


class DeadProcedure(NamedTuple):
    object: str
    name: str
    proc_type: str
    cyclomatic: int | None
    confidence: str  # 'high' | 'medium' | 'low'
    caller_count_naive: int
    caller_count_scoped: int


def compute_dead_procedures(
    procedures: list[tuple[str, str, str, int | None]],
    calls: list[tuple[str, str, str]],
    resolved: list[tuple[str, str, str, str]],
    inherits: list[tuple[str, str]],
    dw_objects: set[str],
) -> list[DeadProcedure]:
    """Compute unreachable procedures via BFS from entry points.

    Args:
        procedures: (object, name, proc_type, cyclomatic)
        calls: (object, from_proc, to_name)
        resolved: (object, from_proc, target_object, target_proc)
        inherits: (from_object, to_object)
        dw_objects: set of DataWindow object names

    Returns:
        Sorted list of dead procedures with confidence classification.
    """
    # Index procedures by (object, name)
    proc_index: dict[tuple[str, str], tuple[str, int | None]] = {}
    for obj, name, ptype, cc in procedures:
        proc_index[(obj, name)] = (ptype, cc)

    # Build same-object edges: caller -> callee when callee lives in same object.
    # Case-insensitive: lower(to_name) matches lower(procedure name).
    same_obj_by_proc: dict[tuple[str, str], list[tuple[str, str]]] = defaultdict(list)
    # Index procedure names by object for efficient lookup
    procs_by_obj: dict[str, dict[str, str]] = defaultdict(dict)
    for (p_obj, p_name) in proc_index:
        procs_by_obj[p_obj][p_name.lower()] = p_name

    for obj, from_proc, to_name in calls:
        name_map = procs_by_obj.get(obj)
        if name_map:
            matched = name_map.get(to_name.lower())
            if matched:
                same_obj_by_proc[(obj, from_proc)].append((obj, matched))

    # Build cross-object edges from resolved_calls.
    cross_obj: dict[tuple[str, str], list[tuple[str, str]]] = defaultdict(list)
    for obj, from_proc, tgt_obj, tgt_proc in resolved:
        cross_obj[(obj, from_proc)].append((tgt_obj, tgt_proc))

    # Build override edges: if parent.m is reachable, child.m (override) is too.
    children_of: dict[str, list[str]] = defaultdict(list)
    for child, parent in inherits:
        children_of[parent].append(child)

    methods_by_obj: dict[str, set[str]] = defaultdict(set)
    for (obj, name) in proc_index:
        methods_by_obj[obj].add(name)

    override_edges: dict[tuple[str, str], list[tuple[str, str]]] = defaultdict(list)
    for parent_obj, methods in methods_by_obj.items():
        for child_obj in children_of.get(parent_obj, []):
            for method in methods:
                if (child_obj, method) in proc_index:
                    override_edges[(parent_obj, method)].append((child_obj, method))

    # Combine all edges into adjacency list.
    edges: dict[tuple[str, str], list[tuple[str, str]]] = defaultdict(list)
    for key, targets in same_obj_by_proc.items():
        edges[key].extend(targets)
    for key, targets in cross_obj.items():
        edges[key].extend(targets)
    for key, targets in override_edges.items():
        edges[key].extend(targets)

    # Seed 1: event and on handlers are always reachable.
    seeds: set[tuple[str, str]] = set()
    for obj, name, ptype, _cc in procedures:
        if ptype in ("event", "on"):
            seeds.add((obj, name))

    # Seed 2: procedures in DW objects that have calls are reachable.
    for obj, from_proc, _to_name in calls:
        if obj in dw_objects:
            seeds.add((obj, from_proc))

    # BFS from seeds.
    reachable: set[tuple[str, str]] = set()
    queue: deque[tuple[str, str]] = deque()
    for seed in seeds:
        if seed not in reachable:
            reachable.add(seed)
            queue.append(seed)

    while queue:
        current = queue.popleft()
        for neighbor in edges.get(current, ()):
            if neighbor not in reachable:
                reachable.add(neighbor)
                queue.append(neighbor)

    # Compute caller counts for dead procedures.
    naive_map: dict[str, set[tuple[str, str]]] = defaultdict(set)
    for obj, from_proc, to_name in calls:
        naive_map[to_name.lower()].add((obj, from_proc))

    scoped_map: dict[tuple[str, str], int] = defaultdict(int)
    for _obj, _from_proc, tgt_obj, tgt_proc in resolved:
        scoped_map[(tgt_obj, tgt_proc)] += 1

    # Collect dead procedures.
    dead: list[DeadProcedure] = []
    for (obj, name), (ptype, cc) in proc_index.items():
        if (obj, name) in reachable:
            continue
        naive = len(naive_map.get(name.lower(), set()))
        scoped = scoped_map.get((obj, name), 0)
        if naive == 0:
            confidence = "high"
        elif scoped == 0:
            confidence = "medium"
        else:
            confidence = "low"
        dead.append(DeadProcedure(obj, name, ptype, cc, confidence, naive, scoped))

    dead.sort(key=lambda d: (d.object, d.name))
    return dead
