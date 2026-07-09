"""Generic in-memory background job registry (Plan 159).

Reusable subsystem: no diagram-specific knowledge. A caller submits a
zero-arg callable under a dedup key; the registry runs it on a small thread
pool and lets any caller poll for the result by job id. Mirrors
`pb.pipeline.diagrams._svg_cache`'s OrderedDict-with-eviction pattern for the
job table itself -- a single-user local tool does not need persistence
across process restarts.
"""

from __future__ import annotations

import threading
import uuid
from collections import OrderedDict
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from enum import Enum
from typing import Any


class JobStatus(str, Enum):
    PENDING = "pending"
    DONE = "done"
    ERROR = "error"


@dataclass
class Job:
    id: str
    key: str
    status: JobStatus = JobStatus.PENDING
    result: Any = None
    error: str | None = None


class JobRegistry:
    """Submits keyed work to a thread pool; dedups in-flight work by key."""

    def __init__(self, max_workers: int = 2, max_jobs: int = 128) -> None:
        self._executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="job")
        self._max_jobs = max_jobs
        self._lock = threading.Lock()
        self._jobs_by_id: OrderedDict[str, Job] = OrderedDict()
        self._jobs_by_key: dict[str, str] = {}

    def submit(self, key: str, fn: Callable[[], Any]) -> str:
        """Return a job id. Attaches to an existing PENDING job for `key`
        instead of starting a duplicate render."""
        with self._lock:
            existing_id = self._jobs_by_key.get(key)
            if existing_id is not None:
                existing = self._jobs_by_id.get(existing_id)
                if existing is not None and existing.status == JobStatus.PENDING:
                    return existing_id

            job_id = uuid.uuid4().hex
            self._jobs_by_id[job_id] = Job(id=job_id, key=key)
            self._jobs_by_key[key] = job_id
            self._evict_locked()

        self._executor.submit(self._run, job_id, fn)
        return job_id

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs_by_id.get(job_id)

    def _run(self, job_id: str, fn: Callable[[], Any]) -> None:
        try:
            result = fn()
            status, result_value, error = JobStatus.DONE, result, None
        except Exception as e:  # noqa: BLE001 - reported via the job's error field, not re-raised
            status, result_value, error = JobStatus.ERROR, None, str(e)

        with self._lock:
            job = self._jobs_by_id.get(job_id)
            if job is None:
                return  # evicted before it finished
            job.status = status
            job.result = result_value
            job.error = error
            if self._jobs_by_key.get(job.key) == job_id:
                del self._jobs_by_key[job.key]

    def _evict_locked(self) -> None:
        """Caller must hold `self._lock`."""
        while len(self._jobs_by_id) > self._max_jobs:
            oldest_id, oldest_job = next(iter(self._jobs_by_id.items()))
            del self._jobs_by_id[oldest_id]
            if self._jobs_by_key.get(oldest_job.key) == oldest_id:
                del self._jobs_by_key[oldest_job.key]
