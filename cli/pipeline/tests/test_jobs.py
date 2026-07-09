"""Tests for pb.pipeline.jobs — generic in-memory background job registry (Plan 159)."""

import threading
import time

from pb.pipeline.jobs import JobRegistry, JobStatus


def test_submit_returns_pending_job_id():
    reg = JobRegistry()
    gate = threading.Event()
    job_id = reg.submit("k1", lambda: gate.wait(5) or "done-value")
    assert isinstance(job_id, str) and job_id
    job = reg.get(job_id)
    assert job is not None
    assert job.status == JobStatus.PENDING
    gate.set()


def test_poll_pending_job_returns_pending_status():
    reg = JobRegistry()
    gate = threading.Event()
    job_id = reg.submit("k2", lambda: gate.wait(5))
    job = reg.get(job_id)
    assert job.status == JobStatus.PENDING
    assert job.result is None
    assert job.error is None
    gate.set()


def _wait_for(reg: JobRegistry, job_id: str, status: JobStatus, timeout: float = 5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = reg.get(job_id)
        if job is not None and job.status == status:
            return job
        time.sleep(0.01)
    raise AssertionError(f"job {job_id} did not reach {status} within {timeout}s")


def test_poll_completed_job_returns_done_with_result():
    reg = JobRegistry()
    job_id = reg.submit("k3", lambda: "the-result")
    job = _wait_for(reg, job_id, JobStatus.DONE)
    assert job.result == "the-result"
    assert job.error is None


def test_poll_failed_job_returns_error_with_message():
    reg = JobRegistry()

    def boom():
        raise ValueError("kaboom")

    job_id = reg.submit("k4", boom)
    job = _wait_for(reg, job_id, JobStatus.ERROR)
    assert job.result is None
    assert "kaboom" in job.error


def test_duplicate_key_while_pending_attaches_to_existing_job():
    reg = JobRegistry()
    gate = threading.Event()
    first_id = reg.submit("same-key", lambda: gate.wait(5) or "v")
    second_id = reg.submit("same-key", lambda: gate.wait(5) or "v")
    assert first_id == second_id
    gate.set()


def test_new_submit_after_completion_creates_new_job():
    reg = JobRegistry()
    first_id = reg.submit("k5", lambda: "v1")
    _wait_for(reg, first_id, JobStatus.DONE)
    second_id = reg.submit("k5", lambda: "v2")
    assert second_id != first_id
    job = _wait_for(reg, second_id, JobStatus.DONE)
    assert job.result == "v2"


def test_poll_unknown_job_id_returns_none():
    reg = JobRegistry()
    assert reg.get("no-such-job") is None


def test_eviction_drops_oldest_job_when_over_max_jobs():
    reg = JobRegistry(max_jobs=4)
    ids = []
    for i in range(6):
        job_id = reg.submit(f"key-{i}", lambda: "v")
        _wait_for(reg, job_id, JobStatus.DONE)
        ids.append(job_id)
    assert reg.get(ids[0]) is None
    assert reg.get(ids[1]) is None
    assert reg.get(ids[-1]) is not None
