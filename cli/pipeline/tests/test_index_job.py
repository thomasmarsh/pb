"""Unit tests for pb.pipeline.index_job.IndexJob -- background-thread index run."""

from __future__ import annotations

import io
import threading
import time
from pathlib import Path

import duckdb
from pb.pipeline.index_job import IndexJob, IndexJobState


def _make_minimal_db(path: str) -> None:
    """Create a minimal DuckDB with the Haskell-native schema tables."""
    conn = duckdb.connect(path)
    conn.execute("CREATE TABLE objects (file TEXT, kind TEXT, object TEXT, ancestor TEXT)")
    conn.execute(
        "CREATE TABLE procedures (file TEXT, object TEXT, proc_name TEXT, proc_type TEXT, "
        "start_line INT, end_line INT, cfg_json TEXT, instr_graph_json TEXT, "
        "params TEXT, return_type TEXT, cyclomatic INT)"
    )
    conn.execute(
        "CREATE TABLE call_sites (file TEXT, object TEXT, from_proc TEXT, to_name TEXT, "
        "call_type TEXT, line INT)"
    )
    conn.execute(
        "CREATE TABLE global_vars (file TEXT, object TEXT, var_name TEXT, var_type TEXT, mods TEXT)"
    )
    conn.execute(
        "CREATE TABLE dw_controls (file TEXT, object TEXT, band TEXT, control_type TEXT, "
        "name TEXT, x INT, y INT, width INT, height INT, expression TEXT)"
    )
    conn.execute(
        "CREATE TABLE dead_code (object TEXT, proc_name TEXT, proc_type TEXT, cyclomatic INT, "
        "confidence TEXT, caller_count_naive INT, caller_count_scoped INT)"
    )
    conn.execute(
        "CREATE TABLE sql_statements (file TEXT, object TEXT, proc_name TEXT, line INT, "
        "operation TEXT, tables TEXT, columns TEXT, raw_sql TEXT, parse_ok BOOLEAN)"
    )
    conn.close()


class _FakePopen:
    """Minimal Popen stand-in, mirrors test_shell_pipeline.py's _FakePopen but
    supports a `gate` Event so a test can hold pbc "running" until it has
    inspected mid-run state."""

    def __init__(self, returncode: int, stderr_lines: list[bytes] = [], gate: threading.Event | None = None) -> None:
        self._returncode = returncode
        self.stderr = io.BytesIO(b"".join(line + b"\n" for line in stderr_lines))
        self.returncode: int | None = None
        self._gate = gate

    def wait(self) -> None:
        if self._gate is not None:
            self._gate.wait(timeout=5)
        self.returncode = self._returncode


def _wait_until(predicate, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("condition not met within timeout")


def test_index_job_starts_in_running_state(monkeypatch, tmp_path):
    gate = threading.Event()

    def fake_popen(args, **kwargs):
        return _FakePopen(returncode=0, gate=gate)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    src_dir = tmp_path / "src"
    src_dir.mkdir()
    job = IndexJob(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"))
    job.start()
    try:
        assert job.done is False
        assert job.snapshot()["job_status"] == IndexJobState.RUNNING.value
    finally:
        gate.set()


def test_index_job_snapshot_reflects_partial_progress_while_running(monkeypatch, tmp_path):
    gate = threading.Event()
    step_line = b'{"tag":"step","label":"Parsing","since_start_ms":1.0}'

    def fake_popen(args, **kwargs):
        return _FakePopen(returncode=0, stderr_lines=[step_line], gate=gate)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    src_dir = tmp_path / "src"
    src_dir.mkdir()
    job = IndexJob(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"))
    job.start()
    try:
        _wait_until(lambda: job.snapshot().get("current") is not None)
        snap = job.snapshot()
        assert snap["current"]["label"] == "Parsing"
    finally:
        gate.set()


def test_index_job_completes_and_swaps_db_on_success(monkeypatch, tmp_path):
    db_path = str(tmp_path / "out.duckdb")

    def fake_popen(args, **kwargs):
        new_path = args[args.index("--db") + 1]
        _make_minimal_db(new_path)
        done_line = b'{"tag":"done","parsed":5,"errors":0}'
        return _FakePopen(returncode=0, stderr_lines=[done_line])

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    src_dir = tmp_path / "src"
    src_dir.mkdir()
    job = IndexJob(src_dir, db_path, Path("/fake/bin"))
    job.start()

    _wait_until(lambda: job.done)

    assert job.error is None
    assert job.snapshot()["job_status"] == IndexJobState.DONE.value
    assert Path(db_path).exists(), "final DB file should exist after rename"
    assert not Path(db_path + ".new").exists(), ".new file should be removed after rename"


def test_index_job_marks_error_status_on_pbc_failure(monkeypatch, tmp_path):
    def fake_popen(args, **kwargs):
        return _FakePopen(returncode=1, stderr_lines=[b"crash"])

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    src_dir = tmp_path / "src"
    src_dir.mkdir()
    job = IndexJob(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"))
    job.start()

    _wait_until(lambda: job.done)

    assert job.error is not None
    assert job.snapshot()["job_status"] == IndexJobState.ERROR.value


def test_index_job_marks_error_status_on_unexpected_exception(monkeypatch, tmp_path):
    def fake_popen(args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    src_dir = tmp_path / "src"
    src_dir.mkdir()
    job = IndexJob(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"))
    job.start()

    _wait_until(lambda: job.done)

    assert job.error is not None and "boom" in job.error
    assert job.snapshot()["job_status"] == IndexJobState.ERROR.value


def test_index_job_snapshot_readable_concurrently_from_another_thread(monkeypatch, tmp_path):
    gate = threading.Event()
    step_lines = [f'{{"tag":"step","label":"L{i}","since_start_ms":{float(i)}}}'.encode() for i in range(20)]

    def fake_popen(args, **kwargs):
        return _FakePopen(returncode=0, stderr_lines=step_lines, gate=gate)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    src_dir = tmp_path / "src"
    src_dir.mkdir()
    job = IndexJob(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"))
    job.start()

    errors: list[Exception] = []

    def reader() -> None:
        try:
            for _ in range(50):
                job.snapshot()
        except Exception as e:  # noqa: BLE001 - captured for the assertion below
            errors.append(e)

    threads = [threading.Thread(target=reader) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=5)

    gate.set()
    _wait_until(lambda: job.done)

    assert errors == []


def test_index_job_diagnostics_report_written_when_path_given(monkeypatch, tmp_path):
    db_path = str(tmp_path / "out.duckdb")
    report_path = str(tmp_path / "diag")

    def fake_popen(args, **kwargs):
        new_path = args[args.index("--db") + 1]
        _make_minimal_db(new_path)
        done_line = b'{"tag":"done","parsed":5,"errors":0}'
        return _FakePopen(returncode=0, stderr_lines=[done_line])

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    src_dir = tmp_path / "src"
    src_dir.mkdir()
    job = IndexJob(src_dir, db_path, Path("/fake/bin"), diagnostics_report_path=report_path)
    job.start()

    _wait_until(lambda: job.done)

    assert Path(report_path + ".json").exists()
    assert Path(report_path + ".html").exists()
