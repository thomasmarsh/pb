"""Route-level tests for live index-progress endpoint (polling + SSE) and
the SPA-fallback conditional that serves progress.html while an IndexJob is
attached and running, on both the root `/` route (routes/static.py) and the
catch-all deep-link route (app.py).

Also tests the DiagnosticsCollector subscriber lifecycle (subscribe, broadcast,
unsubscribe) which underpins the SSE endpoint."""

from __future__ import annotations

import queue

from fastapi.testclient import TestClient
from pb.api import create_app
from pb.pipeline.reporter import DiagnosticsCollector


class _FakeCollector:
    """Minimal stand-in for DiagnosticsCollector — supports subscribe/unsubscribe."""

    def __init__(self, snapshot: dict) -> None:
        self._snapshot = snapshot
        self._subscribers: list[queue.Queue] = []

    def snapshot(self) -> dict:
        return self._snapshot

    def subscribe(self, q: queue.Queue) -> None:
        self._subscribers.append(q)

    def unsubscribe(self, q: queue.Queue) -> None:
        self._subscribers = [s for s in self._subscribers if s is not q]


class _FakeIndexJob:
    """Minimal stand-in for pb.pipeline.index_job.IndexJob — exercises the
    route/SPA-fallback contract (.snapshot(), .done) without spawning a real
    background pbc subprocess."""

    def __init__(self, snapshot: dict, *, done: bool) -> None:
        self._snapshot = snapshot
        self.done = done
        self._collector = _FakeCollector(snapshot)

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
    assert "/api/index-events" in r.text


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
    assert "/api/index-events" in r.text


def test_sse_no_job_returns_inactive():
    app = create_app()
    client = TestClient(app)

    r = client.get("/api/index-events")
    assert r.status_code == 200
    assert "text/event-stream" in r.headers["content-type"]
    assert '"active": false' in r.text


# ── DiagnosticsCollector subscriber lifecycle ──────────────────────────────


def test_collector_subscriber_receives_snapshots():
    """on_event() broadcasts a snapshot to every subscriber."""
    c = DiagnosticsCollector()
    q = queue.Queue(maxsize=16)
    c.subscribe(q)

    c.on_event({"tag": "step", "label": "parse", "since_start_ms": 100})
    snap = q.get_nowait()
    assert snap["status"] == "running"
    assert snap["current"]["label"] == "parse"

    c.on_event({"tag": "step", "label": "parse", "elapsed_ms": 500})
    snap = q.get_nowait()
    completed = [s for s in snap["steps"] if s["label"] == "parse"]
    assert len(completed) == 1
    assert completed[0]["elapsed_ms"] == 500


def test_collector_unsubscribe_stops_broadcasts():
    """After unsubscribe, no further snapshots are delivered."""
    c = DiagnosticsCollector()
    q = queue.Queue(maxsize=16)
    c.subscribe(q)
    c.unsubscribe(q)

    c.on_event({"tag": "step", "label": "x", "since_start_ms": 0})
    assert q.empty()


def test_collector_multiple_subscribers():
    """All subscribers receive the same snapshot."""
    c = DiagnosticsCollector()
    q1 = queue.Queue(maxsize=16)
    q2 = queue.Queue(maxsize=16)
    c.subscribe(q1)
    c.subscribe(q2)

    c.on_event({"tag": "step", "label": "a", "since_start_ms": 0})
    assert not q1.empty()
    assert not q2.empty()
    s1 = q1.get_nowait()
    s2 = q2.get_nowait()
    assert s1["current"]["label"] == s2["current"]["label"] == "a"


def test_collector_slow_subscriber_dropped():
    """A full queue doesn't block other subscribers or the pipeline thread."""
    c = DiagnosticsCollector()
    slow = queue.Queue(maxsize=1)
    fast = queue.Queue(maxsize=16)
    c.subscribe(slow)
    c.subscribe(fast)

    # Fill the slow queue
    c.on_event({"tag": "step", "label": "a", "since_start_ms": 0})
    # Second event: slow is full, should not raise
    c.on_event({"tag": "step", "label": "b", "since_start_ms": 100})
    # Fast subscriber still gets both events (drained in order)
    assert fast.get_nowait()["current"]["label"] == "a"
    assert fast.get_nowait()["current"]["label"] == "b"


def test_collector_finish_sends_done_sentinel():
    """finish() pushes a {'tag': 'done'} sentinel to all subscribers."""
    c = DiagnosticsCollector()
    q = queue.Queue(maxsize=16)
    c.subscribe(q)

    c.finish()
    sentinel = q.get_nowait()
    assert sentinel == {"tag": "done"}
