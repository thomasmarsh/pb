"""Background-thread index run for `pb explore`'s live progress view (Plan 181 Phase 2)."""

from __future__ import annotations

import threading
from collections.abc import Sequence
from enum import Enum
from pathlib import Path
from typing import Any

from pb.pipeline.db import setup_db_extras
from pb.pipeline.env import env
from pb.pipeline.metrics import compute_metrics
from pb.pipeline.pipeline import _prepare_run, _run_pbc
from pb.pipeline.reporter import DiagnosticsCollector, RecordingReporter


class IndexJobState(str, Enum):
    RUNNING = "running"
    DONE = "done"
    ERROR = "error"


class IndexJob:
    """Wraps pipeline.run()'s subprocess-spawn-plus-event-loop body on a
    background thread, feeding events into a live-safe DiagnosticsCollector
    instead of a Rich console reporter. .snapshot() is safe to call from a
    request thread while the background thread is still writing."""

    def __init__(
        self,
        src_dir: Path,
        db: str,
        binary: Path,
        *,
        reset: bool = False,
        dialect: str = "oracle",
        input_path: Path | None = None,
        ddl: Sequence[str] = (),
        default_namespace: str | None = None,
        diagnostics_report_path: str | None = None,
        profile: bool = False,
    ) -> None:
        self._src_dir = src_dir
        self._db = db
        self._binary = binary
        self._reset = reset
        self._dialect = dialect
        self._ddl = ddl
        self._default_namespace = default_namespace
        self._diagnostics_report_path = diagnostics_report_path
        self._profile = profile

        self._collector = DiagnosticsCollector()
        self._state_lock = threading.Lock()
        self._state = IndexJobState.RUNNING
        self._error: str | None = None

    def start(self) -> None:
        threading.Thread(target=self._run, daemon=True).start()

    def snapshot(self) -> dict[str, Any]:
        snap = self._collector.snapshot()
        with self._state_lock:
            snap["job_status"] = self._state.value
            snap["error"] = self._error
        return snap

    @property
    def done(self) -> bool:
        with self._state_lock:
            return self._state != IndexJobState.RUNNING

    @property
    def error(self) -> str | None:
        with self._state_lock:
            return self._error

    def _fail(self, message: str) -> None:
        with self._state_lock:
            self._state = IndexJobState.ERROR
            self._error = message

    def _run(self) -> None:
        try:
            _src_dir, db_new, argv, _default_namespace = _prepare_run(
                self._src_dir, self._db, self._binary, self._reset, self._dialect,
                self._ddl, self._default_namespace, profile=self._profile,
            )

            returncode, raw_stderr_lines = _run_pbc(argv, self._collector.on_event)

            if returncode != 0:
                self._fail(f"pbc failed (exit {returncode}): {'; '.join(raw_stderr_lines)}")
                return

            with env.storage.db_connection(db_new) as conn:
                setup_db_extras(conn)
                conn.execute(
                    "INSERT OR REPLACE INTO metadata VALUES (?, ?)",
                    ["ingestion_root", str(self._src_dir)],
                )
                if _default_namespace:
                    conn.execute(
                        "INSERT OR REPLACE INTO metadata VALUES (?, ?)",
                        ["default_namespace", _default_namespace],
                    )

            Path(db_new).rename(self._db)

            recording = RecordingReporter()
            with env.storage.db_connection(self._db) as conn, recording.analyze_progress() as progress:
                compute_metrics(conn, progress)

            if self._diagnostics_report_path:
                self._collector.write(self._diagnostics_report_path)

            with self._state_lock:
                self._state = IndexJobState.DONE
        except Exception as e:  # noqa: BLE001 - reported via .error, never raised cross-thread
            self._fail(str(e))
        finally:
            self._collector.finish()
