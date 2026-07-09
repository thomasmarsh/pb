"""Tests for pb.pipeline.diagrams's async job entry points (Plan 159):
submit_diagram_job / get_diagram_job.
"""

import time
from pathlib import Path

import duckdb
import pytest
from pb.pipeline.build import find_repo
from pb.pipeline.diagrams import _svg_cache, get_diagram_job, render_svg, submit_diagram_job

REPO_ROOT = find_repo()
DB_PATH = str(REPO_ROOT / "pb.duckdb")


@pytest.fixture(autouse=True)
def _require_db():
    if not Path(DB_PATH).exists():
        pytest.skip(f"pb.duckdb not found at {DB_PATH} — run `pb index` + `pb analyze` first")


def _wait_for_done(job_id: str, timeout: float = 10.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        envelope = get_diagram_job(job_id)
        assert envelope is not None
        if envelope["status"] != "pending":
            return envelope
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not finish within {timeout}s")


def test_submit_diagram_job_cache_hit_returns_done_without_job():
    _svg_cache.clear()
    conn = duckdb.connect(DB_PATH, read_only=True)
    svg = render_svg("heatmap", conn)
    conn.close()

    envelope = submit_diagram_job("heatmap", DB_PATH)
    assert envelope == {"status": "done", "result": svg}


def test_submit_diagram_job_new_params_returns_pending_then_done():
    _svg_cache.clear()
    envelope = submit_diagram_job("heatmap", DB_PATH)
    assert envelope["status"] == "pending"
    assert isinstance(envelope["jobId"], str) and envelope["jobId"]

    done = _wait_for_done(envelope["jobId"])
    assert done["status"] == "done"
    assert "<svg" in done["result"] or "<?xml" in done["result"]


def test_get_diagram_job_unknown_id_returns_none():
    assert get_diagram_job("no-such-job") is None
