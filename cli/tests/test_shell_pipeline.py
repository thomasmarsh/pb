"""Unit tests for pb_cli.shell.pipeline.run — incremental diff control flow.

Uses in-memory fakes for every env.storage/env.build field `run()` touches, so no
cabal build and no real DuckDB connection are needed. Full corpus-backed integration
coverage (real parse → real ingest → real metrics) stays in test_explorer.py's
db_path fixture, which exercises run_from_jsonl_lines + compute_metrics directly.
"""

from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path

import pytest

from pb_cli.reporter import RecordingReporter
from pb_cli.shell.env import ShellEnv
from pb_cli.shell.pipeline import run


class FakeDb:
    """In-memory stand-in for the file-state + object tables pipeline.run touches."""

    def __init__(self, file_state: dict[str, str] | None = None):
        self.file_state = dict(file_state or {})
        self.deleted: list[str] = []
        self.dropped = False
        self.schema_created = False
        self.state_table_created = False
        self.saved_state: dict[str, str] = {}
        self.metrics_computed = False


@pytest.fixture
def fake_env(tmp_path):
    db = FakeDb()
    e = ShellEnv()
    subset_dir = tmp_path / "subset"
    subset_dir.mkdir(exist_ok=True)

    @contextmanager
    def db_connection(path, read_only=False):
        yield db

    e.storage.db_connection = db_connection  # type: ignore[assignment]
    e.storage.drop_tables = lambda conn: setattr(conn, "dropped", True)
    e.storage.create_schema = lambda conn: setattr(conn, "schema_created", True)
    e.storage.create_state_table = lambda conn: setattr(conn, "state_table_created", True)
    e.storage.load_file_state = lambda conn: conn.file_state  # type: ignore[attr-defined]
    e.storage.delete_file_rows = lambda conn, file_path: conn.deleted.append(file_path)  # type: ignore[attr-defined]
    e.storage.save_file_state = lambda conn, states: conn.saved_state.update(states)  # type: ignore[attr-defined]
    e.storage.compute_metrics = lambda conn, progress: setattr(conn, "metrics_computed", True)
    e.storage.build_subset_tmpdir = lambda src_dir, files: subset_dir
    e.storage.ingest_batch = lambda objects, conn, dialect="oracle", on_progress=None: len(objects)  # type: ignore[assignment]

    return e, db


def _patch_env(monkeypatch, env_obj):
    monkeypatch.setattr("pb_cli.shell.pipeline.env", env_obj)


def test_no_changes_short_circuits(monkeypatch, fake_env):
    e, db = fake_env
    db.file_state = {"a.srw": "abc"}
    e.build.hash_source_dir = lambda src_dir: {"a.srw": "abc"}
    _patch_env(monkeypatch, e)

    reporter = RecordingReporter()
    run(Path("/fake"), "test.duckdb", Path("/fake/bin"), reporter)

    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert len(done) == 1
    assert done[0]["parsed"] == 0
    assert done[0]["errors"] == 0
    assert done[0]["diff"] == {"new": 0, "changed": 0, "deleted": 0}
    assert not db.metrics_computed


def test_new_files_parsed_and_ingested(monkeypatch, fake_env):
    e, db = fake_env
    e.build.hash_source_dir = lambda src_dir: {"new.srw": "hash1"}
    e.runner.parse_stream = lambda src_dir, binary, *, remap_from=None, remap_to=None: iter(
        [(False, {"file": "new.srw", "tag": "file"})]
    )
    _patch_env(monkeypatch, e)

    reporter = RecordingReporter()
    run(Path("/fake"), "test.duckdb", Path("/fake/bin"), reporter)

    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert len(done) == 1
    assert done[0]["parsed"] == 1
    assert done[0]["errors"] == 0
    assert done[0]["diff"] == {"new": 1, "changed": 0, "deleted": 0}
    assert db.saved_state == {"new.srw": "hash1"}


def test_changed_file_triggers_delete_then_reingest(monkeypatch, fake_env):
    e, db = fake_env
    db.file_state = {"old.srw": "old_hash"}
    e.build.hash_source_dir = lambda src_dir: {"old.srw": "new_hash"}
    e.runner.parse_stream = lambda src_dir, binary, *, remap_from=None, remap_to=None: iter(
        [(False, {"file": "old.srw", "tag": "file"})]
    )
    _patch_env(monkeypatch, e)

    reporter = RecordingReporter()
    run(Path("/fake"), "test.duckdb", Path("/fake/bin"), reporter)

    assert "old.srw" in db.deleted
    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert done[0]["parsed"] == 1
    assert done[0]["diff"] == {"new": 0, "changed": 1, "deleted": 0}


def test_deleted_file_only_deletes_no_reparse(monkeypatch, fake_env):
    e, db = fake_env
    db.file_state = {"gone.srw": "hash1"}
    e.build.hash_source_dir = lambda src_dir: {}

    parse_called = False

    def fake_parse(src_dir, binary, *, remap_from=None, remap_to=None):
        nonlocal parse_called
        parse_called = True
        return iter([])

    e.runner.parse_stream = fake_parse
    _patch_env(monkeypatch, e)

    reporter = RecordingReporter()
    run(Path("/fake"), "test.duckdb", Path("/fake/bin"), reporter)

    assert "gone.srw" in db.deleted
    assert not parse_called
    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert done[0]["parsed"] == 0
    assert done[0]["diff"] == {"new": 0, "changed": 0, "deleted": 1}


def test_reset_flag_drops_tables(monkeypatch, fake_env):
    e, db = fake_env
    e.build.hash_source_dir = lambda src_dir: {}
    _patch_env(monkeypatch, e)

    reporter = RecordingReporter()
    run(Path("/fake"), "test.duckdb", Path("/fake/bin"), reporter, reset=True)
    assert db.dropped

    db2 = FakeDb()
    e2, db2_ref = fake_env
    e2.build.hash_source_dir = lambda src_dir: {}

    @contextmanager
    def db_connection2(path, read_only=False):
        yield db2

    e2.storage.db_connection = db_connection2
    e2.storage.drop_tables = lambda conn: setattr(conn, "dropped", True)
    _patch_env(monkeypatch, e2)

    reporter2 = RecordingReporter()
    run(Path("/fake"), "test.duckdb", Path("/fake/bin"), reporter2, reset=False)
    assert not db2.dropped


def test_parse_error_propagates_to_done_event(monkeypatch, fake_env):
    e, db = fake_env
    e.build.hash_source_dir = lambda src_dir: {"bad.srw": "hash1"}
    e.runner.parse_stream = lambda src_dir, binary, *, remap_from=None, remap_to=None: iter(
        [(True, {"file": "bad.srw", "error": "lex failure"})]
    )
    _patch_env(monkeypatch, e)

    reporter = RecordingReporter()
    run(Path("/fake"), "test.duckdb", Path("/fake/bin"), reporter)

    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert len(done) == 1
    assert done[0]["errors"] == 1
    assert done[0]["parsed"] == 1
