"""DuckDB I/O for taint analysis tables — bulk-inserts from Haskell-produced JSON.

Pass 7 of the Haskell pipeline (writeTaintAnalysis) produces:
  taint_sources.json, taint_sinks.json, taint_paths.json, taint_annotations.json

This module reads those files and bulk-inserts into DuckDB.
"""

from __future__ import annotations

import json
from pathlib import Path

from pb_cli.shell.bulk import bulk_insert
from pb_cli.shell.db import Conn


def build_taint_tables(conn: Conn, out_dir: Path | None = None) -> None:
    """Bulk-insert taint analysis results from Haskell-produced JSON."""
    conn.execute("TRUNCATE TABLE taint_sources")
    conn.execute("TRUNCATE TABLE taint_sinks")
    conn.execute("TRUNCATE TABLE taint_paths")
    conn.execute("TRUNCATE TABLE taint_annotations")

    if out_dir is None:
        return

    _bulk_insert_taint_sources(conn, out_dir)
    _bulk_insert_taint_sinks(conn, out_dir)
    _bulk_insert_taint_paths(conn, out_dir)
    _bulk_insert_taint_annotations(conn, out_dir)


def _load_json(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8"))


def _bulk_insert_taint_sources(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "taint_sources.json")
    if not rows:
        return
    bulk_insert(conn, "taint_sources",
        ["file", "object", "proc_name", "var_name", "line", "source_type"],
        [(r["file"], r["object"], r["proc_name"], r["var_name"], r.get("line"), r["source_type"])
         for r in rows],
    )


def _bulk_insert_taint_sinks(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "taint_sinks.json")
    if not rows:
        return
    bulk_insert(conn, "taint_sinks",
        ["file", "object", "proc_name", "var_name", "line", "sink_type", "severity"],
        [(r["file"], r["object"], r["proc_name"], r["var_name"], r.get("line"),
          r["sink_type"], r["severity"])
         for r in rows],
    )


def _bulk_insert_taint_paths(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "taint_paths.json")
    if not rows:
        return
    bulk_insert(conn, "taint_paths",
        [
            "id", "source_object", "source_proc", "source_var", "source_line", "source_type",
            "sink_object", "sink_proc", "sink_var", "sink_line", "sink_type",
            "severity", "category", "steps_json",
        ],
        [
            (
                i,
                p["source"]["object"], p["source"]["proc_name"], p["source"]["var_name"],
                p["source"].get("line"), p["source"]["source_type"],
                p["sink"]["object"], p["sink"]["proc_name"], p["sink"]["var_name"],
                p["sink"].get("line"), p["sink"]["sink_type"],
                p["severity"], p["category"],
                json.dumps(p.get("steps", [])),
            )
            for i, p in enumerate(rows)
        ],
    )


def _bulk_insert_taint_annotations(conn: Conn, out_dir: Path) -> None:
    rows = _load_json(out_dir / "taint_annotations.json")
    if not rows:
        return
    bulk_insert(conn, "taint_annotations",
        ["file", "object", "proc_name", "block_id", "is_taint_entry", "is_taint_sink", "tainted_vars"],
        [
            (
                a["file"], a["object"], a["proc_name"], a["block_id"],
                a["is_taint_entry"], a["is_taint_sink"],
                json.dumps(a["tainted_vars"]),
            )
            for a in rows
        ],
    )
