"""Tests for the dataflow facet → DuckDB unpacker (shell/dataflow.py).

The analysis itself now lives in Haskell (PB.Pipeline.Dataflow); the Python
side only unpacks the per-procedure `dataflow` facet that import_file stored
on the procedures row into the proc_defs / proc_uses tables. These tests
exercise that unpacking plus the schema migration for existing databases.
"""

from __future__ import annotations

import json

from pb_cli.shell.dataflow import build_dataflow_tables
from pb_cli.shell.db import create_schema, db_connection

_COLS = ["file", "object", "proc_name", "var_name", "block_id", "stmt_index", "line", "kind"]


def _make_facet(defs: list[dict], uses: list[dict]) -> str:
    return json.dumps({"defs": defs, "uses": uses})


def _insert_procedure(conn, file: str, obj: str, name: str, dataflow_json: str | None) -> None:
    conn.execute(
        "INSERT INTO procedures VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (file, obj, None, "function", name, None, None, None, None, None, None, "", 1, None, None, dataflow_json),
    )


def test_build_dataflow_tables_unpacks_facet(tmp_path):
    """Defs and uses from the facet land in proc_defs / proc_uses with the
    full 8-key row shape that core/interproc.py and core/slicing.py read."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        _insert_procedure(
            conn, "f.srw", "w_obj", "uf_x",
            _make_facet(
                defs=[
                    {"var_name": "li_y", "block_id": "b0", "stmt_index": 0, "line": 3, "kind": "assign"},
                ],
                uses=[
                    {"var_name": "a", "block_id": "b0", "stmt_index": 0, "line": 3, "kind": "rhs"},
                    {"var_name": "li_y", "block_id": "b0", "stmt_index": 1, "line": 4, "kind": "return"},
                ],
            ),
        )

        build_dataflow_tables(conn)

        defs = conn.execute("SELECT * FROM proc_defs ORDER BY var_name").fetchall()
        uses = conn.execute("SELECT * FROM proc_uses ORDER BY var_name, stmt_index").fetchall()

        assert len(defs) == 1
        assert defs[0] == ("f.srw", "w_obj", "uf_x", "li_y", "b0", 0, 3, "assign")

        assert len(uses) == 2
        assert uses[0][:4] == ("f.srw", "w_obj", "uf_x", "a")
        assert uses[1][:4] == ("f.srw", "w_obj", "uf_x", "li_y")
        assert uses[1][7] == "return"


def test_build_dataflow_tables_skips_null_facet(tmp_path):
    """Procedures without a dataflow facet (dataflow_json IS NULL) contribute
    no rows — the WHERE clause filters them before unpacking."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        _insert_procedure(conn, "f.srw", "w_obj", "uf_empty", None)

        build_dataflow_tables(conn)

        defs_count = conn.execute("SELECT COUNT(*) FROM proc_defs").fetchone()
        uses_count = conn.execute("SELECT COUNT(*) FROM proc_uses").fetchone()
        assert defs_count is not None and defs_count[0] == 0
        assert uses_count is not None and uses_count[0] == 0


def test_build_dataflow_tables_adds_column_to_legacy_schema(tmp_path):
    """Existing databases created before 111d-1 have no dataflow_json column.
    build_dataflow_tables must add it (ALTER ... ADD COLUMN IF NOT EXISTS)
    before selecting, mirroring store_resolved_calls' migration pattern."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        # Simulate a legacy database: drop the new column.
        conn.execute("ALTER TABLE procedures DROP COLUMN dataflow_json")
        cols = {r[1] for r in conn.execute("PRAGMA table_info('procedures')").fetchall()}
        assert "dataflow_json" not in cols

        # The migration must restore it without error.
        build_dataflow_tables(conn)
        cols = {r[1] for r in conn.execute("PRAGMA table_info('procedures')").fetchall()}
        assert "dataflow_json" in cols

        count = conn.execute("SELECT COUNT(*) FROM proc_defs").fetchone()
        assert count is not None
        assert count[0] == 0


def test_build_dataflow_tables_row_keys_match_consumer_shape(tmp_path):
    """The 8 columns must exactly match what interproc.py:237 and
    slicing.py:53 read by dict key — drift here breaks both consumers."""
    db = str(tmp_path / "test.duckdb")
    with db_connection(db) as conn:
        create_schema(conn)
        _insert_procedure(
            conn, "f.srw", "w_obj", "uf_keys",
            _make_facet(
                defs=[{"var_name": "x", "block_id": "b0", "stmt_index": 0, "line": 1, "kind": "local_var"}],
                uses=[{"var_name": "y", "block_id": "b0", "stmt_index": 0, "line": 1, "kind": "rhs"}],
            ),
        )

        build_dataflow_tables(conn)

        def_cols = [r[1] for r in conn.execute("PRAGMA table_info('proc_defs')").fetchall()]
        use_cols = [r[1] for r in conn.execute("PRAGMA table_info('proc_uses')").fetchall()]
        assert def_cols == _COLS
        assert use_cols == _COLS
