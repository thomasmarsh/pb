"""Plan 153 D7: window x table concept lattice (FCA).

Lives in `pb-pipeline` (not `pb-api`, where D7 originated) because the
diagram-rendering shell (`pb.pipeline.diagrams`) needs the same concepts/
covers computation and `pb-pipeline` cannot depend on `pb-api` (the
dependency runs the other way: `pb-api` already depends on `pb-pipeline`).
Moved verbatim from `pb.api.services.schema`'s `_window_table_pairs`/
`_fca_concepts`/`_fca_covers` -- `get_window_table_lattice` there is now a
thin wrapper over `compute_window_table_lattice` here, so there is exactly
one copy of Ganter's Next Closure, not two.
"""

from __future__ import annotations

import json
from collections import defaultdict
from typing import Any

from pb.pipeline.db import Conn


def _rows(cursor) -> list[dict[str, Any]]:
    cols = [d[0] for d in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]


_WINDOW_DIRECT_SQL_TABLES_SQL = """
    SELECT DISTINCT o.object AS window, a.table_name
    FROM all_sql_tables a JOIN objects o ON o.object = a.object
    WHERE a.source = 'powerscript' AND o.layout_json IS NOT NULL
"""


def window_table_pairs(conn: Conn) -> set[tuple[str, str]]:
    """D7: 'window touches table', direct + DW-control-mediated.

    Direct: a window's own embedded SQL (`all_sql_tables`, restricted to PS
    objects with `layout_json IS NOT NULL` -- the existing window classifier,
    see `extractWindowLayout`). Indirect: a window's DataWindow control (its
    `layout_json.controls[].dataobject`, already captured at parse time) that
    retrieves from a table (`dw_retrieve_tables`). Parsed in Python, not SQL
    -- `json_each` over `objects.layout_json` chokes on the heterogeneous
    control shapes across windows (DuckDB tries to unify a struct type across
    all rows and fails on mismatched fields).
    """
    pairs = {(r["window"], r["table_name"]) for r in _rows(conn.execute(_WINDOW_DIRECT_SQL_TABLES_SQL))}

    dw_to_tables: dict[str, set[str]] = defaultdict(set)
    for r in _rows(conn.execute("SELECT lower(dw_name) AS dw_name, table_name FROM dw_retrieve_tables")):
        dw_to_tables[r["dw_name"]].add(r["table_name"])

    for r in _rows(conn.execute("SELECT object, layout_json FROM objects WHERE layout_json IS NOT NULL")):
        layout = json.loads(r["layout_json"])
        for control in layout.get("controls", []):
            dataobject = control.get("dataobject")
            if dataobject:
                for table in dw_to_tables.get(dataobject.lower(), ()):
                    pairs.add((r["object"], table))

    return pairs


def fca_concepts(
    incidence: dict[str, frozenset[str]], attributes: list[str]
) -> list[tuple[frozenset[str], frozenset[str]]]:
    """Ganter's Next Closure algorithm: every formal concept (extent, intent)
    of the context (incidence, attributes), in lectic order of intent.

    Pure Python, bitmask-encoded (attributes are few enough -- real tables in
    this corpus top out at ~34 -- that this is a same-order-of-magnitude
    rewrite of D3's "no scipy" precedent, not a new dependency). Verified
    against real openpay data three independent ways before landing: every
    returned intent is idempotent under the closure operator, extents are
    pairwise distinct, and unioning every concept's extent x intent
    reconstructs the exact original incidence relation (see
    `test_get_window_table_lattice_concepts_reconstruct_all_pairs`).
    """
    objects = sorted(incidence)
    attr_index = {a: i for i, a in enumerate(attributes)}
    obj_masks = [sum(1 << attr_index[a] for a in incidence[g]) for g in objects]
    full_mask = (1 << len(attributes)) - 1

    def derive_objects(attr_mask: int) -> int:
        return sum(1 << gi for gi, m in enumerate(obj_masks) if (m & attr_mask) == attr_mask)

    def derive_attrs(obj_mask: int) -> int:
        if obj_mask == 0:
            return full_mask
        result = full_mask
        for gi, m in enumerate(obj_masks):
            if obj_mask & (1 << gi):
                result &= m
        return result

    def closure(attr_mask: int) -> int:
        return derive_attrs(derive_objects(attr_mask))

    def next_closure(b: int) -> int | None:
        for i in range(len(attributes) - 1, -1, -1):
            bit = 1 << i
            if b & bit:
                continue
            prefix_mask = bit - 1
            candidate = closure((b & prefix_mask) | bit)
            if (candidate & prefix_mask) == (b & prefix_mask):
                return candidate
        return None

    def mask_to_names(mask: int, names: list[str]) -> frozenset[str]:
        return frozenset(names[i] for i in range(len(names)) if mask & (1 << i))

    intents = [closure(0)]
    while (nxt := next_closure(intents[-1])) is not None:
        intents.append(nxt)

    return [(mask_to_names(derive_objects(b), objects), mask_to_names(b, attributes)) for b in intents]


def fca_covers(concepts: list[tuple[frozenset[str], frozenset[str]]]) -> list[dict[str, int]]:
    """Hasse diagram: `upper` covers `lower` iff lower's extent is a proper
    subset of upper's extent and no third concept's extent sits strictly
    between them. O(n^3) on the concept count, negligible at real corpus
    scale (49 concepts on openpay).
    """
    extents = [ext for ext, _ in concepts]
    n = len(concepts)
    covers: list[dict[str, int]] = []
    for lower in range(n):
        for upper in range(n):
            if lower == upper or not (extents[lower] < extents[upper]):
                continue
            if any(
                extents[lower] < extents[mid] < extents[upper]
                for mid in range(n)
                if mid != lower and mid != upper
            ):
                continue
            covers.append({"upper": upper, "lower": lower})
    return covers


def compute_window_table_lattice(conn: Conn) -> dict[str, Any]:
    """D7: concept lattice over the 'window W touches table T' incidence
    (147 idea 8) -- an architecture-recovery grouping of windows by shared
    table footprint, i.e. a migration-module map candidate.
    """
    pairs = window_table_pairs(conn)
    windows = sorted({w for w, _ in pairs})
    tables = sorted({t for _, t in pairs})
    incidence = {w: frozenset(t for ww, t in pairs if ww == w) for w in windows}

    concepts = fca_concepts(incidence, tables)
    covers = fca_covers(concepts)

    return {
        "windows": windows,
        "tables": tables,
        "pairs": len(pairs),
        "concepts": [{"extent": sorted(ext), "intent": sorted(intent)} for ext, intent in concepts],
        "covers": covers,
    }
