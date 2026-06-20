"""Unit tests for pb_cli.shell.commands — dump, corpus, debt.

dump.run() is fully env-wrapped and testable with fakes.
corpus.run() and debt.run() call subprocess directly (not env-wrapped),
so we test their build-routing logic and analysis paths respectively.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from pb_cli.shell.commands.dump import run as run_dump
from pb_cli.shell.env import ShellEnv
from pb_cli.shell.reporter import RecordingReporter

# ── dump.run ──────────────────────────────────────────────────────────────────


class FakeRunner:
    def __init__(self, objects: list[dict], errors: list[dict] | None = None):
        self._objects = objects
        self._errors = errors or []

    def parse_stream(self, src_dir, binary, *, remap_from=None, remap_to=None):
        for obj in self._objects:
            yield (False, obj)
        for err in self._errors:
            yield (True, err)


@pytest.fixture
def dump_env(tmp_path):
    e = ShellEnv()
    e.build.count_sr_files = lambda src_dir: 2
    runner = FakeRunner(
        objects=[
            {"file": "w_main.srw", "tag": "file"},
            {"file": "u_svc.sru", "tag": "file"},
        ]
    )
    e.runner.parse_stream = runner.parse_stream
    return e


def test_dump_writes_json_files(tmp_path, dump_env):
    out = tmp_path / "out"
    out.mkdir()

    with patch("pb_cli.shell.commands.dump.env", dump_env):
        reporter = RecordingReporter()
        run_dump(Path("/fake/src"), out, Path("/fake/bin"), reporter)

    assert (out / "w_main.srw.json").exists()
    assert (out / "u_svc.sru.json").exists()


def test_dump_emits_done_event(tmp_path, dump_env):
    out = tmp_path / "out"
    out.mkdir()

    with patch("pb_cli.shell.commands.dump.env", dump_env):
        reporter = RecordingReporter()
        run_dump(Path("/fake/src"), out, Path("/fake/bin"), reporter)

    done = [e for e in reporter.events if e["type"] == "done"]
    assert len(done) == 1
    assert done[0]["parsed"] == 2
    assert done[0]["errors"] == 0


def test_dump_errors_recorded(tmp_path):
    e = ShellEnv()
    e.build.count_sr_files = lambda src_dir: 2
    runner = FakeRunner(
        objects=[{"file": "good.srw", "tag": "file"}],
        errors=[{"file": "bad.srw", "error": "lex error"}],
    )
    e.runner.parse_stream = runner.parse_stream

    out = tmp_path / "out"
    out.mkdir()

    with patch("pb_cli.shell.commands.dump.env", e):
        reporter = RecordingReporter()
        run_dump(Path("/fake/src"), out, Path("/fake/bin"), reporter)

    done = [ev for ev in reporter.events if ev["type"] == "done"]
    assert done[0]["errors"] == 1
    # good file written, bad file not
    assert (out / "good.srw.json").exists()
    assert not (out / "bad.srw.json").exists()


def test_dump_nested_dirs_created(tmp_path):
    e = ShellEnv()
    src = tmp_path / "src"
    src.mkdir()
    nested = src / "sub" / "dir"
    nested.mkdir(parents=True)
    (nested / "w_main.srw").write_text("source")

    e.build.count_sr_files = lambda src_dir: 1
    e.runner.parse_stream = lambda src_dir, binary, *, remap_from=None, remap_to=None: iter(
        [(False, {"file": str(nested / "w_main.srw"), "tag": "file"})]
    )

    out = tmp_path / "out"
    out.mkdir()

    with patch("pb_cli.shell.commands.dump.env", e):
        reporter = RecordingReporter()
        run_dump(src, out, Path("/fake/bin"), reporter)

    assert (out / "sub/dir/w_main.srw.json").exists()


# ── corpus.run build routing ──────────────────────────────────────────────────


def test_corpus_routes_to_build_runner(monkeypatch, tmp_path):
    """corpus.run(no_build=False) calls build_runner, not find_binary."""
    from pb_cli.shell.commands import corpus

    built = []

    def fake_find_repo(repo=None):
        return tmp_path

    def fake_build_runner(repo, verbose=False):
        built.append(repo)
        return tmp_path / "pb-runner"

    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.find_repo", fake_find_repo)
    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.build_runner", fake_build_runner)

    # Create corpus source dirs so run() doesn't skip
    (tmp_path / "example" / "PowerBuilder-Example-extract").mkdir(parents=True)
    (tmp_path / "example" / "openpay-0.1.1b-extract").mkdir(parents=True)

    with patch("pb_cli.shell.commands.corpus.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "fail"
        with pytest.raises(SystemExit):
            corpus.run(no_build=False)

    assert len(built) == 1


def test_corpus_routes_to_find_binary(monkeypatch, tmp_path):
    """corpus.run(no_build=True) calls find_binary, not build_runner."""
    from pb_cli.shell.commands import corpus

    found = []

    def fake_find_repo(repo=None):
        return tmp_path

    def fake_find_binary(repo):
        found.append(repo)
        return tmp_path / "pb-runner"

    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.find_repo", fake_find_repo)
    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.find_binary", fake_find_binary)

    (tmp_path / "example" / "PowerBuilder-Example-extract").mkdir(parents=True)
    (tmp_path / "example" / "openpay-0.1.1b-extract").mkdir(parents=True)

    with patch("pb_cli.shell.commands.corpus.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "fail"
        with pytest.raises(SystemExit):
            corpus.run(no_build=True)

    assert len(found) == 1


# ── debt.run build routing ────────────────────────────────────────────────────


def test_debt_routes_to_build_runner(monkeypatch, tmp_path):
    from pb_cli.shell.commands import debt

    built = []

    def fake_find_repo(repo=None):
        return tmp_path

    def fake_build_runner(repo, verbose=False):
        built.append(repo)
        return tmp_path / "pb-runner"

    monkeypatch.setattr("pb_cli.shell.commands.debt.env.build.find_repo", fake_find_repo)
    monkeypatch.setattr("pb_cli.shell.commands.debt.env.build.build_runner", fake_build_runner)

    (tmp_path / "example" / "PowerBuilder-Example-extract").mkdir(parents=True)
    (tmp_path / "example" / "openpay-0.1.1b-extract").mkdir(parents=True)

    with patch("pb_cli.shell.commands.debt.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "fail"
        with pytest.raises(SystemExit):
            debt.run(no_build=False)

    assert len(built) == 1


def test_debt_routes_to_find_binary(monkeypatch, tmp_path):
    from pb_cli.shell.commands import debt

    found = []

    def fake_find_repo(repo=None):
        return tmp_path

    def fake_find_binary(repo):
        found.append(repo)
        return tmp_path / "pb-runner"

    monkeypatch.setattr("pb_cli.shell.commands.debt.env.build.find_repo", fake_find_repo)
    monkeypatch.setattr("pb_cli.shell.commands.debt.env.build.find_binary", fake_find_binary)

    (tmp_path / "example" / "PowerBuilder-Example-extract").mkdir(parents=True)
    (tmp_path / "example" / "openpay-0.1.1b-extract").mkdir(parents=True)

    with patch("pb_cli.shell.commands.debt.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "fail"
        with pytest.raises(SystemExit):
            debt.run(no_build=True)

    assert len(found) == 1
