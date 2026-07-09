"""Unit tests for pb.api.services.diagrams — get_wiring_diagram, get_cfg_diagram."""

from __future__ import annotations

import os

import duckdb
import graphviz
from pb.api.services.diagrams import get_cfg_diagram, get_wiring_diagram
from pb.pipeline.diagrams import _PLACEHOLDER_SVG


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


def test_get_diagram_route_window_table_lattice(schema_db_path: str):
    """Regression: `/api/diagram/{kind}` has its own `_KINDS` allowlist,
    separate from `pb.pipeline.diagrams.render_svg`'s `builders` dict --
    adding a new diagram kind to one without the other 400s at the route
    layer even though `render_svg` itself supports it (caught manually
    while browser-testing Plan 153 D7)."""
    from fastapi.testclient import TestClient
    from pb.api import create_app

    app = create_app(schema_db_path)
    client = TestClient(app)

    r = client.get("/api/diagram/window-table-lattice")
    assert r.status_code == 200
    assert "<svg" in r.text or "<?xml" in r.text


# ---------------------------------------------------------------------------
# get_cfg_diagram must never let a graphviz render failure escape as an
# exception -- it should get the same placeholder-SVG guarantee as
# pb.pipeline.diagrams.render_svg (regression: this path was never wired
# through that guarantee, so a triangulation-library-less `dot` build took
# the whole endpoint down uncaught).
# ---------------------------------------------------------------------------


def test_get_cfg_diagram_returns_placeholder_on_render_failure(monkeypatch, db_conn):
    def _raise(self, format):  # noqa: A002
        raise graphviz.backend.execute.CalledProcessError(1, ["dot"])

    monkeypatch.setattr(graphviz.Digraph, "pipe", _raise)

    row = db_conn.execute(
        "SELECT object, proc_name FROM procedures WHERE cfg_json IS NOT NULL LIMIT 1"
    ).fetchone()
    assert row is not None, "no procedures with cfg_json in fixture corpus"
    object_name, proc_name = row

    result = get_cfg_diagram(db_conn, object_name, proc_name)

    assert result is not None
    assert result["svg"] == _PLACEHOLDER_SVG


def test_get_cfg_diagram_survives_real_dot_subprocess_failure(monkeypatch, db_conn, tmp_path):
    """Same guarantee as test_get_cfg_diagram_returns_placeholder_on_render_failure,
    but through a REAL failing `dot` subprocess on PATH (simulating a graphviz
    build missing the triangulation library) rather than a monkeypatched
    graphviz.Digraph.pipe -- exercises the actual subprocess.run ->
    graphviz.backend.execute.CalledProcessError path the fix guards against."""
    fake_dot = tmp_path / "dot"
    fake_dot.write_text(
        "#!/bin/sh\n"
        'echo "Error: remove_overlap: Graphviz not built with triangulation library" >&2\n'
        "exit 1\n"
    )
    fake_dot.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])

    row = db_conn.execute(
        "SELECT object, proc_name FROM procedures WHERE cfg_json IS NOT NULL LIMIT 1"
    ).fetchone()
    assert row is not None, "no procedures with cfg_json in fixture corpus"
    object_name, proc_name = row

    result = get_cfg_diagram(db_conn, object_name, proc_name)

    assert result is not None
    assert result["svg"] == _PLACEHOLDER_SVG


def test_get_cfg_diagram_endpoint_returns_503_on_executable_not_found(monkeypatch, db_path):
    def _raise(self, format):  # noqa: A002
        raise graphviz.backend.execute.ExecutableNotFound(["dot"])

    monkeypatch.setattr(graphviz.Digraph, "pipe", _raise)

    conn = duckdb.connect(db_path, read_only=True)
    row = conn.execute(
        "SELECT object, proc_name FROM procedures WHERE cfg_json IS NOT NULL LIMIT 1"
    ).fetchone()
    conn.close()
    assert row is not None, "no procedures with cfg_json in fixture corpus"
    object_name, proc_name = row

    from fastapi.testclient import TestClient
    from pb.api import create_app

    app = create_app(db_path)
    client = TestClient(app)

    r = client.get(f"/api/diagrams/cfg/{object_name}/{proc_name}")
    assert r.status_code == 503
