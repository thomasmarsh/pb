"""DuckDB I/O for intra-procedural data flow tables.

The analysis is computed in Haskell by PB.Pipeline.Dataflow (Pass 6) and
written to proc_defs.json / proc_uses.json in the runner output directory.
This module reads those files and bulk-inserts into DuckDB proc_defs / proc_uses.

Called after type resolution in the `pb index` pipeline.
"""

from __future__ import annotations

import json
from pathlib import Path

from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn

_COLUMNS = [
    "file", "object", "proc_name",
    "var_name", "block_id", "stmt_index", "line", "kind",
]


def _load_json(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def build_dataflow_tables(conn: Conn, out_dir: Path | None = None) -> None:
    """Bulk-insert proc_defs / proc_uses from Haskell-produced JSON files.

    Reads proc_defs.json and proc_uses.json from out_dir (written by Pass 6).
    When out_dir is None the tables are truncated but left empty.
    """
    conn.execute("TRUNCATE TABLE proc_defs")
    conn.execute("TRUNCATE TABLE proc_uses")

    if out_dir is None:
        return

    def _rows(records: list[dict]) -> list[tuple]:
        return [
            (
                r["file"], r["object"], r["proc_name"],
                r["var_name"], r["block_id"], r["stmt_index"], r.get("line"), r["kind"],
            )
            for r in records
        ]

    defs = _load_json(out_dir / "proc_defs.json")
    uses = _load_json(out_dir / "proc_uses.json")

    bulk_insert(conn, "proc_defs", _COLUMNS, _rows(defs))
    bulk_insert(conn, "proc_uses", _COLUMNS, _rows(uses))
