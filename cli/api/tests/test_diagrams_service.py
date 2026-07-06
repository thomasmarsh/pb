"""Unit tests for pb.api.services.diagrams — get_wiring_diagram."""

from __future__ import annotations

import duckdb
from pb.api.services.diagrams import get_wiring_diagram


def test_get_wiring_diagram_happy_path(db_conn: duckdb.DuckDBPyConnection):
    row = db_conn.execute(
        "SELECT object, proc_name FROM procedures WHERE wiring_json IS NOT NULL LIMIT 1"
    ).fetchone()
    assert row is not None, "no procedures with wiring_json in fixture corpus"
    object_name, proc_name = row

    result = get_wiring_diagram(db_conn, object_name, proc_name)

    assert result is not None
    assert "tag" in result["term"]
    assert isinstance(result["sharedBlocks"], dict)
    assert result["sourceOriginal"] is None
    assert "procStartLine" in result


def test_get_wiring_diagram_missing_procedure(db_conn: duckdb.DuckDBPyConnection):
    assert get_wiring_diagram(db_conn, "__nonexistent_object__", "__nonexistent_proc__") is None


def test_get_wiring_diagram_null_wiring(tmp_path):
    db_path = str(tmp_path / "null_wiring.duckdb")
    conn = duckdb.connect(db_path)
    conn.execute(
        "CREATE TABLE procedures (object TEXT, proc_name TEXT, start_line INT, wiring_json TEXT)"
    )
    conn.execute(
        "INSERT INTO procedures VALUES (?, ?, ?, ?)",
        ["w_obj", "of_no_wiring", 1, None],
    )

    assert get_wiring_diagram(conn, "w_obj", "of_no_wiring") is None
