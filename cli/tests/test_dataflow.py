"""Tests for the dataflow disk-file → DuckDB importer (shell/dataflow.py).

Haskell Pass 6 writes proc_defs.json / proc_uses.json in the runner output
directory. build_dataflow_tables reads those files and bulk-inserts into the
proc_defs / proc_uses DuckDB tables.
"""

from __future__ import annotations

import json

from pb_cli.shell.dataflow import build_dataflow_tables
from pb_cli.shell.db import create_schema, db_connection

_COLS = ["file", "object", "proc_name", "var_name", "block_id", "stmt_index", "line", "kind"]


def _write_json(path, data) -> None:
    path.write_text(json.dumps(data), encoding="utf-8")


def test_build_dataflow_tables_reads_disk_files(tmp_path):
    """Rows from proc_defs.json / proc_uses.json land in proc_defs / proc_uses
    with the full 8-key shape that core/interproc.py and core/slicing.py read."""
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    _write_json(out_dir / "proc_defs.json", [
        {"file": "f.srw", "object": "w_obj", "proc_name": "uf_x",
         "var_name": "li_y", "block_id": "b0", "stmt_index": 0, "line": 3, "kind": "assign"},
    ])
    _write_json(out_dir / "proc_uses.json", [
        {"file": "f.srw", "object": "w_obj", "proc_name": "uf_x",
         "var_name": "a", "block_id": "b0", "stmt_index": 0, "line": 3, "kind": "rhs"},
        {"file": "f.srw", "object": "w_obj", "proc_name": "uf_x",
         "var_name": "li_y", "block_id": "b0", "stmt_index": 1, "line": 4, "kind": "return"},
    ])

    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        build_dataflow_tables(conn, out_dir)

        defs = conn.execute("SELECT * FROM proc_defs ORDER BY var_name").fetchall()
        uses = conn.execute("SELECT * FROM proc_uses ORDER BY var_name, stmt_index").fetchall()

    assert len(defs) == 1
    assert defs[0] == ("f.srw", "w_obj", "uf_x", "li_y", "b0", 0, 3, "assign")
    assert len(uses) == 2
    assert uses[0][:4] == ("f.srw", "w_obj", "uf_x", "a")
    assert uses[1][:4] == ("f.srw", "w_obj", "uf_x", "li_y")
    assert uses[1][7] == "return"


def test_build_dataflow_tables_no_out_dir_leaves_tables_empty(tmp_path):
    """When out_dir is None the tables are truncated but stay empty."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        build_dataflow_tables(conn, None)

        defs_count = conn.execute("SELECT COUNT(*) FROM proc_defs").fetchone()
        uses_count = conn.execute("SELECT COUNT(*) FROM proc_uses").fetchone()
    assert defs_count is not None and defs_count[0] == 0
    assert uses_count is not None and uses_count[0] == 0


def test_build_dataflow_tables_missing_files_leaves_tables_empty(tmp_path):
    """An out_dir with no proc_defs.json / proc_uses.json is treated as zero rows."""
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        build_dataflow_tables(conn, out_dir)

        defs_count = conn.execute("SELECT COUNT(*) FROM proc_defs").fetchone()
        uses_count = conn.execute("SELECT COUNT(*) FROM proc_uses").fetchone()
    assert defs_count is not None and defs_count[0] == 0
    assert uses_count is not None and uses_count[0] == 0


def test_build_dataflow_tables_column_shape(tmp_path):
    """The 8 columns must exactly match what interproc.py and slicing.py read by dict key."""
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    _write_json(out_dir / "proc_defs.json", [
        {"file": "f.srw", "object": "w_obj", "proc_name": "uf_keys",
         "var_name": "x", "block_id": "b0", "stmt_index": 0, "line": 1, "kind": "local_var"},
    ])
    _write_json(out_dir / "proc_uses.json", [
        {"file": "f.srw", "object": "w_obj", "proc_name": "uf_keys",
         "var_name": "y", "block_id": "b0", "stmt_index": 0, "line": 1, "kind": "rhs"},
    ])

    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        build_dataflow_tables(conn, out_dir)

        def_cols = [r[1] for r in conn.execute("PRAGMA table_info('proc_defs')").fetchall()]
        use_cols = [r[1] for r in conn.execute("PRAGMA table_info('proc_uses')").fetchall()]
    assert def_cols == _COLS
    assert use_cols == _COLS
