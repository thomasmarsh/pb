"""DuckDB I/O for intra-procedural data flow tables.

The analysis itself is computed in Haskell by PB.Pipeline.Dataflow and
delivered per-procedure as a `dataflow` facet in the parsed JSON
(`{"defs": [...], "uses": [...]}`), which import_file stores on each
procedures row as `dataflow_json`. This module just unpacks that facet
into the proc_defs / proc_uses tables — it does no analysis of its own.

Called after type resolution in the `pb index` pipeline.
"""

from __future__ import annotations

import json

from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn

_COLUMNS = [
    "file", "object", "proc_name",
    "var_name", "block_id", "stmt_index", "line", "kind",
]


def build_dataflow_tables(conn: Conn) -> None:
    """Unpack the per-procedure dataflow facet into proc_defs / proc_uses.

    The facet is emitted by Haskell (wrapSrFile → analyzeProcedure), so this
    is a pure bulk-insert: no CFG rebuild, no per-row analysis. The row shape
    matches the schema exactly and is what core/interproc.py and
    core/slicing.py read by dict key.
    """
    # Schema migration: existing databases predate the dataflow_json column.
    conn.execute("ALTER TABLE procedures ADD COLUMN IF NOT EXISTS dataflow_json TEXT")
    conn.execute("TRUNCATE TABLE proc_defs")
    conn.execute("TRUNCATE TABLE proc_uses")

    rows = conn.execute(
        "SELECT file, object, name, dataflow_json "
        "FROM procedures WHERE dataflow_json IS NOT NULL"
    ).fetchall()

    all_defs: list[tuple] = []
    all_uses: list[tuple] = []

    for file_path, obj, name, dataflow_json_str in rows:
        facet = (
            json.loads(dataflow_json_str)
            if isinstance(dataflow_json_str, str)
            else dataflow_json_str
        )
        if not isinstance(facet, dict):
            continue
        for d in facet.get("defs", []):
            all_defs.append((
                file_path, obj, name,
                d["var_name"], d["block_id"], d["stmt_index"], d.get("line"), d["kind"],
            ))
        for u in facet.get("uses", []):
            all_uses.append((
                file_path, obj, name,
                u["var_name"], u["block_id"], u["stmt_index"], u.get("line"), u["kind"],
            ))

    bulk_insert(conn, "proc_defs", _COLUMNS, all_defs)
    bulk_insert(conn, "proc_uses", _COLUMNS, all_uses)
