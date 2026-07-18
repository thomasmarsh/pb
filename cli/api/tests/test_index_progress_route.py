"""Route-level tests for Plan 181 Phase 3's live index-progress endpoint and
the SPA-fallback conditional that serves progress.html while an IndexJob is
attached and running, on both the root `/` route (routes/static.py) and the
catch-all deep-link route (app.py)."""

from __future__ import annotations

from fastapi.testclient import TestClient
from pb.api import create_app


class _FakeIndexJob:
    """Minimal stand-in for pb.pipeline.index_job.IndexJob — exercises the
    route/SPA-fallback contract (.snapshot(), .done) without spawning a real
    background pbc subprocess."""

    def __init__(self, snapshot: dict, *, done: bool) -> None:
        self._snapshot = snapshot
        self.done = done

    def snapshot(self) -> dict:
        return self._snapshot


_RUNNING_SNAPSHOT = {
    "status": "running",
    "job_status": "running",
    "error": None,
    "elapsed_ms": 1234.5,
    "timeline_html": "<svg></svg>",
    "steps": [],
    "current": {"label": "Parsing & indexing", "elapsed_ms": 500.0},
    "workers": [],
}


def test_index_progress_no_job_returns_inactive():
    app = create_app()
    client = TestClient(app)

    r = client.get("/api/index-progress")
    assert r.status_code == 200
    assert r.json() == {"active": False}


def test_index_progress_returns_job_snapshot():
    app = create_app()
    app.state.index_job = _FakeIndexJob(_RUNNING_SNAPSHOT, done=False)
    client = TestClient(app)

    r = client.get("/api/index-progress")
    assert r.status_code == 200
    body = r.json()
    assert body["active"] is True
    assert body["job_status"] == "running"
    assert body["current"]["label"] == "Parsing & indexing"


def test_spa_root_serves_progress_page_while_job_running():
    app = create_app()
    app.state.index_job = _FakeIndexJob(_RUNNING_SNAPSHOT, done=False)
    client = TestClient(app)

    r = client.get("/")
    assert r.status_code == 200
    assert 'id="app"' not in r.text
    assert "/api/index-progress" in r.text


def test_spa_root_serves_index_when_job_done():
    app = create_app()
    app.state.index_job = _FakeIndexJob({**_RUNNING_SNAPSHOT, "job_status": "done"}, done=True)
    client = TestClient(app)

    r = client.get("/")
    assert r.status_code == 200
    assert 'id="app"' in r.text


def test_spa_root_serves_index_when_no_job():
    app = create_app()
    client = TestClient(app)

    r = client.get("/")
    assert r.status_code == 200
    assert 'id="app"' in r.text


def test_spa_fallback_path_serves_progress_page_while_job_running():
    app = create_app()
    app.state.index_job = _FakeIndexJob(_RUNNING_SNAPSHOT, done=False)
    client = TestClient(app)

    r = client.get("/objects/Foo")
    assert r.status_code == 200
    assert 'id="app"' not in r.text
    assert "/api/index-progress" in r.text
