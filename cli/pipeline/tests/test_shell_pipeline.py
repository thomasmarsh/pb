"""Unit tests for pb.pipeline.pipeline.run — pbc --db flow."""

from __future__ import annotations

import io
from pathlib import Path

import duckdb
from pb.pipeline.pipeline import run
from pb.pipeline.reporter import RecordingReporter


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
    """Minimal Popen stand-in for pipeline tests."""

    def __init__(self, returncode: int, stderr_lines: list[bytes] = []) -> None:
        self._returncode = returncode
        self.stderr = io.BytesIO(b"".join(line + b"\n" for line in stderr_lines))
        self.returncode: int | None = None

    def wait(self) -> None:
        self.returncode = self._returncode


def test_run_reports_error_on_binary_failure(monkeypatch, tmp_path):
    def fake_popen(args, **kwargs):
        return _FakePopen(returncode=1, stderr_lines=[b"crash"])

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    reporter = RecordingReporter()
    run(tmp_path, str(tmp_path / "out.duckdb"), Path("/fake/bin"), reporter)

    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert len(done) == 1
    assert done[0]["errors"] == 1


def test_run_calls_pb_runner_with_db_flag(monkeypatch, tmp_path):
    called_args: list = []

    def fake_popen(args, **kwargs):
        called_args.extend(args)
        return _FakePopen(returncode=1)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    reporter = RecordingReporter()
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    run(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"), reporter)

    assert "--db" in called_args
    assert "-i" in called_args
    assert str(src_dir.resolve()) in called_args


def test_run_omits_ddl_flag_when_not_given(monkeypatch, tmp_path):
    called_args: list = []

    def fake_popen(args, **kwargs):
        called_args.extend(args)
        return _FakePopen(returncode=1)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    reporter = RecordingReporter()
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    run(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"), reporter)

    assert "--ddl" not in called_args


def test_run_passes_ddl_flag_when_given(monkeypatch, tmp_path):
    called_args: list = []

    def fake_popen(args, **kwargs):
        called_args.extend(args)
        return _FakePopen(returncode=1)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    reporter = RecordingReporter()
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    ddl_path = tmp_path / "schema.sql"
    run(src_dir, str(tmp_path / "out.duckdb"), Path("/fake/bin"), reporter, ddl=[str(ddl_path)])

    assert "--ddl" in called_args
    assert called_args[called_args.index("--ddl") + 1] == str(ddl_path)


def test_run_passes_multiple_schema_tagged_ddl_flags_when_given(monkeypatch, tmp_path):
    called_args: list = []

    def fake_popen(args, **kwargs):
        called_args.extend(args)
        return _FakePopen(returncode=1)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    reporter = RecordingReporter()
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    run(
        src_dir,
        str(tmp_path / "out.duckdb"),
        Path("/fake/bin"),
        reporter,
        ddl=["CLIMS:clims.sql", "CLIMS_COMMON:common.sql"],
    )

    ddl_indices = [i for i, a in enumerate(called_args) if a == "--ddl"]
    assert len(ddl_indices) == 2
    assert called_args[ddl_indices[0] + 1] == "CLIMS:clims.sql"
    assert called_args[ddl_indices[1] + 1] == "CLIMS_COMMON:common.sql"


def test_run_success_renames_db(monkeypatch, tmp_path):
    db_path = str(tmp_path / "out.duckdb")

    def fake_popen(args, **kwargs):
        # Simulate pbc creating the .new DB file
        new_path = args[args.index("--db") + 1]
        _make_minimal_db(new_path)
        # Emit a minimal done event so runner_progress gets a clean signal
        done_line = b'{"tag":"done","parsed":5,"errors":0}'
        return _FakePopen(returncode=0, stderr_lines=[done_line])

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    reporter = RecordingReporter()
    run(tmp_path, db_path, Path("/fake/bin"), reporter)

    assert Path(db_path).exists(), "final DB file should exist after rename"
    assert not Path(db_path + ".new").exists(), ".new file should be removed after rename"

    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert len(done) == 1
    assert done[0]["errors"] == 0


def test_run_reset_deletes_existing_db(monkeypatch, tmp_path):
    db_path = tmp_path / "out.duckdb"
    db_path.write_text("placeholder")

    def fake_popen(args, **kwargs):
        return _FakePopen(returncode=1)

    monkeypatch.setattr("pb.pipeline.pipeline.subprocess.Popen", fake_popen)

    reporter = RecordingReporter()
    run(tmp_path, str(db_path), Path("/fake/bin"), reporter, reset=True)

    assert not db_path.exists()
