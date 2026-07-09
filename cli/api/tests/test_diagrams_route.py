"""Route-level tests for the Plan 159 async diagram job endpoints:
GET /api/diagram/{kind}?async=1, GET /api/diagram-jobs/{jobId},
GET /api/diagrams/cfg/{object}/{proc}?async=1.
"""

from __future__ import annotations

import time

import duckdb
from fastapi.testclient import TestClient
from pb.api import create_app


def _poll_until_done(client: TestClient, job_id: str, timeout: float = 10.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = client.get(f"/api/diagram-jobs/{job_id}")
        assert r.status_code == 200
        envelope = r.json()
        if envelope["status"] != "pending":
            return envelope
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish within {timeout}s")


def test_get_diagram_async_returns_job_envelope(schema_db_path: str):
    app = create_app(schema_db_path)
    client = TestClient(app)

    r = client.get("/api/diagram/heatmap?async=1")
    assert r.status_code == 200
    envelope = r.json()
    assert envelope["status"] in ("pending", "done")
    if envelope["status"] == "pending":
        assert isinstance(envelope["jobId"], str) and envelope["jobId"]
    else:
        assert "<svg" in envelope["result"] or "<?xml" in envelope["result"]


def test_get_diagram_job_endpoint_round_trip(schema_db_path: str):
    app = create_app(schema_db_path)
    client = TestClient(app)

    r = client.get("/api/diagram/heatmap?async=1")
    envelope = r.json()
    job_id = envelope.get("jobId")
    if job_id is None:
        return  # already served from cache; nothing to poll

    done = _poll_until_done(client, job_id)
    assert done["status"] == "done"
    assert "<svg" in done["result"] or "<?xml" in done["result"]


def test_get_diagram_job_endpoint_unknown_id_404(schema_db_path: str):
    app = create_app(schema_db_path)
    client = TestClient(app)

    r = client.get("/api/diagram-jobs/no-such-job")
    assert r.status_code == 404


def test_get_cfg_diagram_async_returns_job_envelope(db_path: str):
    conn = duckdb.connect(db_path, read_only=True)
    row = conn.execute(
        "SELECT object, proc_name FROM procedures WHERE cfg_json IS NOT NULL LIMIT 1"
    ).fetchone()
    conn.close()
    assert row is not None, "no procedures with cfg_json in fixture corpus"
    object_name, proc_name = row

    app = create_app(db_path)
    client = TestClient(app)

    r = client.get(f"/api/diagrams/cfg/{object_name}/{proc_name}?async=1")
    assert r.status_code == 200
    envelope = r.json()
    assert envelope["status"] == "pending"
    job_id = envelope["jobId"]

    done = _poll_until_done(client, job_id)
    assert done["status"] == "done"
    assert "svg" in done["result"]
